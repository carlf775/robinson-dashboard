const std = @import("std");
const Pipeline = @import("../../pipeline.zig").Pipeline;
const Node = @import("../../pipeline.zig").Node;
const sam3_engine = @import("engine.zig");
const Sam3TrainEngine = sam3_engine.Sam3TrainEngine;

pub const node_type = "sam3_ad";

pub const Sam3State = struct {
    pipeline: *Pipeline,
    input_frame: ?*?[]u8, // wired by edge to camera's output_frame
    output_score: ?f32,
    output_heatmap: ?[]u8,

    // Worker state
    mutex: std.Thread.Mutex,
    condvar: std.Thread.Condition,
    pending_frame: ?[]u8,
    result_score: ?f32,
    result_heatmap: ?[]u8,
    worker_ready: bool,

    // Config
    model_id: ?[]const u8,
    image_size: i64,
    threshold: f32,
    sam3_state: ?[]const u8, // "idle", "collecting", "training", "ready"

    allocator: std.mem.Allocator,
};

pub fn init(pipeline: *Pipeline, id: []const u8, data: std.json.Value, ports: *std.StringHashMap(*anyopaque)) ?Node {
    const a = pipeline.arena.allocator();

    const state = a.create(Sam3State) catch return null;

    // Extract config from node data
    var model_id: ?[]const u8 = null;
    var image_size: i64 = 504;
    var threshold: f32 = 0.5;
    var sam3_state: ?[]const u8 = null;

    if (data == .object) {
        if (data.object.get("state")) |st| {
            if (st == .string) sam3_state = a.dupe(u8, st.string) catch null;
        }
        if (data.object.get("modelId")) |mid| {
            if (mid == .string and mid.string.len > 0) {
                model_id = a.dupe(u8, mid.string) catch null;
            }
        }
        if (data.object.get("trainingConfig")) |tc| {
            if (tc == .object) {
                if (tc.object.get("imageSize")) |isz| {
                    if (isz == .integer and isz.integer > 0 and @mod(isz.integer, 14) == 0) {
                        image_size = isz.integer;
                    }
                }
            }
        }
        if (data.object.get("inferenceThreshold")) |thr| {
            switch (thr) {
                .float => |f| {
                    if (f > 0 and f <= 1) threshold = @floatCast(f);
                },
                .integer => |i| {
                    if (i >= 0 and i <= 1) threshold = @floatFromInt(i);
                },
                else => {},
            }
        }
    }

    state.* = .{
        .pipeline = pipeline,
        .input_frame = null,
        .output_score = null,
        .output_heatmap = null,
        .mutex = .{},
        .condvar = .{},
        .pending_frame = null,
        .result_score = null,
        .result_heatmap = null,
        .worker_ready = false,
        .model_id = model_id,
        .image_size = image_size,
        .threshold = threshold,
        .sam3_state = sam3_state,
        .allocator = std.heap.page_allocator,
    };

    // Register input port: "{id}:image"
    const input_key = std.fmt.allocPrint(a, "{s}:image", .{id}) catch return null;
    ports.put(input_key, @ptrCast(&state.input_frame)) catch return null;

    // Register output ports
    const score_key = std.fmt.allocPrint(a, "{s}:score", .{id}) catch return null;
    ports.put(score_key, @ptrCast(&state.output_score)) catch return null;

    const heatmap_key = std.fmt.allocPrint(a, "{s}:heatmap", .{id}) catch return null;
    ports.put(heatmap_key, @ptrCast(&state.output_heatmap)) catch return null;

    // Spawn worker thread if we have a model ready
    const is_ready = if (sam3_state) |s| std.mem.eql(u8, s, "ready") else false;
    if (is_ready and model_id != null) {
        const thread = std.Thread.spawn(.{}, workerLoop, .{state}) catch {
            std.log.err("SAM3: failed to spawn worker thread", .{});
            return null;
        };
        pipeline.threads.append(a, thread) catch {};
    }

    return .{
        .tick_fn = &tick,
        .state = @ptrCast(state),
    };
}

fn tick(state_ptr: *anyopaque, _: i128) void {
    const state: *Sam3State = @ptrCast(@alignCast(state_ptr));

    // Try to read results from worker
    if (state.mutex.tryLock()) {
        defer state.mutex.unlock();

        // Collect results
        if (state.result_score) |score| {
            state.output_score = score;
            state.result_score = null;
        }
        if (state.result_heatmap) |heatmap| {
            if (state.output_heatmap) |old| state.allocator.free(old);
            state.output_heatmap = heatmap;
            state.result_heatmap = null;
        }

        // Submit new frame if worker is ready
        if (state.worker_ready) {
            if (state.input_frame) |frame_ptr| {
                if (frame_ptr.*) |frame_data| {
                    if (state.pending_frame) |old| state.allocator.free(old);
                    state.pending_frame = state.allocator.dupe(u8, frame_data) catch null;
                    state.worker_ready = false;
                    state.condvar.signal();
                }
            }
        }
    }
}

fn workerLoop(state: *Sam3State) void {
    const model_id = state.model_id orelse return;

    // Build model path
    var model_path_buf: [256]u8 = undefined;
    const model_path = std.fmt.bufPrint(&model_path_buf, "data/models/{s}", .{model_id}) catch return;

    // Check model file exists
    std.fs.cwd().access(model_path, .{}) catch {
        std.log.err("SAM3 worker: model file not found: {s}", .{model_path});
        return;
    };

    // Initialize engine
    const engine = Sam3TrainEngine.init(state.allocator, "weights/sam3.safetensors", state.image_size) catch |err| {
        std.log.err("SAM3 worker: failed to init engine: {}", .{err});
        return;
    };
    defer engine.deinit();

    engine.loadTrainedWeights(model_path) catch |err| {
        std.log.err("SAM3 worker: failed to load weights from {s}: {}", .{ model_path, err });
        return;
    };

    std.log.info("SAM3 worker: engine ready (model={s})", .{model_id});

    // Signal ready
    {
        state.mutex.lock();
        state.worker_ready = true;
        state.mutex.unlock();
    }

    while (!state.pipeline.should_stop.load(.acquire)) {
        var frame: ?[]u8 = null;
        {
            state.mutex.lock();
            defer state.mutex.unlock();

            while (state.pending_frame == null and !state.pipeline.should_stop.load(.acquire)) {
                state.condvar.timedWait(&state.mutex, 100_000_000) catch {};
            }
            if (state.pipeline.should_stop.load(.acquire)) return;
            frame = state.pending_frame;
            state.pending_frame = null;
        }

        const jpeg_data = frame orelse continue;
        defer state.allocator.free(jpeg_data);

        // Preprocess
        const image_data = Sam3TrainEngine.preprocessJpeg(state.allocator, jpeg_data, @intCast(state.image_size)) catch continue;
        defer state.allocator.free(image_data);

        // Infer
        const pred = engine.infer(image_data) catch continue;
        defer state.allocator.free(pred.pred_logits);
        defer state.allocator.free(pred.pred_boxes);
        defer state.allocator.free(pred.pred_masks);

        // Post-process
        const detections = Sam3TrainEngine.postProcessPredictions(pred, state.allocator, state.threshold) catch continue;
        defer state.allocator.free(detections);

        var max_score: f32 = 0;
        for (detections) |det| {
            if (det.score > max_score) max_score = det.score;
        }

        // Write results
        {
            state.mutex.lock();
            defer state.mutex.unlock();
            state.result_score = max_score;
            state.worker_ready = true;
        }
    }
}

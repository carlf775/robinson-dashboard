const std = @import("std");
const Pipeline = @import("../../pipeline.zig").Pipeline;
const Node = @import("../../pipeline.zig").Node;
const StreamManager = @import("stream_manager.zig").StreamManager;

pub const node_type = "camera";

pub const CameraState = struct {
    pipeline: *Pipeline,
    camera_id: ?[]const u8,
    output_frame: ?[]u8,
    stream_manager: *StreamManager,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CameraState) void {
        if (self.output_frame) |f| {
            self.allocator.free(f);
            self.output_frame = null;
        }
    }
};

pub fn init(pipeline: *Pipeline, id: []const u8, data: std.json.Value, ports: *std.StringHashMap(*anyopaque)) ?Node {
    const a = pipeline.arena.allocator();

    const state = a.create(CameraState) catch return null;

    // Extract cameraId from node data
    var camera_id: ?[]const u8 = null;
    if (data == .object) {
        if (data.object.get("cameraId")) |cid| {
            if (cid == .string and cid.string.len > 0) {
                camera_id = a.dupe(u8, cid.string) catch null;
            }
        }
    }

    // Get StreamManager from opaque context
    const ctx: *StreamManager = @ptrCast(@alignCast(pipeline.ctx orelse return null));

    state.* = .{
        .pipeline = pipeline,
        .camera_id = camera_id,
        .output_frame = null,
        .stream_manager = ctx,
        .allocator = std.heap.page_allocator,
    };

    // Register output port: "{id}:image"
    const port_key = std.fmt.allocPrint(a, "{s}:image", .{id}) catch return null;
    ports.put(port_key, @ptrCast(&state.output_frame)) catch return null;

    return .{
        .tick_fn = &tick,
        .state = @ptrCast(state),
    };
}

fn tick(state_ptr: *anyopaque, _: i128) void {
    const state: *CameraState = @ptrCast(@alignCast(state_ptr));
    const camera_id = state.camera_id orelse return;
    const sm = state.stream_manager;

    if (!sm.isStreaming(camera_id)) {
        if (sm.isStreamingAny()) return;
        _ = sm.startStream(camera_id) catch return;
        return;
    }

    const gst_pipeline = sm.getPipeline() orelse return;
    const jpeg = gst_pipeline.pullJpeg() orelse return;
    defer gst_pipeline.freeJpeg(jpeg);

    // Update output frame
    if (state.output_frame) |old| state.allocator.free(old);
    state.output_frame = state.allocator.dupe(u8, jpeg) catch null;
}

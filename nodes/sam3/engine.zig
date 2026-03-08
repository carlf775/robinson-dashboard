const std = @import("std");

const zml = @import("zml");
const pjrt = zml.pjrt;
const graph = zml.ComputeGraph;
const sam3 = zml.sam3;

const stbi = @cImport({
    @cInclude("stb_image.h");
});

const MAX_POINTS: i64 = 16;
const MASK_H: i64 = 288; // FPN pixel decoder upsamples: 72 → 144 → 288
const MASK_W: i64 = 288;
const OUT_MASK_H: usize = @intCast(MASK_H); // already at full resolution from FPN
const OUT_MASK_W: usize = @intCast(MASK_W);
const NUM_QUERIES: i64 = 200;
const IMAGE_SIZE: i64 = 1008;
const TEXT_SEQ_LEN: i64 = 32;

pub const Detection = struct {
    box: [4]f32, // xyxy normalized [0,1]
    score: f32,
    selected: bool, // true for the query matching the clicked point
};

pub const SegmentResult = struct {
    /// OUT_MASK_H x OUT_MASK_W binary mask (0 or 255 per pixel)
    mask: []u8,
    width: u32 = OUT_MASK_W,
    height: u32 = OUT_MASK_H,
    iou: f32,
    /// All confident detections
    detections: []Detection,
};

pub const Sam3Engine = struct {
    allocator: std.mem.Allocator,

    // Compiled model executable + PJRT state
    plugin: zml.Plugin = undefined,
    executable: zml.Executable = undefined,
    device_weights: []?*pjrt.PJRT_Buffer = undefined,
    device: *pjrt.PJRT_Device = undefined,

    // Input buffer indices (set during graph construction)
    image_buf_idx: usize = 0,
    text_buf_idx: usize = 0,
    points_buf_idx: usize = 0,
    point_labels_buf_idx: usize = 0,
    point_mask_buf_idx: usize = 0,
    num_outputs: usize = 0,

    pub fn init(allocator: std.mem.Allocator, weights_path: []const u8) !*Sam3Engine {
        const self = try allocator.create(Sam3Engine);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
        };

        // Load PJRT plugin (CUDA backend)
        self.plugin = zml.Plugin.load("../zig-ml/lib/libpjrt_cuda.so") catch
            try zml.loadPlugin(.cuda);

        // SAM3 Large configuration (matches example_infer_sam.zig)
        const config = sam3.Sam3ImageConfig{
            .image_size = IMAGE_SIZE,
            .patch_size = 14,
            .embed_dim = 1024,
            .vit_depth = 32,
            .vit_num_heads = 16,
            .vit_mlp_ratio = 4.625,
            .window_size = 24,
            .pretrain_img_size = 336,
            .neck_out_dim = 256,
            .num_feature_levels = 1,
            .text_embed_dim = 1024,
            .text_num_layers = 24,
            .text_num_heads = 16,
            .text_context_length = TEXT_SEQ_LEN,
            .text_vocab_size = 49408,
            .encoder_d_model = 256,
            .encoder_num_heads = 8,
            .encoder_dim_feedforward = 2048,
            .encoder_num_layers = 6,
            .decoder_d_model = 256,
            .decoder_num_heads = 8,
            .decoder_dim_feedforward = 2048,
            .decoder_num_layers = 6,
            .num_queries = NUM_QUERIES,
            .use_dac = true,
            .use_box_refine = true,
            .geo_num_layers = 3,
            .geo_num_heads = 8,
            .seg_hidden_dim = 256,
            .seg_num_upsampling_stages = 3,
            .use_dot_prod_scoring = true,
        };

        // Build the computation graph
        var g = zml.ComputeGraph.init(allocator);
        defer g.deinit();

        const Shape = zml.Node.Shape;
        const image = g.addInput("image", Shape.init(.{ 1, 3, IMAGE_SIZE, IMAGE_SIZE }, .f32));
        const text_tokens = g.addInput("text_tokens", Shape.init(.{ 1, TEXT_SEQ_LEN }, .i64));

        // Point prompt inputs: [num_points, B, 2], [num_points, B], [B, num_points]
        const points_input = g.addInput("points", Shape.init(.{ MAX_POINTS, 1, 2 }, .f32));
        const point_labels_input = g.addInput("point_labels", Shape.init(.{ MAX_POINTS, 1 }, .f32));
        const point_mask_input = g.addInput("point_mask", Shape.init(.{ 1, MAX_POINTS }, .bool));

        // Build model with point prompts
        const output = try sam3.addSam3Image(
            &g,
            image,
            text_tokens,
            null, // no box prompts
            null, // no box mask
            points_input,
            point_labels_input,
            point_mask_input,
            "detector_model",
            config,
            allocator,
        );

        // Outputs: pred_logits[0], pred_boxes[1], pred_masks[2]
        g.setOutput(output.pred_logits);
        g.setOutput(output.pred_boxes);
        g.setOutput(output.pred_masks);
        self.num_outputs = 3;

        // Store input indices
        self.image_buf_idx = g.getInputIndex("image") orelse return error.InputNotFound;
        self.text_buf_idx = g.getInputIndex("text_tokens") orelse return error.InputNotFound;
        self.points_buf_idx = g.getInputIndex("points") orelse return error.InputNotFound;
        self.point_labels_buf_idx = g.getInputIndex("point_labels") orelse return error.InputNotFound;
        self.point_mask_buf_idx = g.getInputIndex("point_mask") orelse return error.InputNotFound;

        // Compile
        std.log.info("SAM3: Emitting MLIR module...", .{});
        const module = try zml.emitMLIR(allocator, &g);
        std.log.info("SAM3: Compiling model (this may take a while)...", .{});
        self.executable = try zml.compile(allocator, module, &self.plugin);

        // Load and upload weights
        std.log.info("SAM3: Loading weights from {s}...", .{weights_path});
        const host_weights = try g.loadWeights(weights_path, allocator);
        defer allocator.free(host_weights);
        std.log.info("SAM3: Uploading weights to GPU...", .{});
        self.device_weights = try g.uploadWeights(
            host_weights,
            self.plugin.api,
            self.executable.client,
            allocator,
        );

        // Get device handle for buffer uploads
        var devices_args = pjrt.PJRT_Client_Devices_Args{
            .struct_size = pjrt.PJRT_Client_Devices_Args_STRUCT_SIZE,
            .client = self.executable.client,
        };
        _ = self.plugin.api.PJRT_Client_Devices.?(&devices_args);
        self.device = devices_args.devices[0].?;

        std.log.info("SAM3: Engine initialized successfully", .{});

        return self;
    }

    pub fn deinit(self: *Sam3Engine) void {
        // Free GPU weight buffers
        for (self.device_weights) |maybe_buf| {
            if (maybe_buf) |buf| {
                destroyPjrtBuffer(self.plugin.api, buf);
            }
        }
        self.allocator.free(self.device_weights);
        self.executable.deinit();
        self.plugin.deinit();
        self.allocator.destroy(self);
    }

    /// Run the full model with point prompts, return binary mask of best query.
    /// `jpeg_data` is raw JPEG file bytes.
    /// `points` are normalized 0-1 coordinates, `labels` are 0=negative, 1=positive.
    pub fn segment(self: *Sam3Engine, jpeg_data: []const u8, points: []const [2]f32, labels: []const i32) !SegmentResult {

        const allocator = self.allocator;

        // 1. Decode JPEG via stb_image
        var img_w: c_int = 0;
        var img_h: c_int = 0;
        var img_c: c_int = 0;
        const pixels = stbi.stbi_load_from_memory(
            jpeg_data.ptr,
            @intCast(jpeg_data.len),
            &img_w,
            &img_h,
            &img_c,
            3, // force RGB
        ) orelse return error.ImageDecodeFailed;
        defer stbi.stbi_image_free(pixels);

        const src_w: usize = @intCast(img_w);
        const src_h: usize = @intCast(img_h);
        const target: usize = @intCast(IMAGE_SIZE);

        // 2. Preprocess: resize + normalize to [-1, 1] in [1, 3, H, W] layout
        const num_pixels = target * target;
        const image_data = try allocator.alloc(f32, 3 * num_pixels);
        defer allocator.free(image_data);

        const src_wf = @as(f32, @floatFromInt(src_w));
        const src_hf = @as(f32, @floatFromInt(src_h));
        const target_f = @as(f32, @floatFromInt(target));
        const scale_x = src_wf / target_f;
        const scale_y = src_hf / target_f;

        for (0..target) |y| {
            for (0..target) |x| {
                // PIL-compatible bilinear interpolation (pixel-center aligned)
                const src_xf = (@as(f32, @floatFromInt(x)) + 0.5) * scale_x - 0.5;
                const src_yf = (@as(f32, @floatFromInt(y)) + 0.5) * scale_y - 0.5;

                const x0 = @as(usize, @intFromFloat(@max(src_xf, 0)));
                const y0 = @as(usize, @intFromFloat(@max(src_yf, 0)));
                const x1 = @min(x0 + 1, src_w - 1);
                const y1 = @min(y0 + 1, src_h - 1);

                const xf = @max(src_xf - @as(f32, @floatFromInt(x0)), 0);
                const yf = @max(src_yf - @as(f32, @floatFromInt(y0)), 0);

                const di = y * target + x;

                for (0..3) |c| {
                    const p00 = @as(f32, @floatFromInt(pixels[(y0 * src_w + x0) * 3 + c]));
                    const p10 = @as(f32, @floatFromInt(pixels[(y0 * src_w + x1) * 3 + c]));
                    const p01 = @as(f32, @floatFromInt(pixels[(y1 * src_w + x0) * 3 + c]));
                    const p11 = @as(f32, @floatFromInt(pixels[(y1 * src_w + x1) * 3 + c]));

                    const val = p00 * (1 - xf) * (1 - yf) +
                        p10 * xf * (1 - yf) +
                        p01 * (1 - xf) * yf +
                        p11 * xf * yf;

                    // SAM3 normalization: (pixel / 255.0 - 0.5) / 0.5 = pixel / 127.5 - 1.0
                    image_data[c * num_pixels + di] = val / 127.5 - 1.0;
                }
            }
        }

        // 3. Prepare text tokens (empty prompt — just SOT+EOT)
        var text_data: [TEXT_SEQ_LEN]i64 = [_]i64{0} ** TEXT_SEQ_LEN;
        text_data[0] = 49406; // SOT token
        text_data[1] = 49407; // EOT token

        // 4. Prepare point prompt tensors
        // points: [MAX_POINTS, 1, 2], point_labels: [MAX_POINTS, 1], point_mask: [1, MAX_POINTS]
        var pts_data: [MAX_POINTS * 2]f32 = [_]f32{0} ** (MAX_POINTS * 2);
        var lbl_data: [MAX_POINTS]f32 = [_]f32{0} ** MAX_POINTS; // 0 = negative (safe default for padding)
        var mask_data: [MAX_POINTS]u8 = [_]u8{1} ** MAX_POINTS; // 1 = masked (padding)

        const n = @min(points.len, @as(usize, @intCast(MAX_POINTS)));
        for (0..n) |i| {
            pts_data[i * 2 + 0] = points[i][0]; // x normalized 0-1
            pts_data[i * 2 + 1] = points[i][1]; // y normalized 0-1
            // Frontend: 0=positive, 1=negative → SAM3 geometry encoder: 0=negative, 1=positive
            lbl_data[i] = @floatFromInt(1 - labels[i]);
            mask_data[i] = 0; // 0 = not masked (valid point)
            std.log.info("SAM3: point[{}] x={d:.3} y={d:.3} frontend_label={} sam3_label={d:.0}", .{ i, points[i][0], points[i][1], labels[i], lbl_data[i] });
        }

        // 5. Upload all inputs to device
        const api = self.plugin.api;
        const client = self.executable.client;
        const device = self.device;

        // Make a mutable copy of device_weights for input slots
        const bufs = try allocator.dupe(?*pjrt.PJRT_Buffer, self.device_weights);
        defer allocator.free(bufs);

        // Upload image [1, 3, 1008, 1008]
        var img_dims = [_]i64{ 1, 3, IMAGE_SIZE, IMAGE_SIZE };
        bufs[self.image_buf_idx] = try uploadBuffer(api, client, device, @ptrCast(image_data.ptr), &img_dims, 4, @intCast(pjrt.PJRT_Buffer_Type_F32));

        // Upload text tokens [1, 32]
        var txt_dims = [_]i64{ 1, TEXT_SEQ_LEN };
        bufs[self.text_buf_idx] = try uploadBuffer(api, client, device, @ptrCast(&text_data), &txt_dims, 2, @intCast(pjrt.PJRT_Buffer_Type_S64));

        // Upload points [MAX_POINTS, 1, 2]
        var pts_dims = [_]i64{ MAX_POINTS, 1, 2 };
        bufs[self.points_buf_idx] = try uploadBuffer(api, client, device, @ptrCast(&pts_data), &pts_dims, 3, @intCast(pjrt.PJRT_Buffer_Type_F32));

        // Upload point_labels [MAX_POINTS, 1]
        var lbl_dims = [_]i64{ MAX_POINTS, 1 };
        bufs[self.point_labels_buf_idx] = try uploadBuffer(api, client, device, @ptrCast(&lbl_data), &lbl_dims, 2, @intCast(pjrt.PJRT_Buffer_Type_F32));

        // Upload point_mask [1, MAX_POINTS] as PRED (bool)
        var msk_dims = [_]i64{ 1, MAX_POINTS };
        bufs[self.point_mask_buf_idx] = try uploadBuffer(api, client, device, @ptrCast(&mask_data), &msk_dims, 2, @intCast(pjrt.PJRT_Buffer_Type_PRED));

        // 6. Execute
        std.log.info("SAM3: Running inference...", .{});
        const outputs = try self.executable.execute(bufs, allocator, self.num_outputs);
        defer allocator.free(outputs);

        // 7. Download pred_logits [1, 200, 1] and pred_masks [1, 200, 72, 72]
        const logits_data = try allocator.alloc(f32, @intCast(NUM_QUERIES));
        defer allocator.free(logits_data);
        try downloadBuffer(api, outputs[0], @ptrCast(logits_data.ptr), logits_data.len * @sizeOf(f32));

        const mw: usize = @intCast(MASK_W);
        const mh: usize = @intCast(MASK_H);
        const mask_pixels: usize = mw * mh;
        const nq: usize = @intCast(NUM_QUERIES);
        const all_masks = try allocator.alloc(f32, nq * mask_pixels);
        defer allocator.free(all_masks);
        try downloadBuffer(api, outputs[2], @ptrCast(all_masks.ptr), all_masks.len * @sizeOf(f32));

        // Download pred_boxes [1, 200, 4] in cxcywh normalized format
        const all_boxes = try allocator.alloc(f32, nq * 4);
        defer allocator.free(all_boxes);
        try downloadBuffer(api, outputs[1], @ptrCast(all_boxes.ptr), all_boxes.len * @sizeOf(f32));

        // Point-guided query selection: pick the query whose mask is most
        // positive at the first positive point location, among confident queries.
        // Fall back to highest logit if no positive point.
        var best_idx: usize = 0;
        var best_score: f32 = -std.math.inf(f32);

        // Find first positive point in mask coordinates
        var pos_mx: usize = 0;
        var pos_my: usize = 0;
        var has_positive_pt = false;
        for (0..n) |i| {
            if (lbl_data[i] == 1) { // SAM3 positive label
                pos_mx = @min(@as(usize, @intFromFloat(points[i][0] * @as(f32, @floatFromInt(mw)))), mw - 1);
                pos_my = @min(@as(usize, @intFromFloat(points[i][1] * @as(f32, @floatFromInt(mh)))), mh - 1);
                has_positive_pt = true;
                break;
            }
        }

        var positive_count: usize = 0;
        for (0..nq) |i| {
            if (logits_data[i] > 0) positive_count += 1;
        }

        if (has_positive_pt) {
            // Step 1: Among queries with positive logits, find the one with
            // highest mask value at the clicked point
            for (0..nq) |i| {
                if (logits_data[i] <= 0) continue; // only real detections
                const mask_val = all_masks[i * mask_pixels + pos_my * mw + pos_mx];
                if (mask_val > best_score) {
                    best_score = mask_val;
                    best_idx = i;
                }
            }
            // Step 2: If no positive-logit query found, fall back to highest logit
            if (best_score == -std.math.inf(f32)) {
                for (0..nq) |i| {
                    if (logits_data[i] > best_score) {
                        best_score = logits_data[i];
                        best_idx = i;
                    }
                }
            }
        } else {
            // No positive points — pick highest logit
            for (0..nq) |i| {
                if (logits_data[i] > best_score) {
                    best_score = logits_data[i];
                    best_idx = i;
                }
            }
        }
        const iou = 1.0 / (1.0 + @exp(-logits_data[best_idx])); // sigmoid of logit
        std.log.info("SAM3: {}/{} positive queries, selected query={} (logit={d:.3}, iou={d:.3})", .{ positive_count, nq, best_idx, logits_data[best_idx], iou });

        // Debug: compact 18×18 ASCII visualization of selected mask
        {
            const src_dbg = all_masks[best_idx * mask_pixels ..][0..mask_pixels];
            var ascii: [19 * 18]u8 = undefined; // 18 chars + newline per row
            for (0..18) |row| {
                for (0..18) |col| {
                    const sy_d = row * mh / 18;
                    const sx_d = col * mw / 18;
                    ascii[row * 19 + col] = if (src_dbg[sy_d * mw + sx_d] > 0) '#' else '.';
                }
                ascii[row * 19 + 18] = '\n';
            }
            std.log.info("SAM3: Mask preview (18x18):\n{s}", .{&ascii});
        }

        // Collect all confident detections (positive logit) with their boxes
        var det_list: std.ArrayList(Detection) = .{};
        for (0..nq) |i| {
            if (logits_data[i] <= 0) continue;
            const b = all_boxes[i * 4 ..][0..4];
            const bx1 = @max(b[0] - b[2] / 2.0, 0);
            const by1 = @max(b[1] - b[3] / 2.0, 0);
            const bx2 = @min(b[0] + b[2] / 2.0, 1.0);
            const by2 = @min(b[1] + b[3] / 2.0, 1.0);
            try det_list.append(allocator, .{
                .box = .{ bx1, by1, bx2, by2 },
                .score = 1.0 / (1.0 + @exp(-logits_data[i])),
                .selected = (i == best_idx),
            });
        }

        // Binarize the selected mask (288×288 from FPN pixel decoder)
        const src = all_masks[best_idx * mask_pixels ..][0..mask_pixels];
        const result_mask = try allocator.alloc(u8, OUT_MASK_H * OUT_MASK_W);
        var white_pixels: usize = 0;

        for (0..mask_pixels) |i| {
            result_mask[i] = if (src[i] > 0) 255 else 0;
            if (src[i] > 0) white_pixels += 1;
        }

        std.log.info("SAM3: mask {}/{} white pixels ({d:.1}%), {} detections", .{ white_pixels, OUT_MASK_H * OUT_MASK_W, @as(f32, @floatFromInt(white_pixels)) / @as(f32, @floatFromInt(OUT_MASK_H * OUT_MASK_W)) * 100.0, det_list.items.len });

        return SegmentResult{
            .mask = result_mask,
            .iou = iou,
            .detections = try det_list.toOwnedSlice(allocator),
        };
    }

    fn uploadBuffer(
        api: *const pjrt.PJRT_Api,
        client: *pjrt.PJRT_Client,
        device: *pjrt.PJRT_Device,
        data: *const anyopaque,
        dims: [*]i64,
        num_dims: usize,
        dtype: c_uint,
    ) !*pjrt.PJRT_Buffer {
        var args = pjrt.PJRT_Client_BufferFromHostBuffer_Args{
            .struct_size = pjrt.PJRT_Client_BufferFromHostBuffer_Args_STRUCT_SIZE,
            .client = client,
            .data = data,
            .type = dtype,
            .dims = dims,
            .num_dims = num_dims,
            .host_buffer_semantics = pjrt.PJRT_HostBufferSemantics_kImmutableUntilTransferCompletes,
            .device = device,
        };
        if (api.PJRT_Client_BufferFromHostBuffer.?(&args) != null) {
            return error.BufferUploadFailed;
        }
        // Wait for transfer
        if (args.done_with_host_buffer) |event| {
            var await_args = pjrt.PJRT_Event_Await_Args{
                .struct_size = pjrt.PJRT_Event_Await_Args_STRUCT_SIZE,
                .event = event,
            };
            _ = api.PJRT_Event_Await.?(&await_args);
        }
        return args.buffer orelse error.BufferUploadFailed;
    }

    fn downloadBuffer(
        api: *const pjrt.PJRT_Api,
        src: *pjrt.PJRT_Buffer,
        dst: *anyopaque,
        dst_size: usize,
    ) !void {
        var args = pjrt.PJRT_Buffer_ToHostBuffer_Args{
            .struct_size = pjrt.PJRT_Buffer_ToHostBuffer_Args_STRUCT_SIZE,
            .src = src,
            .dst = dst,
            .dst_size = dst_size,
        };
        if (api.PJRT_Buffer_ToHostBuffer.?(&args) != null) {
            return error.BufferDownloadFailed;
        }
        // Wait for transfer
        var await_args = pjrt.PJRT_Event_Await_Args{
            .struct_size = pjrt.PJRT_Event_Await_Args_STRUCT_SIZE,
            .event = args.event,
        };
        _ = api.PJRT_Event_Await.?(&await_args);
    }

    pub fn isAvailable() bool {
        return true;
    }
};

// ============================================================================
// Training Engine — forward-only (loss computation without backward pass)
// ============================================================================

pub const TRAIN_MAX_GT: i64 = 10; // max ground truth objects per image
const PATCH_SIZE: i64 = 14;

pub const MaskDecodeResult = struct {
    mask: []f32, // mask_h * mask_w, values 0.0 or 1.0
    bbox: [4]f32, // [cx, cy, w, h] normalized 0-1
};

/// Decode a raw PNG (already base64-decoded) into a binary mask + bounding box.
/// Caller must free the returned mask slice.
pub fn decodeMaskForTraining(allocator: std.mem.Allocator, png_bytes: []const u8, dst_h: usize, dst_w: usize) !MaskDecodeResult {

    // Decode PNG via stb_image (request 1 channel = grayscale)
    var img_w: c_int = 0;
    var img_h: c_int = 0;
    var img_c: c_int = 0;
    const pixels = stbi.stbi_load_from_memory(
        png_bytes.ptr,
        @intCast(png_bytes.len),
        &img_w,
        &img_h,
        &img_c,
        1, // force grayscale
    ) orelse return error.MaskDecodeFailed;
    defer stbi.stbi_image_free(pixels);

    const src_w: usize = @intCast(img_w);
    const src_h: usize = @intCast(img_h);

    // Allocate output mask
    const mask = try allocator.alloc(f32, dst_h * dst_w);
    errdefer allocator.free(mask);

    // Nearest-neighbor resize from source to dst_h × dst_w, binarize
    var min_x: usize = dst_w;
    var max_x: usize = 0;
    var min_y: usize = dst_h;
    var max_y: usize = 0;

    for (0..dst_h) |y| {
        const src_y = y * src_h / dst_h;
        for (0..dst_w) |x| {
            const src_x = x * src_w / dst_w;
            const pixel_val = pixels[src_y * src_w + src_x];
            const is_fg: bool = pixel_val > 127;
            mask[y * dst_w + x] = if (is_fg) 1.0 else 0.0;
            if (is_fg) {
                if (x < min_x) min_x = x;
                if (x > max_x) max_x = x;
                if (y < min_y) min_y = y;
                if (y > max_y) max_y = y;
            }
        }
    }

    // Compute cxcywh bbox normalized by dst dims
    var bbox = [4]f32{ 0, 0, 0, 0 };
    if (max_x >= min_x and max_y >= min_y) {
        const dst_wf: f32 = @floatFromInt(dst_w);
        const dst_hf: f32 = @floatFromInt(dst_h);
        const x1: f32 = @as(f32, @floatFromInt(min_x)) / dst_wf;
        const y1: f32 = @as(f32, @floatFromInt(min_y)) / dst_hf;
        const x2: f32 = @as(f32, @floatFromInt(max_x + 1)) / dst_wf;
        const y2: f32 = @as(f32, @floatFromInt(max_y + 1)) / dst_hf;
        bbox = .{
            (x1 + x2) / 2.0, // cx
            (y1 + y2) / 2.0, // cy
            x2 - x1, // w
            y2 - y1, // h
        };
    }

    return MaskDecodeResult{
        .mask = mask,
        .bbox = bbox,
    };
}

pub const TrainLosses = struct {
    total_loss: f32,
    loss_class: f32,
    loss_bbox: f32,
    loss_giou: f32,
    loss_mask_bce: f32,
    loss_mask_dice: f32,
};

pub const Sam3TrainEngine = struct {
    allocator: std.mem.Allocator,

    // Runtime training dimensions (set from user-selected image_size)
    train_image_size: i64 = 504,
    train_mask_h: i64 = 144,
    train_mask_w: i64 = 144,

    plugin: zml.Plugin = undefined,
    executable: zml.Executable = undefined,
    device_weights: []?*pjrt.PJRT_Buffer = undefined,

    // Input buffer indices
    image_buf_idx: usize = 0,
    text_buf_idx: usize = 0,
    gt_boxes_buf_idx: usize = 0,
    gt_masks_buf_idx: usize = 0,
    gt_valid_buf_idx: usize = 0,
    step_buf_idx: usize = 0,
    num_outputs: usize = 9,

    // Backward pass / optimizer state
    has_backward: bool = false,
    param_output_start: usize = 9, // first output index for updated params (after 6 losses + 3 predictions)
    // Maps param output index (relative to param_output_start) → device_weights index
    param_weight_map: []usize = &.{},
    num_param_outputs: usize = 0,

    weight_meta: []WeightMeta = &.{},
    total_weight_bytes: usize = 0,

    pub const WeightMeta = struct {
        name: []const u8, // duped safetensors key (owned)
        dtype_str: []const u8, // static string like "F32" (not owned)
        shape_len: usize,
        shape: [8]i64, // inline, max rank 8
        byte_size: usize,
        buf_idx: usize, // index into device_weights
    };

    pub fn init(allocator: std.mem.Allocator, weights_path: []const u8, image_size: i64) !*Sam3TrainEngine {
        const self = try allocator.create(Sam3TrainEngine);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator };

        // Compute mask dimensions from image size: (image_size / patch_size) * 4
        self.train_image_size = image_size;
        self.train_mask_h = @divExact(image_size, PATCH_SIZE) * 4;
        self.train_mask_w = self.train_mask_h;

        self.plugin = zml.Plugin.load("../zig-ml/lib/libpjrt_cuda.so") catch
            try zml.loadPlugin(.cuda);

        const config = sam3.Sam3ImageConfig{
            .image_size = self.train_image_size,
            .num_queries = NUM_QUERIES,
        };

            var g = zml.ComputeGraph.init(allocator);
            defer g.deinit();

            const Shape = zml.Node.Shape;
            const graph_alloc = g.arena.allocator();

            // Inputs (resolution set by user)
            const image = g.addInput("image", Shape.init(.{ 1, 3, self.train_image_size, self.train_image_size }, .f32));
            const text_tokens = g.addInput("text_tokens", Shape.init(.{ 1, TEXT_SEQ_LEN }, .i64));

            // Ground truth inputs
            const gt_boxes = g.addInput("gt_boxes", Shape.init(.{ 1, TRAIN_MAX_GT, 4 }, .f32));
            const gt_masks = g.addInput("gt_masks", Shape.init(.{ 1, TRAIN_MAX_GT, self.train_mask_h, self.train_mask_w }, .f32));
            const gt_valid = g.addInput("gt_valid", Shape.init(.{ 1, TRAIN_MAX_GT }, .f32));
            const step_input = g.addInput("step", Shape.init(.{1}, .i64));

            // Forward pass
            std.log.info("SAM3 Train: Building forward pass...", .{});
            const output = try sam3.addSam3Image(
                &g, image, text_tokens,
                null, null, null, null, null,
                "detector_model", config, allocator,
            );

            // Loss computation
            std.log.info("SAM3 Train: Building loss computation...", .{});
            const losses = sam3.addSAM3Loss(
                &g,
                output.pred_logits,
                output.pred_boxes,
                output.pred_masks,
                gt_boxes,
                gt_masks,
                gt_valid,
                sam3.HungarianMatcherConfig{
                    .cost_class = 2.0,
                    .cost_bbox = 5.0,
                    .cost_giou = 2.0,
                },
                sam3.LossConfig{
                    .weight_class = 2.0,
                    .weight_bbox = 5.0,
                    .weight_giou = 2.0,
                    .weight_mask_bce = 5.0,
                    .weight_mask_dice = 5.0,
                    .focal_alpha = 0.25,
                    .focal_gamma = 2.0,
                },
            );

            // 6 loss outputs (always present)
            g.setOutput(losses.total_loss);
            g.setOutput(losses.loss_class);
            g.setOutput(losses.loss_bbox);
            g.setOutput(losses.loss_giou);
            g.setOutput(losses.loss_mask_bce);
            g.setOutput(losses.loss_mask_dice);

            // 3 prediction outputs (indices 6-8) for post-training inference
            g.setOutput(output.pred_logits); // [1, 200, 1]
            g.setOutput(output.pred_boxes); // [1, 200, 4]
            g.setOutput(output.pred_masks); // [1, 200, 144, 144]

            // Attempt backward pass + SGD optimizer
            // Only train decoder layers — freeze the backbone (ViT, text encoder, geometry encoder)
            // to fit in GPU memory. Decoder layers: detr_encoder, detr_decoder, mask_decoder.
            std.log.info("SAM3 Train: Collecting trainable parameters (decoder only)...", .{});
            var trainable_params: std.ArrayListUnmanaged(*const zml.Node) = .{};
            var trainable_buf_indices: std.ArrayListUnmanaged(usize) = .{};
            var total_weights: usize = 0;
            for (g.buffers.items, 0..) |entry, buf_idx| {
                switch (entry.source) {
                    .weight => |name| {
                        total_weights += 1;
                        // Only train decoder layers, freeze backbone/text/geometry
                        const trainable = std.mem.indexOf(u8, name, ".detr_encoder.") != null or
                            std.mem.indexOf(u8, name, ".detr_decoder.") != null or
                            std.mem.indexOf(u8, name, ".mask_decoder.") != null;
                        if (trainable) {
                            try trainable_params.append(graph_alloc, entry.node);
                            try trainable_buf_indices.append(graph_alloc, buf_idx);
                        }
                    },
                    .input => {},
                }
            }
            std.log.info("SAM3 Train: Found {} trainable / {} total weight parameters", .{ trainable_params.items.len, total_weights });

            // Save output count before backward attempt so we can restore on failure
            const saved_output_count = g.outputs.items.len;

            const backward_ok = blk: {
                std.log.info("SAM3 Train: Building backward pass...", .{});
                const grad_map = g.backward(losses.total_loss, trainable_params.items) catch |err| {
                    std.log.warn("SAM3 Train: Backward pass failed ({s}), falling back to forward-only", .{@errorName(err)});
                    break :blk false;
                };

                // SGD with cosine-annealed learning rate schedule from zig-ml
                std.log.info("SAM3 Train: Building SGD+LR schedule ({} params)...", .{trainable_params.items.len});
                const ops = zml.ops;

                // Compute scheduled learning rate: warmup → cosine decay
                const lr_scheduled = sam3.addLRSchedule(&g, step_input, .{
                    .base_lr = 1e-5,
                    .min_lr = 1e-7,
                    .warmup_steps = 20,
                    .total_steps = 10000,
                }, .f32);

                self.param_output_start = g.outputs.items.len;
                var num_updated: usize = 0;
                for (trainable_params.items) |param| {
                    const grad_node = grad_map.get(param) orelse continue;
                    if (num_updated % 100 == 0) {
                        std.log.info("SAM3 Train: param {}/{} (rank={}, dtype={})", .{ num_updated, trainable_params.items.len, param.shape.len, @intFromEnum(param.shape.dtype) });
                    }

                    // Gradient clipping to [-0.5, 0.5] to stabilize training with few samples
                    const cp = ops.constantScalar(&g, grad_node.shape, 0.5);
                    const cn = ops.constantScalar(&g, grad_node.shape, -0.5);
                    const clipped = ops.addClamp(&g, grad_node, cn, cp);

                    // Broadcast scheduled LR to parameter shape and apply SGD update
                    const lr_bc = ops.addBroadcast(&g, lr_scheduled, param.shape);
                    const lr_typed = ops.addConvert(&g, lr_bc, param.shape.dtype);
                    const scaled_grad = ops.addMul(&g, lr_typed, clipped);
                    const updated = ops.addSub(&g, param, scaled_grad);
                    g.setOutput(updated);
                    num_updated += 1;
                }
                self.num_param_outputs = num_updated;

                // Build mapping: param output index → device_weights buffer index
                // Only include params that had gradients (matching the outputs above)
                self.param_weight_map = allocator.alloc(usize, num_updated) catch {
                    g.outputs.items.len = saved_output_count;
                    break :blk false;
                };
                var map_idx: usize = 0;
                for (trainable_params.items, 0..) |param, pi| {
                    if (grad_map.get(param) != null) {
                        self.param_weight_map[map_idx] = trainable_buf_indices.items[pi];
                        map_idx += 1;
                    }
                }

                self.has_backward = true;
                std.log.info("SAM3 Train: Backward pass + optimizer built ({} param outputs)", .{self.num_param_outputs});
                break :blk true;
            };

            if (!backward_ok) {
                // Restore output count in case backward partially added outputs before failing
                g.outputs.items.len = saved_output_count;
                std.log.info("SAM3 Train: Using forward-only mode (loss computed but weights not updated)", .{});
            }

            self.num_outputs = 9 + (if (self.has_backward) self.num_param_outputs else 0);

            // Store input indices
            self.image_buf_idx = g.getInputIndex("image") orelse return error.InputNotFound;
            self.text_buf_idx = g.getInputIndex("text_tokens") orelse return error.InputNotFound;
            self.gt_boxes_buf_idx = g.getInputIndex("gt_boxes") orelse return error.InputNotFound;
            self.gt_masks_buf_idx = g.getInputIndex("gt_masks") orelse return error.InputNotFound;
            self.gt_valid_buf_idx = g.getInputIndex("gt_valid") orelse return error.InputNotFound;
            self.step_buf_idx = g.getInputIndex("step") orelse return error.InputNotFound;

            // Compile
            std.log.info("SAM3 Train: Emitting MLIR...", .{});
            const module = try zml.emitMLIR(allocator, &g);
            std.log.info("SAM3 Train: Compiling (this may take a while)...", .{});
            self.executable = try zml.compile(allocator, module, &self.plugin);

            // Load and upload weights
            std.log.info("SAM3 Train: Loading weights from {s}...", .{weights_path});
            const host_weights = try g.loadWeights(weights_path, allocator);
            defer allocator.free(host_weights);
            std.log.info("SAM3 Train: Uploading weights to GPU...", .{});
            self.device_weights = try g.uploadWeights(
                host_weights,
                self.plugin.api,
                self.executable.client,
                allocator,
            );

            // Capture weight metadata for later saving to safetensors
            {
                var meta_list: std.ArrayList(WeightMeta) = .{};
                var total_bytes: usize = 0;
                for (g.buffers.items, 0..) |entry, buf_idx| {
                    switch (entry.source) {
                        .weight => |name| {
                            const size = entry.node.shape.byteSize();
                            const dims = entry.node.shape.getDims();
                            var shape: [8]i64 = [_]i64{0} ** 8;
                            const shape_len: usize = @min(dims.len, 8);
                            for (0..shape_len) |di| {
                                shape[di] = dims[di];
                            }
                            const dtype_str: []const u8 = switch (entry.node.shape.dtype) {
                                .f32 => "F32",
                                .f16 => "F16",
                                .bf16 => "BF16",
                                .f64 => "F64",
                                .i64 => "I64",
                                .i32 => "I32",
                                .i16 => "I16",
                                .i8 => "I8",
                                .u8 => "U8",
                                .bool => "BOOL",
                                else => "F32",
                            };
                            try meta_list.append(allocator, .{
                                .name = try allocator.dupe(u8, name),
                                .dtype_str = dtype_str,
                                .shape_len = shape_len,
                                .shape = shape,
                                .byte_size = size,
                                .buf_idx = buf_idx,
                            });
                            total_bytes += size;
                        },
                        .input => {},
                    }
                }
                self.weight_meta = try meta_list.toOwnedSlice(allocator);
                self.total_weight_bytes = total_bytes;
                std.log.info("SAM3 Train: Captured {d} weight tensors ({d} bytes) for saving", .{ self.weight_meta.len, self.total_weight_bytes });
            }

        std.log.info("SAM3 Train: Engine ready (backward={})", .{self.has_backward});

        return self;
    }

    pub fn deinit(self: *Sam3TrainEngine) void {
        // Free GPU weight buffers
        for (self.device_weights) |maybe_buf| {
            if (maybe_buf) |buf| {
                destroyPjrtBuffer(self.plugin.api, buf);
            }
        }
        self.allocator.free(self.device_weights);
        self.executable.deinit();
        self.plugin.deinit();
        if (self.param_weight_map.len > 0) self.allocator.free(self.param_weight_map);
        for (self.weight_meta) |meta| {
            self.allocator.free(meta.name);
        }
        if (self.weight_meta.len > 0) self.allocator.free(self.weight_meta);
        self.allocator.destroy(self);
    }

    /// Run one training step. Returns loss values.
    /// If backward pass is available, weights are updated in-place on the GPU.
    pub fn step(
        self: *Sam3TrainEngine,
        image_data: []const f32,
        gt_boxes_data: []const f32,
        gt_masks_data: []const f32,
        gt_valid_data: []const f32,
        step_num: i64,
    ) !TrainLosses {
        const allocator = self.allocator;
        const Shape = zml.Node.Shape;

        // Upload inputs
        const image_buf = try self.executable.bufferFromHost(
            std.mem.sliceAsBytes(image_data),
            Shape.init(.{ 1, 3, self.train_image_size, self.train_image_size }, .f32),
        );
        var text_data: [TEXT_SEQ_LEN]i64 = [_]i64{0} ** TEXT_SEQ_LEN;
        text_data[0] = 49406; // SOT
        text_data[1] = 49407; // EOT
        const text_buf = try self.executable.bufferFromHost(
            std.mem.sliceAsBytes(&text_data),
            Shape.init(.{ 1, TEXT_SEQ_LEN }, .i64),
        );
        const gt_boxes_buf = try self.executable.bufferFromHost(
            std.mem.sliceAsBytes(gt_boxes_data),
            Shape.init(.{ 1, TRAIN_MAX_GT, 4 }, .f32),
        );
        const gt_masks_buf = try self.executable.bufferFromHost(
            std.mem.sliceAsBytes(gt_masks_data),
            Shape.init(.{ 1, TRAIN_MAX_GT, self.train_mask_h, self.train_mask_w }, .f32),
        );
        const gt_valid_buf = try self.executable.bufferFromHost(
            std.mem.sliceAsBytes(gt_valid_data),
            Shape.init(.{ 1, TRAIN_MAX_GT }, .f32),
        );
        const step_data = [_]i64{step_num};
        const step_buf = try self.executable.bufferFromHost(
            std.mem.sliceAsBytes(&step_data),
            Shape.init(.{1}, .i64),
        );

        // Prepare input buffer array (weights + runtime inputs)
        const bufs = try allocator.dupe(?*pjrt.PJRT_Buffer, self.device_weights);
        defer allocator.free(bufs);

        bufs[self.image_buf_idx] = image_buf;
        bufs[self.text_buf_idx] = text_buf;
        bufs[self.gt_boxes_buf_idx] = gt_boxes_buf;
        bufs[self.gt_masks_buf_idx] = gt_masks_buf;
        bufs[self.gt_valid_buf_idx] = gt_valid_buf;
        bufs[self.step_buf_idx] = step_buf;

        // Execute
        const outputs = try self.executable.execute(bufs, allocator, self.num_outputs);
        defer allocator.free(outputs);

        // Free input buffers — execution is synchronous, data has been consumed
        destroyPjrtBuffer(self.plugin.api, image_buf);
        destroyPjrtBuffer(self.plugin.api, text_buf);
        destroyPjrtBuffer(self.plugin.api, gt_boxes_buf);
        destroyPjrtBuffer(self.plugin.api, gt_masks_buf);
        destroyPjrtBuffer(self.plugin.api, gt_valid_buf);
        destroyPjrtBuffer(self.plugin.api, step_buf);

        // Download 6 loss scalars
        var losses: TrainLosses = undefined;
        var loss_buf: [1]f32 = undefined;

        try self.executable.bufferToHost(outputs[0], std.mem.sliceAsBytes(&loss_buf));
        losses.total_loss = loss_buf[0];
        try self.executable.bufferToHost(outputs[1], std.mem.sliceAsBytes(&loss_buf));
        losses.loss_class = loss_buf[0];
        try self.executable.bufferToHost(outputs[2], std.mem.sliceAsBytes(&loss_buf));
        losses.loss_bbox = loss_buf[0];
        try self.executable.bufferToHost(outputs[3], std.mem.sliceAsBytes(&loss_buf));
        losses.loss_giou = loss_buf[0];
        try self.executable.bufferToHost(outputs[4], std.mem.sliceAsBytes(&loss_buf));
        losses.loss_mask_bce = loss_buf[0];
        try self.executable.bufferToHost(outputs[5], std.mem.sliceAsBytes(&loss_buf));
        losses.loss_mask_dice = loss_buf[0];

        // Free loss output buffers (0-5) — data has been downloaded to host
        // Free prediction output buffers (6-8) — not needed during training
        for (0..9) |i| {
            destroyPjrtBuffer(self.plugin.api, outputs[i]);
        }

        // Feed updated weight params back for next step
        if (self.has_backward) {
            for (self.param_weight_map, 0..) |buf_idx, i| {
                // Free the old weight buffer before replacing it
                if (self.device_weights[buf_idx]) |old_buf| {
                    destroyPjrtBuffer(self.plugin.api, old_buf);
                }
                self.device_weights[buf_idx] = outputs[self.param_output_start + i];
            }
        } else {
            // Forward-only: no param outputs to keep, losses already freed above
        }

        return losses;
    }

    /// Preprocess a JPEG image: decode, resize to target size, normalize to [-1,1].
    pub fn preprocessJpeg(allocator: std.mem.Allocator, jpeg_data: []const u8, target_size: usize) ![]f32 {
        var img_w: c_int = 0;
        var img_h: c_int = 0;
        var img_c: c_int = 0;
        const pixels = stbi.stbi_load_from_memory(
            jpeg_data.ptr,
            @intCast(jpeg_data.len),
            &img_w,
            &img_h,
            &img_c,
            3,
        ) orelse return error.ImageDecodeFailed;
        defer stbi.stbi_image_free(pixels);

        const src_w: usize = @intCast(img_w);
        const src_h: usize = @intCast(img_h);
        const target: usize = target_size;
        const num_pixels = target * target;

        const image_data = try allocator.alloc(f32, 3 * num_pixels);

        const src_wf = @as(f32, @floatFromInt(src_w));
        const src_hf = @as(f32, @floatFromInt(src_h));
        const target_f = @as(f32, @floatFromInt(target));
        const scale_x = src_wf / target_f;
        const scale_y = src_hf / target_f;

        for (0..target) |y| {
            for (0..target) |x| {
                const src_xf = (@as(f32, @floatFromInt(x)) + 0.5) * scale_x - 0.5;
                const src_yf = (@as(f32, @floatFromInt(y)) + 0.5) * scale_y - 0.5;

                const x0 = @as(usize, @intFromFloat(@max(src_xf, 0)));
                const y0 = @as(usize, @intFromFloat(@max(src_yf, 0)));
                const x1 = @min(x0 + 1, src_w - 1);
                const y1 = @min(y0 + 1, src_h - 1);

                const xf = @max(src_xf - @as(f32, @floatFromInt(x0)), 0);
                const yf = @max(src_yf - @as(f32, @floatFromInt(y0)), 0);

                const di = y * target + x;

                for (0..3) |c| {
                    const p00 = @as(f32, @floatFromInt(pixels[(y0 * src_w + x0) * 3 + c]));
                    const p10 = @as(f32, @floatFromInt(pixels[(y0 * src_w + x1) * 3 + c]));
                    const p01 = @as(f32, @floatFromInt(pixels[(y1 * src_w + x0) * 3 + c]));
                    const p11 = @as(f32, @floatFromInt(pixels[(y1 * src_w + x1) * 3 + c]));

                    const val = p00 * (1 - xf) * (1 - yf) +
                        p10 * xf * (1 - yf) +
                        p01 * (1 - xf) * yf +
                        p11 * xf * yf;

                    image_data[c * num_pixels + di] = val / 127.5 - 1.0;
                }
            }
        }

        return image_data;
    }

    pub const TrainPrediction = struct {
        pred_logits: []f32, // NUM_QUERIES (200) raw logits
        pred_boxes: []f32, // NUM_QUERIES * 4 (cxcywh normalized)
        pred_masks: []f32, // NUM_QUERIES * TRAIN_MASK_H * TRAIN_MASK_W
    };

    pub const TrainDetection = struct {
        box: [4]f32, // x1, y1, x2, y2 normalized [0,1]
        score: f32, // sigmoid(logit)
        mask_idx: usize, // index into pred_masks for this query
    };

    /// Run inference using the trained weights (call after training, before deinit).
    /// Uploads image + zeroed GT, executes graph, downloads prediction outputs.
    pub fn infer(self: *Sam3TrainEngine, image_data: []const f32) !TrainPrediction {
        const allocator = self.allocator;
        const Shape = zml.Node.Shape;

        const mask_h: usize = @intCast(self.train_mask_h);
        const mask_w: usize = @intCast(self.train_mask_w);
        const max_gt: usize = @intCast(TRAIN_MAX_GT);

        // Upload image
        const image_buf = try self.executable.bufferFromHost(
            std.mem.sliceAsBytes(image_data),
            Shape.init(.{ 1, 3, self.train_image_size, self.train_image_size }, .f32),
        );

        // Text tokens (SOT+EOT)
        var text_data: [TEXT_SEQ_LEN]i64 = [_]i64{0} ** TEXT_SEQ_LEN;
        text_data[0] = 49406;
        text_data[1] = 49407;
        const text_buf = try self.executable.bufferFromHost(
            std.mem.sliceAsBytes(&text_data),
            Shape.init(.{ 1, TEXT_SEQ_LEN }, .i64),
        );

        // Zeroed GT inputs (loss outputs will be garbage — we ignore them)
        const gt_boxes_zeros = try allocator.alloc(f32, max_gt * 4);
        defer allocator.free(gt_boxes_zeros);
        @memset(gt_boxes_zeros, 0);
        const gt_boxes_buf = try self.executable.bufferFromHost(
            std.mem.sliceAsBytes(gt_boxes_zeros),
            Shape.init(.{ 1, TRAIN_MAX_GT, 4 }, .f32),
        );

        const gt_masks_zeros = try allocator.alloc(f32, max_gt * mask_h * mask_w);
        defer allocator.free(gt_masks_zeros);
        @memset(gt_masks_zeros, 0);
        const gt_masks_buf = try self.executable.bufferFromHost(
            std.mem.sliceAsBytes(gt_masks_zeros),
            Shape.init(.{ 1, TRAIN_MAX_GT, self.train_mask_h, self.train_mask_w }, .f32),
        );

        const gt_valid_zeros = try allocator.alloc(f32, max_gt);
        defer allocator.free(gt_valid_zeros);
        @memset(gt_valid_zeros, 0);
        const gt_valid_buf = try self.executable.bufferFromHost(
            std.mem.sliceAsBytes(gt_valid_zeros),
            Shape.init(.{ 1, TRAIN_MAX_GT }, .f32),
        );

        const step_data = [_]i64{0};
        const step_buf = try self.executable.bufferFromHost(
            std.mem.sliceAsBytes(&step_data),
            Shape.init(.{1}, .i64),
        );

        // Prepare input buffer array
        const bufs = try allocator.dupe(?*pjrt.PJRT_Buffer, self.device_weights);
        defer allocator.free(bufs);

        bufs[self.image_buf_idx] = image_buf;
        bufs[self.text_buf_idx] = text_buf;
        bufs[self.gt_boxes_buf_idx] = gt_boxes_buf;
        bufs[self.gt_masks_buf_idx] = gt_masks_buf;
        bufs[self.gt_valid_buf_idx] = gt_valid_buf;
        bufs[self.step_buf_idx] = step_buf;

        // Execute
        const outputs = try self.executable.execute(bufs, allocator, self.num_outputs);
        defer allocator.free(outputs);

        // Free input buffers
        destroyPjrtBuffer(self.plugin.api, image_buf);
        destroyPjrtBuffer(self.plugin.api, text_buf);
        destroyPjrtBuffer(self.plugin.api, gt_boxes_buf);
        destroyPjrtBuffer(self.plugin.api, gt_masks_buf);
        destroyPjrtBuffer(self.plugin.api, gt_valid_buf);
        destroyPjrtBuffer(self.plugin.api, step_buf);

        // Download prediction outputs (indices 6-8)
        const nq: usize = @intCast(NUM_QUERIES);
        const pred_logits = try allocator.alloc(f32, nq);
        errdefer allocator.free(pred_logits);
        try self.executable.bufferToHost(outputs[6], std.mem.sliceAsBytes(pred_logits));

        const pred_boxes = try allocator.alloc(f32, nq * 4);
        errdefer allocator.free(pred_boxes);
        try self.executable.bufferToHost(outputs[7], std.mem.sliceAsBytes(pred_boxes));

        const pred_masks = try allocator.alloc(f32, nq * mask_h * mask_w);
        errdefer allocator.free(pred_masks);
        try self.executable.bufferToHost(outputs[8], std.mem.sliceAsBytes(pred_masks));

        // Destroy all output buffers (losses 0-5, predictions 6-8, params 9+)
        for (0..self.num_outputs) |i| {
            // Don't destroy param outputs — they're aliased into device_weights
            if (i >= self.param_output_start) continue;
            destroyPjrtBuffer(self.plugin.api, outputs[i]);
        }
        // Destroy param outputs too (we don't update weights during inference)
        if (self.has_backward) {
            for (self.param_output_start..self.num_outputs) |i| {
                destroyPjrtBuffer(self.plugin.api, outputs[i]);
            }
        }

        return .{
            .pred_logits = pred_logits,
            .pred_boxes = pred_boxes,
            .pred_masks = pred_masks,
        };
    }

    /// Save all trained weights to a safetensors file.
    /// Downloads weight buffers from GPU and writes them in safetensors format.
    pub fn saveTrainedWeights(self: *Sam3TrainEngine, path: []const u8) !void {
        if (self.weight_meta.len == 0) return error.NoWeightMetadata;

        const allocator = self.allocator;

        // Build JSON header
        var json_buf: std.ArrayList(u8) = .{};
        defer json_buf.deinit(allocator);
        const jw = json_buf.writer(allocator);

        try jw.writeByte('{');
        var data_offset: usize = 0;
        for (self.weight_meta, 0..) |meta, i| {
            if (i > 0) try jw.writeByte(',');
            try jw.writeByte('"');
            try jw.writeAll(meta.name);
            try jw.writeAll("\":{\"dtype\":\"");
            try jw.writeAll(meta.dtype_str);
            try jw.writeAll("\",\"shape\":[");
            for (0..meta.shape_len) |di| {
                if (di > 0) try jw.writeByte(',');
                try std.fmt.format(jw, "{d}", .{meta.shape[di]});
            }
            try jw.writeAll("],\"data_offsets\":[");
            try std.fmt.format(jw, "{d},{d}", .{ data_offset, data_offset + meta.byte_size });
            try jw.writeAll("]}");
            data_offset += meta.byte_size;
        }
        try jw.writeByte('}');

        // Pad header to 8-byte alignment
        const padding = (8 - (json_buf.items.len % 8)) % 8;
        for (0..padding) |_| {
            try jw.writeByte(' ');
        }

        // Write file
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        // 8-byte LE header length
        var hdr_len: [8]u8 = undefined;
        std.mem.writeInt(u64, &hdr_len, @intCast(json_buf.items.len), .little);
        try file.writeAll(&hdr_len);

        // JSON header
        try file.writeAll(json_buf.items);

        // Download each weight from GPU and write to file
        for (self.weight_meta) |meta| {
            const host_buf = try allocator.alloc(u8, meta.byte_size);
            defer allocator.free(host_buf);
            try self.executable.bufferToHost(
                self.device_weights[meta.buf_idx].?,
                host_buf,
            );
            try file.writeAll(host_buf);
        }

        std.log.info("SAM3 Train: Saved weights to {s} ({d} tensors, {d} bytes data)", .{
            path, self.weight_meta.len, self.total_weight_bytes,
        });
    }

    /// Load trained weights from a safetensors file, replacing the current weights on GPU.
    /// The file must contain the same tensor names as the current model's weight_meta.
    pub fn loadTrainedWeights(self: *Sam3TrainEngine, path: []const u8) !void {
        if (self.weight_meta.len == 0) return error.NoWeightMetadata;

        const allocator = self.allocator;
        const Shape = zml.Node.Shape;

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        // Read 8-byte LE header length
        var hdr_len_buf: [8]u8 = undefined;
        const hdr_read = try file.readAll(&hdr_len_buf);
        if (hdr_read != 8) return error.InvalidSafetensors;
        const hdr_len = std.mem.readInt(u64, &hdr_len_buf, .little);

        // Read JSON header
        const hdr_json = try allocator.alloc(u8, @intCast(hdr_len));
        defer allocator.free(hdr_json);
        const json_read = try file.readAll(hdr_json);
        if (json_read != hdr_json.len) return error.InvalidSafetensors;

        const data_start: u64 = 8 + hdr_len;

        // Parse JSON header
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, hdr_json, .{}) catch
            return error.InvalidSafetensors;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidSafetensors,
        };

        var loaded: usize = 0;
        for (self.weight_meta) |meta| {
            const tensor_val = root.get(meta.name) orelse continue;
            const tensor_obj = switch (tensor_val) {
                .object => |o| o,
                else => continue,
            };

            // Get data_offsets [start, end]
            const offsets_val = tensor_obj.get("data_offsets") orelse continue;
            const offsets_arr = switch (offsets_val) {
                .array => |a| a,
                else => continue,
            };
            if (offsets_arr.items.len < 2) continue;

            const offset_start: u64 = switch (offsets_arr.items[0]) {
                .integer => |i| @intCast(i),
                else => continue,
            };
            const offset_end: u64 = switch (offsets_arr.items[1]) {
                .integer => |i| @intCast(i),
                else => continue,
            };

            const byte_size: usize = @intCast(offset_end - offset_start);
            if (byte_size != meta.byte_size) {
                std.log.warn("loadTrainedWeights: size mismatch for '{s}': file={d} expected={d}", .{ meta.name, byte_size, meta.byte_size });
                continue;
            }

            // Read tensor data from file
            const host_buf = try allocator.alloc(u8, byte_size);
            defer allocator.free(host_buf);

            try file.seekTo(data_start + offset_start);
            const bytes_read = try file.readAll(host_buf);
            if (bytes_read != byte_size) continue;

            // Map dtype string to DataType
            const dtype: zml.Node.DataType = if (std.mem.eql(u8, meta.dtype_str, "F32"))
                .f32
            else if (std.mem.eql(u8, meta.dtype_str, "F16"))
                .f16
            else if (std.mem.eql(u8, meta.dtype_str, "BF16"))
                .bf16
            else if (std.mem.eql(u8, meta.dtype_str, "I64"))
                .i64
            else if (std.mem.eql(u8, meta.dtype_str, "I32"))
                .i32
            else
                .f32;

            // Build shape from runtime dimensions and upload to GPU
            const shape = Shape.initFromSlice(meta.shape[0..meta.shape_len], dtype);
            const new_buf = try self.executable.bufferFromHost(host_buf, shape);

            // Destroy old buffer and replace
            if (self.device_weights[meta.buf_idx]) |old_buf| {
                destroyPjrtBuffer(self.plugin.api, old_buf);
            }
            self.device_weights[meta.buf_idx] = new_buf;
            loaded += 1;
        }

        std.log.info("SAM3 Train: Loaded {d}/{d} trained weights from {s}", .{ loaded, self.weight_meta.len, path });
    }

    /// Post-process raw predictions: apply sigmoid, filter by threshold, convert cxcywh→xyxy.
    /// Returned detections are sorted by score descending. Caller owns the returned slice.
    pub fn postProcessPredictions(pred: TrainPrediction, alloc: std.mem.Allocator, score_threshold: f32) ![]TrainDetection {
        const nq: usize = @intCast(NUM_QUERIES);
        var det_list: std.ArrayList(TrainDetection) = .{};

        for (0..nq) |i| {
            const score = 1.0 / (1.0 + @exp(-pred.pred_logits[i]));
            if (score < score_threshold) continue;

            const b = pred.pred_boxes[i * 4 ..][0..4];
            const x1 = @max(b[0] - b[2] / 2.0, 0);
            const y1 = @max(b[1] - b[3] / 2.0, 0);
            const x2 = @min(b[0] + b[2] / 2.0, 1.0);
            const y2 = @min(b[1] + b[3] / 2.0, 1.0);

            try det_list.append(alloc, .{
                .box = .{ x1, y1, x2, y2 },
                .score = score,
                .mask_idx = i,
            });
        }

        // Sort by score descending
        const items = det_list.items;
        std.mem.sort(TrainDetection, items, {}, struct {
            fn cmp(_: void, a: TrainDetection, b_det: TrainDetection) bool {
                return a.score > b_det.score;
            }
        }.cmp);

        return try det_list.toOwnedSlice(alloc);
    }

    pub fn isAvailable() bool {
        return true;
    }
};

/// Release a PJRT device buffer (GPU memory).
fn destroyPjrtBuffer(api: anytype, buf: *pjrt.PJRT_Buffer) void {
    var args = pjrt.PJRT_Buffer_Destroy_Args{
        .struct_size = @intCast(pjrt.PJRT_Buffer_Destroy_Args_STRUCT_SIZE),
        .buffer = buf,
    };
    _ = api.PJRT_Buffer_Destroy.?(&args);
}

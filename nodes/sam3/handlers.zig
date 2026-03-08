const std = @import("std");
const server = @import("../../server.zig");
const httpz = @import("httpz");
const Handler = server.Handler;
const ServerContext = server.ServerContext;
const JsonWriter = server.JsonWriter;
const jsonWriter = server.jsonWriter;
pub const writeJsonString = server.writeJsonString;
const mod = @import("mod.zig");
const sam3_engine = @import("engine.zig");
const Sam3Engine = sam3_engine.Sam3Engine;
pub const Sam3TrainEngine = sam3_engine.Sam3TrainEngine;

fn getState(ctx: *ServerContext) *mod.State {
    return ctx.getModuleState(mod) orelse unreachable;
}

/// GET /api/sam3/status — feature detection with init state
pub fn sam3StatusHandler(handler: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    const s = getState(handler.server_ctx);
    s.init_mutex.lock();
    const state = s.init_state;
    s.init_mutex.unlock();
    const engine_ready = s.engine != null;
    const backend = if (engine_ready) "cuda" else "none";
    const state_str = switch (state) {
        .idle => "idle",
        .loading => "loading",
        .ready => "ready",
        .failed => "failed",
    };
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(res.arena,
        "{{\"available\":true,\"engine_ready\":{s},\"backend\":\"{s}\",\"state\":\"{s}\"}}",
        .{ if (engine_ready) "true" else "false", backend, state_str },
    );
}

/// POST /api/sam3/init — trigger lazy SAM3 initialization (idempotent)
pub fn sam3InitHandler(handler: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    const ctx = handler.server_ctx;
    const s = getState(ctx);
    s.init_mutex.lock();
    const state = s.init_state;
    if (state == .idle) {
        // Acquire GPU lock for annotation
        if (!ctx.gpu_lock.tryAcquire(.annotation)) {
            s.init_mutex.unlock();
            const holder = ctx.gpu_lock.getHolder().toStr();
            res.status = 409;
            res.content_type = .JSON;
            res.body = try std.fmt.allocPrint(res.arena, "{{\"error\":\"GPU busy\",\"holder\":\"{s}\"}}", .{holder});
            return;
        }
        s.init_state = .loading;
        s.init_mutex.unlock();
        ctx.broadcastGpuLock();
        s.init_thread = std.Thread.spawn(.{}, initSam3OnDemand, .{ ctx, s }) catch |err| {
            std.log.err("Failed to spawn SAM3 init thread: {}", .{err});
            s.init_mutex.lock();
            s.init_state = .failed;
            s.init_mutex.unlock();
            _ = ctx.gpu_lock.release(.annotation);
            ctx.broadcastGpuLock();
            res.content_type = .JSON;
            res.body = "{\"state\":\"failed\"}";
            return;
        };
        res.content_type = .JSON;
        res.body = "{\"state\":\"loading\"}";
    } else {
        s.init_mutex.unlock();
        const state_str = switch (state) {
            .idle => "idle",
            .loading => "loading",
            .ready => "ready",
            .failed => "failed",
        };
        res.content_type = .JSON;
        res.body = try std.fmt.allocPrint(res.arena, "{{\"state\":\"{s}\"}}", .{state_str});
    }
}

/// POST /api/sam3/deinit — unload SAM3 engine to free GPU memory
pub fn sam3DeinitHandler(handler: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    const ctx = handler.server_ctx;
    const s = getState(ctx);

    // Join init thread if it was running (must release mutex during join to avoid deadlock)
    s.init_mutex.lock();
    const init_thread = s.init_thread;
    s.init_thread = null;
    s.init_mutex.unlock();

    if (init_thread) |t| {
        t.join();
    }

    s.init_mutex.lock();
    if (s.engine) |engine| {
        engine.deinit();
        s.engine = null;
        s.init_state = .idle;
        std.log.info("SAM3: Engine deinitialized (GPU memory freed)", .{});
        ctx.broadcast("{\"type\":\"sam3_status\",\"state\":\"idle\"}");
    } else {
        s.init_state = .idle;
    }
    s.init_mutex.unlock();

    _ = ctx.gpu_lock.release(.annotation);
    ctx.broadcastGpuLock();

    res.content_type = .JSON;
    res.body = "{\"ok\":true,\"state\":\"idle\"}";
}

/// POST /api/sam3/encode — no-op, image loading happens in segment
pub fn sam3EncodeHandler(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

/// POST /api/sam3/segment — run decoder with point prompts
pub fn sam3SegmentHandler(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const s = getState(handler.server_ctx);
    const engine = s.engine orelse {
        res.status = 501;
        res.body = "{\"error\":\"SAM3 not available\"}";
        return;
    };

    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing body\"}";
        return;
    };

    // Parse request
    const parsed = std.json.parseFromSlice(std.json.Value, res.arena, body, .{}) catch {
        res.status = 400;
        res.body = "{\"error\":\"invalid JSON\"}";
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            res.status = 400;
            res.body = "{\"error\":\"expected object\"}";
            return;
        },
    };

    const image_hash = blk: {
        const val = obj.get("image_hash") orelse {
            res.status = 400;
            res.body = "{\"error\":\"missing image_hash\"}";
            return;
        };
        break :blk switch (val) {
            .string => |str| str,
            else => {
                res.status = 400;
                res.body = "{\"error\":\"image_hash must be string\"}";
                return;
            },
        };
    };

    const points_val = obj.get("points") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing points\"}";
        return;
    };
    const points_arr = switch (points_val) {
        .array => |a| a,
        else => {
            res.status = 400;
            res.body = "{\"error\":\"points must be array\"}";
            return;
        },
    };

    // Parse points
    var points: [16][2]f32 = undefined;
    var labels: [16]i32 = undefined;
    const n = @min(points_arr.items.len, 16);
    for (0..n) |i| {
        const pt = switch (points_arr.items[i]) {
            .object => |o| o,
            else => {
                res.status = 400;
                res.body = "{\"error\":\"point must be object\"}";
                return;
            },
        };
        points[i][0] = jsonFloat(pt.get("x") orelse {
            res.status = 400;
            res.body = "{\"error\":\"point missing x\"}";
            return;
        });
        points[i][1] = jsonFloat(pt.get("y") orelse {
            res.status = 400;
            res.body = "{\"error\":\"point missing y\"}";
            return;
        });
        labels[i] = @intCast(switch (pt.get("label") orelse {
            res.status = 400;
            res.body = "{\"error\":\"point missing label\"}";
            return;
        }) {
            .integer => |v| v,
            else => {
                res.status = 400;
                res.body = "{\"error\":\"label must be integer\"}";
                return;
            },
        });
    }

    // Load JPEG from disk
    const img_path = std.fmt.allocPrint(res.arena, "data/images/{s}.jpg", .{image_hash}) catch {
        res.status = 500;
        res.body = "{\"error\":\"alloc failed\"}";
        return;
    };
    const file = std.fs.cwd().openFile(img_path, .{}) catch {
        res.status = 404;
        res.body = "{\"error\":\"image not found\"}";
        return;
    };
    defer file.close();
    const stat = file.stat() catch {
        res.status = 500;
        res.body = "{\"error\":\"stat failed\"}";
        return;
    };
    const jpeg_data = res.arena.alloc(u8, stat.size) catch {
        res.status = 500;
        res.body = "{\"error\":\"alloc failed\"}";
        return;
    };
    _ = file.readAll(jpeg_data) catch {
        res.status = 500;
        res.body = "{\"error\":\"read failed\"}";
        return;
    };

    const result = engine.segment(jpeg_data, points[0..n], labels[0..n]) catch |err| {
        std.log.err("SAM3 segment error: {}", .{err});
        res.status = 500;
        res.body = "{\"error\":\"segmentation failed\"}";
        return;
    };
    defer engine.allocator.free(result.mask);

    // Encode mask as PNG then base64
    const png_data = encodeMaskPng(res.arena, result.mask, result.width, result.height) catch {
        res.status = 500;
        res.body = "{\"error\":\"PNG encoding failed\"}";
        return;
    };

    const base64_len = std.base64.standard.Encoder.calcSize(png_data.len);
    const base64_buf = res.arena.alloc(u8, base64_len) catch {
        res.status = 500;
        res.body = "{\"error\":\"alloc failed\"}";
        return;
    };
    _ = std.base64.standard.Encoder.encode(base64_buf, png_data);

    // Build response JSON with mask + all detections
    var out: std.ArrayList(u8) = .{};
    const w = jsonWriter(&out, res.arena);
    try w.writeAll("{\"mask\":\"");
    try w.writeAll(base64_buf);
    try w.writeAll("\",\"iou\":");
    try std.fmt.format(w, "{d:.4}", .{result.iou});
    try w.writeAll(",\"detections\":[");
    for (result.detections, 0..) |det, di| {
        if (di > 0) try w.writeByte(',');
        try w.writeAll("{\"box\":[");
        try std.fmt.format(w, "{d:.4},{d:.4},{d:.4},{d:.4}", .{ det.box[0], det.box[1], det.box[2], det.box[3] });
        try w.writeAll("],\"score\":");
        try std.fmt.format(w, "{d:.4}", .{det.score});
        try w.writeAll(",\"selected\":");
        try w.writeAll(if (det.selected) "true" else "false");
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    res.content_type = .JSON;
    res.body = out.items;
    engine.allocator.free(result.detections);
}

pub fn initSam3OnDemand(ctx: *ServerContext, s: *mod.State) void {
    std.log.info("SAM3: Starting on-demand initialization...", .{});
    ctx.broadcast("{\"type\":\"sam3_status\",\"state\":\"loading\",\"message\":\"Compiling SAM3 model...\"}");
    const sam3_alloc = std.heap.page_allocator;
    if (Sam3Engine.init(sam3_alloc, "weights/sam3.safetensors")) |engine| {
        s.init_mutex.lock();
        s.engine = engine;
        s.init_state = .ready;
        s.init_mutex.unlock();
        std.log.info("SAM3: Engine ready", .{});
        ctx.broadcast("{\"type\":\"sam3_status\",\"state\":\"ready\"}");
    } else |err| {
        s.init_mutex.lock();
        s.init_state = .failed;
        s.init_mutex.unlock();
        _ = ctx.gpu_lock.release(.annotation);
        ctx.broadcastGpuLock();
        std.log.warn("SAM3 engine init failed: {}", .{err});
        ctx.broadcast("{\"type\":\"sam3_status\",\"state\":\"failed\"}");
    }
}

fn jsonFloat(val: std.json.Value) f32 {
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

/// Encode a grayscale binary mask as a minimal uncompressed PNG
pub fn encodeMaskPng(allocator: std.mem.Allocator, mask: []const u8, width: u32, height: u32) ![]const u8 {
    // Minimal grayscale PNG: signature + IHDR + IDAT (uncompressed) + IEND
    const row_size = 1 + width; // filter byte + pixel data per row
    const raw_size = row_size * height;

    // Deflate stored block: 5-byte header per block (max 65535 bytes per block)
    const max_block = 65535;
    const num_blocks = (raw_size + max_block - 1) / max_block;
    const deflate_size = raw_size + num_blocks * 5 + 2 + 4; // +2 zlib header, +4 adler32

    // Total IDAT data length
    const idat_data_len = deflate_size;

    // Calculate total PNG size
    const png_size = 8 + // signature
        (12 + 13) + // IHDR chunk
        (12 + idat_data_len) + // IDAT chunk
        12; // IEND chunk

    var buf = try allocator.alloc(u8, png_size);
    var pos: usize = 0;

    // PNG signature
    const sig = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    @memcpy(buf[pos..][0..8], &sig);
    pos += 8;

    // IHDR chunk
    pos = writeChunk(buf, pos, "IHDR", &ihdrData(width, height));

    // Build raw image data (filter byte 0 + row data)
    var raw_data = try allocator.alloc(u8, raw_size);
    defer allocator.free(raw_data);
    for (0..height) |y| {
        raw_data[y * row_size] = 0; // filter: none
        @memcpy(raw_data[y * row_size + 1 ..][0..width], mask[y * width ..][0..width]);
    }

    // Build zlib/deflate stream
    var zlib_data = try allocator.alloc(u8, deflate_size);
    defer allocator.free(zlib_data);
    var zpos: usize = 0;

    // Zlib header (CM=8, CINFO=7, no dict, FLEVEL=0)
    zlib_data[zpos] = 0x78;
    zpos += 1;
    zlib_data[zpos] = 0x01;
    zpos += 1;

    // Deflate stored blocks
    var remaining = raw_size;
    var src_pos: usize = 0;
    while (remaining > 0) {
        const block_size: u16 = @intCast(@min(remaining, max_block));
        const is_last: u8 = if (remaining <= max_block) 1 else 0;
        zlib_data[zpos] = is_last;
        zpos += 1;
        zlib_data[zpos] = @intCast(block_size & 0xFF);
        zpos += 1;
        zlib_data[zpos] = @intCast((block_size >> 8) & 0xFF);
        zpos += 1;
        const nblock_size = ~block_size;
        zlib_data[zpos] = @intCast(nblock_size & 0xFF);
        zpos += 1;
        zlib_data[zpos] = @intCast((nblock_size >> 8) & 0xFF);
        zpos += 1;
        @memcpy(zlib_data[zpos..][0..block_size], raw_data[src_pos..][0..block_size]);
        zpos += block_size;
        src_pos += block_size;
        remaining -= block_size;
    }

    // Adler-32 checksum
    var a: u32 = 1;
    var b_sum: u32 = 0;
    for (raw_data) |byte| {
        a = (a + byte) % 65521;
        b_sum = (b_sum + a) % 65521;
    }
    const adler = (b_sum << 16) | a;
    zlib_data[zpos] = @intCast((adler >> 24) & 0xFF);
    zpos += 1;
    zlib_data[zpos] = @intCast((adler >> 16) & 0xFF);
    zpos += 1;
    zlib_data[zpos] = @intCast((adler >> 8) & 0xFF);
    zpos += 1;
    zlib_data[zpos] = @intCast(adler & 0xFF);
    zpos += 1;

    // IDAT chunk
    pos = writeChunkSlice(buf, pos, "IDAT", zlib_data[0..zpos]);

    // IEND chunk
    pos = writeChunk(buf, pos, "IEND", &[_]u8{});

    return buf[0..pos];
}

fn ihdrData(width: u32, height: u32) [13]u8 {
    var data: [13]u8 = undefined;
    // Width (big-endian)
    data[0] = @intCast((width >> 24) & 0xFF);
    data[1] = @intCast((width >> 16) & 0xFF);
    data[2] = @intCast((width >> 8) & 0xFF);
    data[3] = @intCast(width & 0xFF);
    // Height (big-endian)
    data[4] = @intCast((height >> 24) & 0xFF);
    data[5] = @intCast((height >> 16) & 0xFF);
    data[6] = @intCast((height >> 8) & 0xFF);
    data[7] = @intCast(height & 0xFF);
    data[8] = 8; // bit depth
    data[9] = 0; // color type: grayscale
    data[10] = 0; // compression
    data[11] = 0; // filter
    data[12] = 0; // interlace
    return data;
}

fn writeChunk(buf: []u8, pos: usize, chunk_type: *const [4]u8, data: []const u8) usize {
    return writeChunkSlice(buf, pos, chunk_type, data);
}

fn writeChunkSlice(buf: []u8, start: usize, chunk_type: *const [4]u8, data: []const u8) usize {
    var pos = start;
    const len: u32 = @intCast(data.len);

    // Length (big-endian)
    buf[pos] = @intCast((len >> 24) & 0xFF);
    pos += 1;
    buf[pos] = @intCast((len >> 16) & 0xFF);
    pos += 1;
    buf[pos] = @intCast((len >> 8) & 0xFF);
    pos += 1;
    buf[pos] = @intCast(len & 0xFF);
    pos += 1;

    // Chunk type
    @memcpy(buf[pos..][0..4], chunk_type);
    pos += 4;

    // Data
    if (data.len > 0) {
        @memcpy(buf[pos..][0..data.len], data);
        pos += data.len;
    }

    // CRC32 over type + data
    var crc = crc32(chunk_type, 4);
    if (data.len > 0) {
        crc = crc32Update(crc, data);
    }
    buf[pos] = @intCast((crc >> 24) & 0xFF);
    pos += 1;
    buf[pos] = @intCast((crc >> 16) & 0xFF);
    pos += 1;
    buf[pos] = @intCast((crc >> 8) & 0xFF);
    pos += 1;
    buf[pos] = @intCast(crc & 0xFF);
    pos += 1;

    return pos;
}

fn crc32(data: []const u8, len: usize) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data[0..len]) |byte| {
        crc = crc32Table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

fn crc32Update(prev: u32, data: []const u8) u32 {
    var crc = prev ^ 0xFFFFFFFF;
    for (data) |byte| {
        crc = crc32Table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

const crc32Table = blk: {
    @setEvalBranchQuota(3000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            if (c & 1 != 0) {
                c = 0xEDB88320 ^ (c >> 1);
            } else {
                c = c >> 1;
            }
        }
        table[i] = c;
    }
    break :blk table;
};

// ============================================================================
// Training and prediction handlers (moved from server.zig)
// ============================================================================

pub fn startTrainHandler(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const ctx = handler.server_ctx;
    const ms = getState(ctx);
    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing body\"}";
        return;
    };

    // Parse node_id, epochs, and annotations from body
    const parsed = std.json.parseFromSlice(std.json.Value, res.arena, body, .{}) catch {
        res.status = 400;
        res.body = "{\"error\":\"invalid JSON\"}";
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            res.status = 400;
            res.body = "{\"error\":\"expected object\"}";
            return;
        },
    };

    const node_id_val = obj.get("node_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing node_id\"}";
        return;
    };
    const node_id_str = switch (node_id_val) {
        .string => |s| s,
        else => {
            res.status = 400;
            res.body = "{\"error\":\"node_id must be string\"}";
            return;
        },
    };

    const total_epochs: i64 = blk: {
        if (obj.get("epochs")) |v| {
            switch (v) {
                .integer => |i| break :blk i,
                else => {},
            }
        }
        break :blk 100;
    };

    const image_size: i64 = blk: {
        if (obj.get("image_size")) |v| {
            switch (v) {
                .integer => |i| {
                    // Must be a positive multiple of 14 (patch size)
                    if (i > 0 and @mod(i, 14) == 0) break :blk i;
                },
                else => {},
            }
        }
        break :blk 504;
    };

    const patience: i64 = blk: {
        if (obj.get("patience")) |v| {
            switch (v) {
                .integer => |i| {
                    if (i >= 0) break :blk i;
                },
                else => {},
            }
        }
        break :blk 0; // 0 = disabled
    };

    // Parse annotations array — extract image hashes, labels, and mask PNGs
    const annotations_val = obj.get("annotations");
    const annotations_arr = if (annotations_val) |v| switch (v) {
        .array => |a| a,
        else => null,
    } else null;

    // Log raw annotation summary for debugging
    if (annotations_arr) |arr| {
        std.log.info("Training: Received {d} annotation entries from frontend", .{arr.items.len});
        for (arr.items, 0..) |ann_val, ai| {
            if (ai >= 20) {
                std.log.info("Training:   ... and {d} more", .{arr.items.len - 20});
                break;
            }
            const ann_obj = switch (ann_val) {
                .object => |o| o,
                else => continue,
            };
            const h = if (ann_obj.get("imageHash")) |v| switch (v) { .string => |s| s, else => "?" } else "?";
            const l = if (ann_obj.get("label")) |v| switch (v) { .string => |s| s, else => "?" } else "?";
            const mask_count: usize = blk: {
                const mv = ann_obj.get("masks") orelse break :blk 0;
                const ma = switch (mv) { .array => |a| a, else => break :blk 0 };
                break :blk ma.items.len;
            };
            std.log.info("Training:   [{d}] hash={s} label={s} masks={d}", .{ ai, h[0..@min(h.len, 12)], l, mask_count });
        }
    } else {
        std.log.warn("Training: No annotations array in request!", .{});
    }

    const TrainSample = struct {
        image_hash: []const u8,
        is_anomaly: bool,
        /// Raw PNG bytes for each mask (base64-decoded). Up to TRAIN_MAX_GT.
        mask_pngs: [][]const u8,
        /// Label string per mask (parallel to mask_pngs). e.g. "screw", "scratch".
        mask_labels: [][]const u8,
    };

    const alloc = ctx.allocator;
    const parse_max_gt: usize = @intCast(sam3_engine.TRAIN_MAX_GT);

    var samples_list: std.ArrayList(TrainSample) = .{};
    if (annotations_arr) |arr| {
        for (arr.items) |ann_val| {
            const ann_obj = switch (ann_val) {
                .object => |o| o,
                else => continue,
            };
            const hash_val = ann_obj.get("imageHash") orelse continue;
            const hash = switch (hash_val) {
                .string => |s| s,
                else => continue,
            };

            // Extract label
            const is_anomaly = blk: {
                const label_val = ann_obj.get("label") orelse break :blk false;
                const label_str = switch (label_val) {
                    .string => |s| s,
                    else => break :blk false,
                };
                break :blk std.mem.eql(u8, label_str, "anomaly");
            };

            // Extract and decode mask PNGs + labels
            var mask_pngs_list: std.ArrayList([]const u8) = .{};
            var mask_labels_list: std.ArrayList([]const u8) = .{};
            if (is_anomaly) {
                const masks_val = ann_obj.get("masks") orelse null;
                const masks_arr = if (masks_val) |v| switch (v) {
                    .array => |a| a,
                    else => null,
                } else null;

                if (masks_arr) |marr| {
                    for (marr.items) |mask_entry_val| {
                        if (mask_pngs_list.items.len >= parse_max_gt) break;
                        const mask_obj = switch (mask_entry_val) {
                            .object => |o| o,
                            else => continue,
                        };
                        const b64_val = mask_obj.get("mask") orelse continue;
                        const b64_str = switch (b64_val) {
                            .string => |s| s,
                            else => continue,
                        };

                        // Extract per-mask label (default "anomaly")
                        const mask_label_str = blk: {
                            const lv = mask_obj.get("label") orelse break :blk "anomaly";
                            break :blk switch (lv) {
                                .string => |s| if (s.len > 0) s else "anomaly",
                                else => "anomaly",
                            };
                        };

                        // Strip data URI prefix if present ("data:image/png;base64,")
                        const b64_data = if (std.mem.indexOf(u8, b64_str, ",")) |comma_idx|
                            b64_str[comma_idx + 1 ..]
                        else
                            b64_str;

                        // Base64 decode
                        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64_data) catch continue;
                        const png_bytes = alloc.alloc(u8, decoded_len) catch continue;
                        std.base64.standard.Decoder.decode(png_bytes, b64_data) catch {
                            alloc.free(png_bytes);
                            continue;
                        };

                        const label_copy = alloc.dupe(u8, mask_label_str) catch {
                            alloc.free(png_bytes);
                            continue;
                        };

                        mask_pngs_list.append(alloc, png_bytes) catch {
                            alloc.free(png_bytes);
                            alloc.free(label_copy);
                            continue;
                        };
                        mask_labels_list.append(alloc, label_copy) catch {
                            // Undo the png append
                            _ = mask_pngs_list.pop();
                            alloc.free(png_bytes);
                            alloc.free(label_copy);
                            continue;
                        };
                    }
                }
            }

            // Check for duplicates — same image can have "good" + "anomaly" annotations
            // (different labelIds). Prefer anomaly (has masks) over good.
            var existing_idx: ?usize = null;
            for (samples_list.items, 0..) |existing, idx| {
                if (std.mem.eql(u8, existing.image_hash, hash)) {
                    existing_idx = idx;
                    break;
                }
            }

            if (existing_idx) |idx| {
                // Duplicate hash — upgrade good→anomaly if this entry has masks
                if (is_anomaly and mask_pngs_list.items.len > 0 and !samples_list.items[idx].is_anomaly) {
                    std.log.info("Training: Upgrading sample {s} from good→anomaly ({d} masks)", .{
                        hash[0..@min(hash.len, 8)], mask_pngs_list.items.len,
                    });
                    // Free the old (good) entry's data
                    alloc.free(samples_list.items[idx].image_hash);
                    alloc.free(samples_list.items[idx].mask_pngs); // empty slice
                    for (samples_list.items[idx].mask_labels) |lbl| alloc.free(lbl);
                    alloc.free(samples_list.items[idx].mask_labels);
                    // Replace with anomaly entry
                    const hash_copy = alloc.dupe(u8, hash) catch continue;
                    const mask_pngs_owned = mask_pngs_list.toOwnedSlice(alloc) catch continue;
                    const mask_labels_owned = mask_labels_list.toOwnedSlice(alloc) catch continue;
                    samples_list.items[idx] = .{
                        .image_hash = hash_copy,
                        .is_anomaly = true,
                        .mask_pngs = mask_pngs_owned,
                        .mask_labels = mask_labels_owned,
                    };
                } else {
                    // Already have anomaly or this is another good — skip
                    for (mask_pngs_list.items) |png| alloc.free(png);
                    for (mask_labels_list.items) |lbl| alloc.free(lbl);
                }
                continue;
            }

            const hash_copy = alloc.dupe(u8, hash) catch continue;
            const mask_pngs_owned = mask_pngs_list.toOwnedSlice(alloc) catch continue;
            const mask_labels_owned = mask_labels_list.toOwnedSlice(alloc) catch continue;
            samples_list.append(alloc, .{
                .image_hash = hash_copy,
                .is_anomaly = is_anomaly,
                .mask_pngs = mask_pngs_owned,
                .mask_labels = mask_labels_owned,
            }) catch continue;
        }
    }

    // Log dataset composition
    {
        var good_count: usize = 0;
        var anomaly_count: usize = 0;
        var total_masks: usize = 0;
        for (samples_list.items) |s| {
            if (s.is_anomaly) {
                anomaly_count += 1;
                total_masks += s.mask_pngs.len;
            } else {
                good_count += 1;
            }
        }
        std.log.info("Training: Dataset parsed — {d} samples ({d} good, {d} anomaly, {d} total masks)", .{
            samples_list.items.len, good_count, anomaly_count, total_masks,
        });
    }

    // Prepare durable copies for the training thread
    const node_id_copy = try alloc.dupe(u8, node_id_str);
    const samples_owned = try samples_list.toOwnedSlice(alloc);

    const TrainCtx = struct {
        server_ctx: *ServerContext,
        node_id: []const u8,
        total_epochs: i64,
        image_size: i64,
        patience: i64,
        samples: []TrainSample,
        allocator: std.mem.Allocator,

        fn freeCtx(self: *@This()) void {
            const a = self.allocator;
            a.free(self.node_id);
            for (self.samples) |sample| {
                a.free(sample.image_hash);
                for (sample.mask_pngs) |png| a.free(png);
                a.free(sample.mask_pngs);
                for (sample.mask_labels) |lbl| a.free(lbl);
                a.free(sample.mask_labels);
            }
            a.free(self.samples);
            a.destroy(self);
        }
    };

    const train_ctx = try alloc.create(TrainCtx);
    train_ctx.* = .{
        .server_ctx = ctx,
        .node_id = node_id_copy,
        .total_epochs = total_epochs,
        .image_size = image_size,
        .patience = patience,
        .samples = samples_owned,
        .allocator = alloc,
    };

    // Concurrency guard: reject if already training
    if (ms.is_training.swap(true, .acq_rel)) {
        train_ctx.freeCtx();
        res.status = 409;
        res.content_type = .JSON;
        res.body = "{\"error\":\"training already in progress\"}";
        return;
    }

    // Acquire GPU lock for training
    if (!ctx.gpu_lock.tryAcquire(.training)) {
        ms.is_training.store(false, .release);
        train_ctx.freeCtx();
        const holder = ctx.gpu_lock.getHolder().toStr();
        res.status = 409;
        res.content_type = .JSON;
        res.body = try std.fmt.allocPrint(res.arena, "{{\"error\":\"GPU busy\",\"holder\":\"{s}\"}}", .{holder});
        return;
    }
    ctx.broadcastGpuLock();

    // Clear the stop flag BEFORE spawning the thread
    ms.should_stop_training.store(false, .release);

    const thread = std.Thread.spawn(.{}, struct {
        fn run(tc: *TrainCtx) void {
            const tms = getState(tc.server_ctx);
            defer {
                tms.is_training.store(false, .release);
                _ = tc.server_ctx.gpu_lock.release(.training);
                tc.server_ctx.broadcastGpuLock();
            }
            runTraining(tc) catch |err| {
                std.log.err("Training failed: {}", .{err});
                const err_msg = std.fmt.allocPrint(tc.allocator,
                    "{{\"type\":\"training_error\",\"nodeId\":\"{s}\",\"error\":\"Training failed: {s}\"}}",
                    .{ tc.node_id, @errorName(err) },
                ) catch return;
                defer tc.allocator.free(err_msg);
                tc.server_ctx.broadcast(err_msg);
            };
            tc.freeCtx();
        }

        fn runTraining(tc: *TrainCtx) !void {
            const sctx = tc.server_ctx;
            const alloc_ = tc.allocator;
            const tms = getState(sctx);

            // Deinit SAM3 inference engine if loaded (free GPU for training)
            {
                tms.init_mutex.lock();
                if (tms.engine) |engine| {
                    engine.deinit();
                    tms.engine = null;
                    tms.init_state = .idle;
                    std.log.info("Training: Freed SAM3 inference engine for training", .{});
                    sctx.broadcast("{\"type\":\"sam3_status\",\"state\":\"idle\"}");
                }
                tms.init_mutex.unlock();
            }

            // Build training engine
            std.log.info("Training: Building Sam3TrainEngine...", .{});
            sctx.broadcast("{\"type\":\"training_status\",\"phase\":\"compiling\"}");
            const train_engine = Sam3TrainEngine.init(alloc_, "weights/sam3.safetensors", tc.image_size) catch |err| {
                std.log.err("Training: Failed to build train engine: {}", .{err});
                return err;
            };
            defer train_engine.deinit();
            std.log.info("Training: Engine ready, starting training loop", .{});

            const max_gt: usize = @intCast(sam3_engine.TRAIN_MAX_GT);
            const mask_h: usize = @intCast(train_engine.train_mask_h);
            const mask_w: usize = @intCast(train_engine.train_mask_w);

            // Log sample breakdown right before training starts
            {
                var n_good: usize = 0;
                var n_anom: usize = 0;
                var n_masks: usize = 0;
                for (tc.samples) |s| {
                    if (s.is_anomaly) {
                        n_anom += 1;
                        n_masks += s.mask_pngs.len;
                    } else {
                        n_good += 1;
                    }
                }
                std.log.info("Training: {d} samples ({d} good, {d} anomaly, {d} mask PNGs)", .{
                    tc.samples.len, n_good, n_anom, n_masks,
                });
            }

            // Training loop
            var step_num: i64 = 0;
            var best_loss: f64 = std.math.inf(f64);
            var epochs_without_improvement: i64 = 0;
            const min_delta: f64 = 1e-4;
            var stopped_early = false;
            var stopped_by_user = false;
            var final_epoch: usize = 0;
            for (0..@intCast(tc.total_epochs)) |epoch_idx| {
                // Check if user requested stop
                if (tms.should_stop_training.load(.acquire)) {
                    std.log.info("Training: Stopped by user at epoch {}", .{epoch_idx + 1});
                    stopped_by_user = true;
                    final_epoch = epoch_idx;
                    break;
                }
                var epoch_loss: f64 = 0;
                var epoch_loss_class: f64 = 0;
                var epoch_loss_bbox: f64 = 0;
                var epoch_loss_giou: f64 = 0;
                var epoch_loss_mask_bce: f64 = 0;
                var epoch_loss_mask_dice: f64 = 0;
                var sample_count: u32 = 0;

                for (tc.samples) |sample| {
                    step_num += 1;

                    // Load JPEG from disk
                    var path_buf: [128]u8 = undefined;
                    const img_path = std.fmt.bufPrint(&path_buf, "data/images/{s}.jpg", .{sample.image_hash}) catch continue;
                    const file = std.fs.cwd().openFile(img_path, .{}) catch continue;
                    defer file.close();
                    const stat = file.stat() catch continue;
                    const jpeg_data = alloc_.alloc(u8, stat.size) catch continue;
                    defer alloc_.free(jpeg_data);
                    _ = file.readAll(jpeg_data) catch continue;

                    // Preprocess image
                    const image_data = Sam3TrainEngine.preprocessJpeg(alloc_, jpeg_data, @intCast(train_engine.train_image_size)) catch continue;
                    defer alloc_.free(image_data);

                    // Prepare GT tensors (zeroed by default)
                    const gt_boxes_data = try alloc_.alloc(f32, max_gt * 4);
                    defer alloc_.free(gt_boxes_data);
                    @memset(gt_boxes_data, 0);

                    const gt_masks_data = try alloc_.alloc(f32, max_gt * mask_h * mask_w);
                    defer alloc_.free(gt_masks_data);
                    @memset(gt_masks_data, 0);

                    const gt_valid_data = try alloc_.alloc(f32, max_gt);
                    defer alloc_.free(gt_valid_data);
                    @memset(gt_valid_data, 0);

                    // Fill real GT for anomaly images with masks
                    if (sample.is_anomaly) {
                        var filled_gt: usize = 0;
                        for (sample.mask_pngs, 0..) |png_bytes, mi| {
                            if (mi >= max_gt) break;
                            const decoded = sam3_engine.decodeMaskForTraining(alloc_, png_bytes, mask_h, mask_w) catch |err| {
                                std.log.warn("Training: Failed to decode mask {d} ({d} bytes PNG): {}", .{ mi, png_bytes.len, err });
                                continue;
                            };
                            defer alloc_.free(decoded.mask);

                            // Count nonzero pixels for diagnostics
                            var fg_pixels: usize = 0;
                            for (decoded.mask) |v| {
                                if (v > 0.5) fg_pixels += 1;
                            }

                            // Copy mask into gt_masks_data[mi * mask_h * mask_w ..]
                            const mask_offset = mi * mask_h * mask_w;
                            @memcpy(gt_masks_data[mask_offset..][0 .. mask_h * mask_w], decoded.mask);

                            // Copy bbox into gt_boxes_data[mi * 4 ..]
                            const box_offset = mi * 4;
                            gt_boxes_data[box_offset + 0] = decoded.bbox[0];
                            gt_boxes_data[box_offset + 1] = decoded.bbox[1];
                            gt_boxes_data[box_offset + 2] = decoded.bbox[2];
                            gt_boxes_data[box_offset + 3] = decoded.bbox[3];

                            // Mark this GT slot as valid
                            gt_valid_data[mi] = 1.0;
                            filled_gt += 1;

                            if (epoch_idx == 0) {
                                std.log.info("Training: GT mask {d}: {d} fg pixels / {d} total, bbox=[{d:.3},{d:.3},{d:.3},{d:.3}]", .{
                                    mi, fg_pixels, mask_h * mask_w,
                                    decoded.bbox[0], decoded.bbox[1], decoded.bbox[2], decoded.bbox[3],
                                });
                            }
                        }
                        if (epoch_idx == 0) {
                            std.log.info("Training: Anomaly sample {s}: {d}/{d} GT masks filled", .{
                                sample.image_hash[0..@min(sample.image_hash.len, 8)],
                                filled_gt, sample.mask_pngs.len,
                            });
                        }
                    }
                    // For "good" images: gt_valid stays all zeros (no defects) — correct behavior

                    const losses = train_engine.step(
                        image_data,
                        gt_boxes_data,
                        gt_masks_data,
                        gt_valid_data,
                        step_num,
                    ) catch |err| {
                        std.log.err("Training step failed: {}", .{err});
                        continue;
                    };

                    epoch_loss += losses.total_loss;
                    epoch_loss_class += losses.loss_class;
                    epoch_loss_bbox += losses.loss_bbox;
                    epoch_loss_giou += losses.loss_giou;
                    epoch_loss_mask_bce += losses.loss_mask_bce;
                    epoch_loss_mask_dice += losses.loss_mask_dice;
                    sample_count += 1;
                }

                // Average losses over the epoch
                if (sample_count > 0) {
                    const sc: f64 = @floatFromInt(sample_count);
                    epoch_loss /= sc;
                    epoch_loss_class /= sc;
                    epoch_loss_bbox /= sc;
                    epoch_loss_giou /= sc;
                    epoch_loss_mask_bce /= sc;
                    epoch_loss_mask_dice /= sc;
                }

                // Early stopping check
                if (tc.patience > 0 and sample_count > 0) {
                    if (epoch_loss < best_loss - min_delta) {
                        best_loss = epoch_loss;
                        epochs_without_improvement = 0;
                    } else {
                        epochs_without_improvement += 1;
                    }
                }

                // Broadcast progress
                const msg = std.fmt.allocPrint(alloc_,
                    "{{\"type\":\"training\",\"nodeId\":\"{s}\",\"epoch\":{d},\"totalEpochs\":{d},\"loss\":{d:.6},\"loss_class\":{d:.6},\"loss_bbox\":{d:.6},\"loss_giou\":{d:.6},\"loss_mask_bce\":{d:.6},\"loss_mask_dice\":{d:.6}}}",
                    .{
                        tc.node_id,
                        epoch_idx + 1,
                        tc.total_epochs,
                        epoch_loss,
                        epoch_loss_class,
                        epoch_loss_bbox,
                        epoch_loss_giou,
                        epoch_loss_mask_bce,
                        epoch_loss_mask_dice,
                    },
                ) catch continue;
                defer alloc_.free(msg);
                sctx.broadcast(msg);

                std.log.info("Training: epoch {}/{} loss={d:.4} [cls={d:.4} bbox={d:.4} giou={d:.4} bce={d:.4} dice={d:.4}]", .{
                    epoch_idx + 1, @as(usize, @intCast(tc.total_epochs)), epoch_loss,
                    epoch_loss_class, epoch_loss_bbox, epoch_loss_giou, epoch_loss_mask_bce, epoch_loss_mask_dice,
                });

                final_epoch = epoch_idx + 1;

                // Break if patience exhausted
                if (tc.patience > 0 and epochs_without_improvement >= tc.patience) {
                    std.log.info("Training: Early stopping at epoch {} (patience={}, best_loss={d:.4})", .{
                        epoch_idx + 1, tc.patience, best_loss,
                    });
                    stopped_early = true;
                    break;
                }
            }

            // Post-training inference: run predictions on all training samples
            std.log.info("Training: Running post-training inference...", .{});
            sctx.broadcast("{\"type\":\"training_status\",\"phase\":\"inferring\"}");

            var prediction_count: usize = 0;
            // mask_h, mask_w already declared above for the training loop

            for (tc.samples, 0..) |sample, si| {
                // Load & preprocess JPEG
                var img_path_buf: [128]u8 = undefined;
                const img_path = std.fmt.bufPrint(&img_path_buf, "data/images/{s}.jpg", .{sample.image_hash}) catch continue;
                const file = std.fs.cwd().openFile(img_path, .{}) catch continue;
                defer file.close();
                const stat = file.stat() catch continue;
                const jpeg_data = alloc_.alloc(u8, stat.size) catch continue;
                defer alloc_.free(jpeg_data);
                _ = file.readAll(jpeg_data) catch continue;

                const image_data = Sam3TrainEngine.preprocessJpeg(alloc_, jpeg_data, @intCast(train_engine.train_image_size)) catch continue;
                defer alloc_.free(image_data);

                // Run inference
                const pred = train_engine.infer(image_data) catch |err| {
                    std.log.warn("Training: Inference failed for sample {d}: {}", .{ si, err });
                    continue;
                };
                defer alloc_.free(pred.pred_logits);
                defer alloc_.free(pred.pred_boxes);
                defer alloc_.free(pred.pred_masks);

                // Post-process: filter by score > 0.3
                const detections = Sam3TrainEngine.postProcessPredictions(pred, alloc_, 0.3) catch continue;
                defer alloc_.free(detections);

                // Decode GT masks for IoU-based label matching
                const n_gt = sample.mask_pngs.len;
                const gt_decoded = alloc_.alloc([]f32, n_gt) catch null;
                defer {
                    if (gt_decoded) |gd| {
                        for (gd) |m| alloc_.free(m);
                        alloc_.free(gd);
                    }
                }
                var gt_decoded_count: usize = 0;
                if (gt_decoded) |gd| {
                    for (sample.mask_pngs, 0..) |png_bytes, gi| {
                        const dec = sam3_engine.decodeMaskForTraining(alloc_, png_bytes, mask_h, mask_w) catch {
                            gd[gi] = &.{};
                            continue;
                        };
                        gd[gi] = dec.mask;
                        gt_decoded_count += 1;
                    }
                }

                // Build prediction JSON for WS broadcast
                var json_out: std.ArrayList(u8) = .{};
                defer json_out.deinit(alloc_);
                const jw = jsonWriter(&json_out, alloc_);
                jw.writeAll("{\"type\":\"prediction\",\"nodeId\":\"") catch continue;
                jw.writeAll(tc.node_id) catch continue;
                jw.writeAll("\",\"imageHash\":\"") catch continue;
                jw.writeAll(sample.image_hash) catch continue;
                jw.writeAll("\",\"detections\":[") catch continue;

                for (detections, 0..) |det, di| {
                    if (di > 0) jw.writeByte(',') catch continue;
                    jw.writeAll("{\"box\":[") catch continue;
                    std.fmt.format(jw, "{d:.4},{d:.4},{d:.4},{d:.4}", .{ det.box[0], det.box[1], det.box[2], det.box[3] }) catch continue;
                    jw.writeAll("],\"score\":") catch continue;
                    std.fmt.format(jw, "{d:.4}", .{det.score}) catch continue;

                    // Extract and encode mask for this detection
                    const mask_offset = det.mask_idx * mask_h * mask_w;
                    const mask_f32 = pred.pred_masks[mask_offset..][0 .. mask_h * mask_w];

                    // Binarize to u8
                    if (alloc_.alloc(u8, mask_h * mask_w)) |mask_u8| {
                        defer alloc_.free(mask_u8);
                        for (0..mask_h * mask_w) |pi| {
                            mask_u8[pi] = if (mask_f32[pi] > 0) 255 else 0;
                        }

                        // IoU-based label matching against GT masks
                        var best_iou: f64 = 0;
                        var best_gt_idx: ?usize = null;
                        if (gt_decoded) |gd| {
                            for (gd, 0..) |gt_mask, gi| {
                                if (gt_mask.len != mask_h * mask_w) continue;
                                var intersection: usize = 0;
                                var union_count: usize = 0;
                                for (0..mask_h * mask_w) |pi| {
                                    const pred_on = mask_f32[pi] > 0;
                                    const gt_on = gt_mask[pi] > 0.5;
                                    if (pred_on and gt_on) intersection += 1;
                                    if (pred_on or gt_on) union_count += 1;
                                }
                                if (union_count > 0) {
                                    const iou: f64 = @as(f64, @floatFromInt(intersection)) / @as(f64, @floatFromInt(union_count));
                                    if (iou > best_iou) {
                                        best_iou = iou;
                                        best_gt_idx = gi;
                                    }
                                }
                            }
                        }
                        // Skip detections that don't match any GT mask
                        const det_label: ?[]const u8 = if (best_iou > 0.1) blk: {
                            if (best_gt_idx) |gi| {
                                if (gi < sample.mask_labels.len) break :blk sample.mask_labels[gi];
                            }
                            break :blk null;
                        } else null;

                        if (det_label == null) {
                            // Unmatched detection — skip entirely
                            continue;
                        }

                        // Encode as PNG and base64
                        if (encodeMaskPng(alloc_, mask_u8, @intCast(mask_w), @intCast(mask_h))) |png_data_enc| {
                            defer alloc_.free(png_data_enc);
                            const b64_len = std.base64.standard.Encoder.calcSize(png_data_enc.len);
                            if (alloc_.alloc(u8, b64_len)) |b64_buf| {
                                defer alloc_.free(b64_buf);
                                _ = std.base64.standard.Encoder.encode(b64_buf, png_data_enc);
                                jw.writeAll(",\"mask\":\"") catch {};
                                jw.writeAll(b64_buf) catch {};
                                jw.writeAll("\"") catch {};
                            } else |_| {}
                        } else |_| {}

                        // Write label field
                        jw.writeAll(",\"label\":\"") catch {};
                        jw.writeAll(det_label.?) catch {};
                        jw.writeAll("\"") catch {};
                    } else |_| {
                        // No mask allocation — skip
                        continue;
                    }

                    jw.writeAll("}") catch continue;
                }

                jw.writeAll("]}") catch continue;

                // Broadcast prediction via WebSocket
                sctx.broadcast(json_out.items);

                prediction_count += 1;
                std.log.info("Training: Inference {d}/{d}: {s} → {d} detections", .{
                    si + 1, tc.samples.len, sample.image_hash[0..@min(sample.image_hash.len, 8)], detections.len,
                });
            }

            // Save trained weights to disk
            std.fs.cwd().makePath("data/models") catch {};
            var model_id_buf: [128]u8 = undefined;
            const model_id = std.fmt.bufPrint(&model_id_buf, "sam3-{s}-{d}.safetensors", .{
                tc.node_id, std.time.timestamp(),
            }) catch "sam3-unknown.safetensors";
            var model_path_buf: [256]u8 = undefined;
            const model_path = std.fmt.bufPrint(&model_path_buf, "data/models/{s}", .{model_id}) catch "data/models/sam3-unknown.safetensors";
            train_engine.saveTrainedWeights(model_path) catch |err| {
                std.log.err("Training: Failed to save weights: {}", .{err});
            };

            // Completion
            const done_msg = std.fmt.allocPrint(alloc_,
                "{{\"type\":\"training_complete\",\"nodeId\":\"{s}\",\"predictionCount\":{d},\"modelId\":\"{s}\",\"stoppedEarly\":{s},\"stoppedByUser\":{s},\"stoppedAtEpoch\":{d}}}",
                .{ tc.node_id, prediction_count, model_id, if (stopped_early) "true" else "false", if (stopped_by_user) "true" else "false", final_epoch },
            ) catch return;
            defer alloc_.free(done_msg);
            sctx.broadcast(done_msg);

            std.log.info("Training: Complete for node {s} ({d} predictions saved, model={s})", .{ tc.node_id, prediction_count, model_id });
        }
    }.run, .{train_ctx}) catch {
        ms.is_training.store(false, .release);
        train_ctx.freeCtx();
        res.status = 500;
        res.body = "{\"error\":\"failed to spawn training thread\"}";
        return;
    };
    thread.detach();

    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

pub fn stopTrainHandler(handler: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    const s = getState(handler.server_ctx);
    s.should_stop_training.store(true, .release);
    std.log.info("Training: Stop requested by user", .{});
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}


const std = @import("std");
const server = @import("../../server.zig");
const httpz = @import("httpz");
const genicam = @import("genicam");
const Handler = server.Handler;
const ServerContext = server.ServerContext;
const JsonWriter = server.JsonWriter;
const jsonWriter = server.jsonWriter;
const writeJsonString = server.writeJsonString;
const mod = @import("mod.zig");
const StreamManager = @import("stream_manager.zig").StreamManager;

fn getState(ctx: *ServerContext) ?*mod.State {
    return ctx.getModuleState(mod);
}

fn getStreamManager(ctx: *ServerContext) ?*StreamManager {
    const s = getState(ctx) orelse return null;
    return &s.stream_manager;
}

/// GET /api/cameras/discover — discover GigE Vision cameras on the network
pub fn discoverCamerasHandler(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    var result = genicam.discovery.discover(res.arena, 2000) catch {
        res.status = 500;
        res.body = "{\"error\":\"discovery failed\"}";
        return;
    };
    defer result.deinit();

    var out: std.ArrayList(u8) = .{};
    const w = jsonWriter(&out, res.arena);
    try w.writeByte('[');
    for (result.devices.items, 0..) |dev, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try writeJsonString(w, dev.id);
        try w.writeAll(",\"vendor\":");
        try writeJsonString(w, dev.vendor);
        try w.writeAll(",\"model\":");
        try writeJsonString(w, dev.model);
        try w.writeAll(",\"serial_number\":");
        try writeJsonString(w, dev.serial_number);
        try w.writeAll(",\"user_name\":");
        try writeJsonString(w, dev.user_name);
        try w.writeAll(",\"mac_address\":");
        var mac_buf: [17]u8 = undefined;
        _ = std.fmt.bufPrint(&mac_buf, "{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
            dev.mac_address[0],
            dev.mac_address[1],
            dev.mac_address[2],
            dev.mac_address[3],
            dev.mac_address[4],
            dev.mac_address[5],
        }) catch unreachable;
        try writeJsonString(w, &mac_buf);
        try w.writeAll(",\"protocol\":");
        try writeJsonString(w, switch (dev.protocol) {
            .gige_vision => "gige_vision",
            .usb3_vision => "usb3_vision",
        });
        try w.writeByte('}');
    }
    try w.writeByte(']');
    res.content_type = .JSON;
    res.body = out.items;
}

/// GET /api/camera-settings?id=... — read all readable settings from a physical camera
pub fn getCameraSettingsHandler(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const ctx = handler.server_ctx;
    const qs = try req.query();
    const id = qs.get("id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing camera id query param\"}";
        return;
    };

    // Reuse streaming camera (locked) or connect fresh
    var owned_camera: ?*genicam.Camera = null;
    var camera_lock: ?StreamManager.CameraLock = null;
    const camera = if (getStreamManager(ctx)) |sm| blk: {
        if (sm.lockCamera(id)) |lock| {
            camera_lock = lock;
            break :blk lock.camera;
        }
        const c = genicam.Camera.connectIp(res.arena, id, .{}) catch {
            res.status = 502;
            res.body = "{\"error\":\"failed to connect to camera\"}";
            return;
        };
        owned_camera = c;
        break :blk c;
    } else blk: {
        const c = genicam.Camera.connectIp(res.arena, id, .{}) catch {
            res.status = 502;
            res.body = "{\"error\":\"failed to connect to camera\"}";
            return;
        };
        owned_camera = c;
        break :blk c;
    };
    defer if (camera_lock) |lock| lock.release();
    defer if (owned_camera) |c| c.deinit();

    const gc = camera.genicam orelse {
        res.content_type = .JSON;
        res.body = "{}";
        return;
    };

    var out: std.ArrayList(u8) = .{};
    const w = jsonWriter(&out, res.arena);
    try w.writeByte('{');
    var first = true;

    var it = gc.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr.*;
        if (!node.isReadable()) continue;

        const name = entry.key_ptr.*;
        const writable = node.isWritable();
        switch (node) {
            .integer => |int_node| {
                if (camera.getInteger(name)) |val| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try writeJsonString(w, name);
                    try w.writeAll(":{\"type\":\"int\",\"value\":");
                    try std.fmt.format(w, "{d}", .{val});
                    if (int_node.min) |v| {
                        try w.writeAll(",\"min\":");
                        try std.fmt.format(w, "{d}", .{v});
                    }
                    if (int_node.max) |v| {
                        try w.writeAll(",\"max\":");
                        try std.fmt.format(w, "{d}", .{v});
                    }
                    if (!writable) try w.writeAll(",\"readonly\":true");
                    try w.writeByte('}');
                } else |_| {}
            },
            .float => |float_node| {
                if (camera.getFloat(name)) |val| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try writeJsonString(w, name);
                    try w.writeAll(":{\"type\":\"float\",\"value\":");
                    try std.fmt.format(w, "{d}", .{val});
                    if (float_node.min) |v| {
                        try w.writeAll(",\"min\":");
                        try std.fmt.format(w, "{d}", .{v});
                    }
                    if (float_node.max) |v| {
                        try w.writeAll(",\"max\":");
                        try std.fmt.format(w, "{d}", .{v});
                    }
                    if (!writable) try w.writeAll(",\"readonly\":true");
                    try w.writeByte('}');
                } else |_| {}
            },
            .converter => |conv_node| {
                if (camera.getFloat(name)) |val| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try writeJsonString(w, name);
                    try w.writeAll(":{\"type\":\"float\",\"value\":");
                    try std.fmt.format(w, "{d}", .{val});
                    if (conv_node.min) |v| {
                        try w.writeAll(",\"min\":");
                        try std.fmt.format(w, "{d}", .{v});
                    }
                    if (conv_node.max) |v| {
                        try w.writeAll(",\"max\":");
                        try std.fmt.format(w, "{d}", .{v});
                    }
                    if (!writable) try w.writeAll(",\"readonly\":true");
                    try w.writeByte('}');
                } else |_| {}
            },
            .int_converter => |ic_node| {
                if (camera.getFloat(name)) |val| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try writeJsonString(w, name);
                    try w.writeAll(":{\"type\":\"float\",\"value\":");
                    try std.fmt.format(w, "{d}", .{val});
                    if (ic_node.min) |v| {
                        try w.writeAll(",\"min\":");
                        try std.fmt.format(w, "{d}", .{v});
                    }
                    if (ic_node.max) |v| {
                        try w.writeAll(",\"max\":");
                        try std.fmt.format(w, "{d}", .{v});
                    }
                    if (!writable) try w.writeAll(",\"readonly\":true");
                    try w.writeByte('}');
                } else |_| {}
            },
            .boolean => {
                if (camera.getInteger(name)) |val| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try writeJsonString(w, name);
                    try w.writeAll(":{\"type\":\"bool\",\"value\":");
                    try w.writeAll(if (val != 0) "true" else "false");
                    if (!writable) try w.writeAll(",\"readonly\":true");
                    try w.writeByte('}');
                } else |_| {}
            },
            .enumeration => |enum_node| {
                if (camera.getInteger(name)) |val| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try writeJsonString(w, name);
                    try w.writeAll(":{\"type\":\"enum\",\"value\":");
                    if (enum_node.findEntryByValue(val)) |enum_entry| {
                        try writeJsonString(w, enum_entry.name);
                    } else {
                        try std.fmt.format(w, "{d}", .{val});
                    }
                    try w.writeAll(",\"options\":[");
                    for (enum_node.entries, 0..) |opt, oi| {
                        if (oi > 0) try w.writeByte(',');
                        try writeJsonString(w, opt.name);
                    }
                    try w.writeByte(']');
                    if (!writable) try w.writeAll(",\"readonly\":true");
                    try w.writeByte('}');
                } else |_| {}
            },
            else => {},
        }
    }

    try w.writeByte('}');
    res.content_type = .JSON;
    res.body = out.items;
}

/// PUT /api/camera-settings?id=... — apply settings to a physical camera
pub fn putCameraSettingsHandler(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const ctx = handler.server_ctx;
    const qs = try req.query();
    const id = qs.get("id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing camera id query param\"}";
        return;
    };

    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing body\"}";
        return;
    };

    // Reuse streaming camera (locked) or connect fresh
    var owned_camera: ?*genicam.Camera = null;
    var camera_lock: ?StreamManager.CameraLock = null;
    const camera = if (getStreamManager(ctx)) |sm| blk: {
        if (sm.lockCamera(id)) |lock| {
            camera_lock = lock;
            break :blk lock.camera;
        }
        const c = genicam.Camera.connectIp(res.arena, id, .{}) catch {
            res.status = 502;
            res.body = "{\"error\":\"failed to connect to camera\"}";
            return;
        };
        owned_camera = c;
        break :blk c;
    } else blk: {
        const c = genicam.Camera.connectIp(res.arena, id, .{}) catch {
            res.status = 502;
            res.body = "{\"error\":\"failed to connect to camera\"}";
            return;
        };
        owned_camera = c;
        break :blk c;
    };
    defer if (camera_lock) |lock| lock.release();
    defer if (owned_camera) |c| c.deinit();

    camera.loadSettingsFromJson(body) catch {
        res.status = 400;
        res.body = "{\"error\":\"failed to apply settings\"}";
        return;
    };

    // Read back actual values after applying
    const json = camera.settingsToJson(res.arena) catch {
        res.status = 500;
        res.body = "{\"error\":\"failed to read back settings\"}";
        return;
    };

    res.content_type = .JSON;
    res.body = json;
}

/// POST /api/camera-trigger?id=... — execute TriggerSoftware command on camera
pub fn cameraTriggerHandler(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const ctx = handler.server_ctx;
    const qs = try req.query();
    const id = qs.get("id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing camera id query param\"}";
        return;
    };

    // Reuse streaming camera (locked) or connect fresh
    var owned_camera: ?*genicam.Camera = null;
    var camera_lock: ?StreamManager.CameraLock = null;
    const camera = if (getStreamManager(ctx)) |sm| blk: {
        if (sm.lockCamera(id)) |lock| {
            camera_lock = lock;
            break :blk lock.camera;
        }
        const c = genicam.Camera.connectIp(res.arena, id, .{}) catch {
            res.status = 502;
            res.body = "{\"error\":\"failed to connect to camera\"}";
            return;
        };
        owned_camera = c;
        break :blk c;
    } else blk: {
        const c = genicam.Camera.connectIp(res.arena, id, .{}) catch {
            res.status = 502;
            res.body = "{\"error\":\"failed to connect to camera\"}";
            return;
        };
        owned_camera = c;
        break :blk c;
    };
    defer if (owned_camera) |c| c.deinit();

    camera.execute("TriggerSoftware") catch {
        if (camera_lock) |lock| lock.release();
        res.status = 500;
        res.body = "{\"error\":\"trigger command failed\"}";
        return;
    };

    // Release camera lock before accessing pipeline to avoid deadlock
    if (camera_lock) |lock| {
        lock.release();
        camera_lock = null;
    }

    // Try to grab the triggered frame and save to disk
    var saved_path: ?[]const u8 = null;
    if (getStreamManager(ctx)) |sm| {
        if (sm.getPipeline()) |pipeline| {
            // Wait briefly for the triggered frame to arrive
            std.Thread.sleep(200 * std.time.ns_per_ms);
            if (pipeline.pullJpeg()) |jpeg| {
                defer pipeline.freeJpeg(jpeg);
                const timestamp = std.time.timestamp();
                const filename = std.fmt.allocPrint(res.arena, "trigger_{d}.jpg", .{timestamp}) catch null;
                if (filename) |fname| {
                    const cwd = std.fs.cwd();
                    if (cwd.createFile(fname, .{})) |file| {
                        defer file.close();
                        file.writeAll(jpeg) catch {};
                        saved_path = fname;
                    } else |_| {}
                }
            }
        }
    }

    res.content_type = .JSON;
    if (saved_path) |path| {
        const json = std.fmt.allocPrint(res.arena, "{{\"ok\":true,\"saved\":\"{s}\"}}", .{path}) catch "{\"ok\":true}";
        res.body = json;
    } else {
        res.body = "{\"ok\":true}";
    }
}

/// POST /api/stream/start?id=... — start camera streaming via GStreamer
pub fn startStreamHandler(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const ctx = handler.server_ctx;
    const sm = getStreamManager(ctx) orelse {
        res.status = 501;
        res.body = "{\"error\":\"streaming not available (gstreamer disabled)\"}";
        return;
    };

    const qs = try req.query();
    const id = qs.get("id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing camera id query param\"}";
        return;
    };

    _ = sm.startStream(id) catch |err| {
        std.log.err("Failed to start stream: {}", .{err});
        res.status = 502;
        res.body = "{\"error\":\"failed to start stream\"}";
        return;
    };

    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

/// POST /api/stream/stop — stop current camera stream
pub fn stopStreamHandler(handler: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    const ctx = handler.server_ctx;
    const sm = getStreamManager(ctx) orelse {
        res.status = 501;
        res.body = "{\"error\":\"streaming not available\"}";
        return;
    };

    sm.stopStream();
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

/// GET /api/stream/snapshot — returns the latest JPEG frame
pub fn snapshotHandler(handler: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    const ctx = handler.server_ctx;
    const sm = getStreamManager(ctx) orelse {
        res.status = 501;
        res.body = "{\"error\":\"streaming not available\"}";
        return;
    };

    // Touch watchdog so stream stays alive while client is polling
    sm.last_client_poll.store(std.time.timestamp(), .release);

    const pipeline = sm.getPipeline() orelse {
        res.status = 409;
        res.body = "{\"error\":\"no active stream\"}";
        return;
    };

    const jpeg = pipeline.pullJpeg() orelse {
        res.status = 204; // No frame available yet
        return;
    };
    defer pipeline.freeJpeg(jpeg);

    res.header("Content-Type", "image/jpeg");
    res.header("Cache-Control", "no-cache, no-store");
    res.body = try res.arena.dupe(u8, jpeg);
}

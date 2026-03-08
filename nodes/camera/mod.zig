const std = @import("std");
const gstreamer = @import("gstreamer.zig");
const StreamManager = @import("stream_manager.zig").StreamManager;
const handlers = @import("handlers.zig");

pub const node_type = "camera";

pub const State = struct {
    stream_manager: StreamManager,

    pub fn init(allocator: std.mem.Allocator) State {
        gstreamer.init();
        return .{ .stream_manager = StreamManager.init(allocator) };
    }

    pub fn deinit(self: *State) void {
        self.stream_manager.deinit();
        gstreamer.deinit();
    }
};

pub fn registerRoutes(router: anytype) void {
    router.get("/api/cameras/discover", handlers.discoverCamerasHandler, .{});
    router.get("/api/camera-settings", handlers.getCameraSettingsHandler, .{});
    router.put("/api/camera-settings", handlers.putCameraSettingsHandler, .{});
    router.post("/api/camera-trigger", handlers.cameraTriggerHandler, .{});
    router.post("/api/stream/start", handlers.startStreamHandler, .{});
    router.post("/api/stream/stop", handlers.stopStreamHandler, .{});
    router.get("/api/stream/snapshot", handlers.snapshotHandler, .{});
}

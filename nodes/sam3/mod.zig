const std = @import("std");
const sam3_engine = @import("engine.zig");
pub const Sam3Engine = sam3_engine.Sam3Engine;
pub const Sam3TrainEngine = sam3_engine.Sam3TrainEngine;
const handlers = @import("handlers.zig");

pub const node_type = "sam3_ad";

pub const State = struct {
    engine: ?*Sam3Engine = null,
    init_state: enum { idle, loading, ready, failed } = .idle,
    init_thread: ?std.Thread = null,
    init_mutex: std.Thread.Mutex = .{},
    should_stop_training: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    is_training: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init() State {
        return .{};
    }

    pub fn deinit(self: *State) void {
        if (self.init_thread) |t| t.join();
        if (self.engine) |e| {
            e.deinit();
            self.engine = null;
        }
    }
};

pub fn registerRoutes(router: anytype) void {
    router.get("/api/sam3/status", handlers.sam3StatusHandler, .{});
    router.post("/api/sam3/init", handlers.sam3InitHandler, .{});
    router.post("/api/sam3/encode", handlers.sam3EncodeHandler, .{});
    router.post("/api/sam3/segment", handlers.sam3SegmentHandler, .{});
    router.post("/api/sam3/deinit", handlers.sam3DeinitHandler, .{});
    router.post("/api/train", handlers.startTrainHandler, .{});
    router.post("/api/train/stop", handlers.stopTrainHandler, .{});
}

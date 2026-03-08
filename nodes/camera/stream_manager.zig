const std = @import("std");
const Allocator = std.mem.Allocator;
const genicam = @import("genicam");
const gstreamer = @import("gstreamer.zig");
const build_options = @import("build_options");

pub const StreamManager = struct {
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},

    active_camera_id: ?[]const u8 = null,
    camera: ?*genicam.Camera = null,
    gst_pipeline: ?*gstreamer.Pipeline = null,
    frame_thread: ?std.Thread = null,
    watchdog_thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_client_poll: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    last_stop_time: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn init(allocator: Allocator) StreamManager {
        return .{ .allocator = allocator };
    }

    pub fn startStream(self: *StreamManager, camera_id: []const u8) !*gstreamer.Pipeline {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Stop existing stream if any
        if (self.camera != null) {
            self.stopStreamLocked();
        }

        // If a stream was recently stopped (by watchdog or explicit stop),
        // wait for the camera to release its GVCP control session.
        const since_stop = std.time.timestamp() - self.last_stop_time.load(.acquire);
        if (since_stop < 1) {
            self.mutex.unlock();
            std.Thread.sleep(500 * std.time.ns_per_ms);
            self.mutex.lock();
        }

        // Connect camera
        const camera = genicam.Camera.connectIp(self.allocator, camera_id, .{}) catch |err| {
            std.log.err("StreamManager: camera connection failed: {}", .{err});
            return error.CameraConnectionFailed;
        };
        errdefer camera.deinit();

        // Read camera dimensions and pixel format
        const width: u32 = @intCast(camera.getInteger("Width") catch 640);
        const height: u32 = @intCast(camera.getInteger("Height") catch 480);
        const pf_val: u32 = @intCast(camera.getInteger("PixelFormat") catch 0x01080001); // default mono8
        const pixel_format = mapPixelFormat(pf_val);
        std.log.info("StreamManager: camera {s} — {d}x{d} pf=0x{x}", .{ camera_id, width, height, pf_val });

        // Create GStreamer pipeline
        const pipeline = gstreamer.createPipeline(self.allocator, width, height, pixel_format) catch |err| {
            std.log.err("StreamManager: GStreamer pipeline creation failed: {}", .{err});
            return err;
        };
        errdefer pipeline.destroy();

        // Create camera stream
        var payload_size = camera.getPayloadSize() catch |err| blk: {
            std.log.warn("StreamManager: getPayloadSize failed: {}, computing from WxHxBPP", .{err});
            break :blk @as(usize, 0);
        };
        if (payload_size == 0) {
            // Fallback: compute from width * height * bytes-per-pixel
            const bpp: u32 = switch (pf_val) {
                0x01100003, 0x01100005, 0x01100007, 0x01100009 => 2, // mono16, bayer16
                0x02180014, 0x02180015 => 3, // rgb8, bgr8
                0x02200016, 0x02200017 => 4, // rgba8, bgra8
                else => 1, // mono8, bayer8
            };
            payload_size = @as(usize, width) * @as(usize, height) * bpp;
            std.log.info("StreamManager: computed payload_size={d} ({d}x{d}x{d})", .{ payload_size, width, height, bpp });
        } else {
            std.log.info("StreamManager: payload_size={d}", .{payload_size});
        }
        const stream = camera.stream(.{
            .buffer_count = 10,
            .payload_size = payload_size,
        }) catch |err| {
            std.log.err("StreamManager: stream creation failed: {}", .{err});
            return error.StreamCreationFailed;
        };

        // Start listening and acquisition
        stream.listen() catch |err| {
            std.log.err("StreamManager: stream listen failed: {}", .{err});
            stream.deinit();
            return error.StreamListenFailed;
        };
        camera.startAcquisition() catch |err| {
            std.log.err("StreamManager: acquisition start failed: {}", .{err});
            stream.stopListening();
            stream.deinit();
            return error.AcquisitionFailed;
        };

        // Start GStreamer pipeline
        pipeline.start() catch |err| {
            std.log.err("StreamManager: GStreamer pipeline start failed: {}", .{err});
            camera.stopAcquisition() catch {};
            stream.stopListening();
            stream.deinit();
            return err;
        };

        // Store state
        self.active_camera_id = self.allocator.dupe(u8, camera_id) catch null;
        self.camera = camera;
        self.gst_pipeline = pipeline;
        self.should_stop.store(false, .release);

        // Spawn frame thread
        const thread_ctx = FrameThreadCtx{
            .stream = stream,
            .pipeline = pipeline,
            .should_stop = &self.should_stop,
        };
        self.frame_thread = std.Thread.spawn(.{}, frameThreadFn, .{thread_ctx}) catch {
            self.stopStreamLocked();
            return error.ThreadSpawnFailed;
        };

        // Start watchdog — auto-stop stream if no client polls for snapshots
        self.last_client_poll.store(std.time.timestamp(), .release);
        self.watchdog_thread = std.Thread.spawn(.{}, watchdogFn, .{self}) catch null;

        return pipeline;
    }

    pub fn stopStream(self: *StreamManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopStreamLocked();
    }

    fn stopStreamLocked(self: *StreamManager) void {
        // Signal thread to stop
        self.should_stop.store(true, .release);

        // Wait for watchdog thread
        if (self.watchdog_thread) |thread| {
            thread.join();
            self.watchdog_thread = null;
        }

        // Wait for frame thread
        if (self.frame_thread) |thread| {
            thread.join();
            self.frame_thread = null;
        }

        // Stop camera acquisition and stream
        if (self.camera) |camera| {
            camera.stopAcquisition() catch {};
            // Stream cleanup happens automatically when camera deinits
            camera.deinit();
            self.camera = null;
        }

        // Destroy GStreamer pipeline
        if (self.gst_pipeline) |pipeline| {
            pipeline.stop();
            pipeline.destroy();
            self.gst_pipeline = null;
        }

        // Free camera ID
        if (self.active_camera_id) |id| {
            self.allocator.free(id);
            self.active_camera_id = null;
        }

        self.last_stop_time.store(std.time.timestamp(), .release);
    }

    pub const CameraLock = struct {
        camera: *genicam.Camera,
        manager: *StreamManager,

        pub fn release(self: CameraLock) void {
            self.manager.mutex.unlock();
        }
    };

    /// Lock the streaming camera for safe access (settings, trigger, etc.).
    /// Holds the StreamManager mutex until release() is called, preventing
    /// the camera from being deinited while in use.
    /// Returns null if not currently streaming the given camera.
    pub fn lockCamera(self: *StreamManager, camera_id: []const u8) ?CameraLock {
        self.mutex.lock();
        if (self.active_camera_id) |active_id| {
            if (std.mem.eql(u8, active_id, camera_id)) {
                if (self.camera) |cam| {
                    return .{ .camera = cam, .manager = self };
                }
            }
            std.log.warn("lockCamera: stream active for '{s}', requested '{s}'", .{ active_id, camera_id });
        } else {
            std.log.debug("lockCamera: no active stream (requested '{s}')", .{camera_id});
        }
        self.mutex.unlock();
        return null;
    }

    pub fn getPipeline(self: *StreamManager) ?*gstreamer.Pipeline {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.gst_pipeline;
    }

    pub fn isStreaming(self: *StreamManager, camera_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active_camera_id) |active_id| {
            return std.mem.eql(u8, active_id, camera_id);
        }
        return false;
    }

    /// Check if any camera is currently streaming (regardless of which one).
    pub fn isStreamingAny(self: *StreamManager) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.active_camera_id != null;
    }

    pub fn deinit(self: *StreamManager) void {
        self.stopStream();
    }
};

/// Watchdog timeout: stop stream if no client polls within 2 seconds.
/// Client polls every ~33ms, so 2s of silence means it's gone.
const WATCHDOG_TIMEOUT_S: i64 = 2;

fn watchdogFn(self: *StreamManager) void {
    std.log.info("Stream watchdog started", .{});
    while (!self.should_stop.load(.acquire)) {
        std.Thread.sleep(500 * std.time.ns_per_ms);
        const last = self.last_client_poll.load(.acquire);
        const now = std.time.timestamp();
        if (now - last > WATCHDOG_TIMEOUT_S) {
            std.log.info("Stream watchdog: no client activity for {d}s, stopping stream", .{now - last});
            // Stop without holding lock — stopStream takes its own lock.
            // Set watchdog_thread to null first so stopStreamLocked won't try to join us.
            self.mutex.lock();
            self.watchdog_thread = null;
            self.stopStreamLocked();
            self.mutex.unlock();
            return;
        }
    }
    std.log.info("Stream watchdog stopped", .{});
}

const FrameThreadCtx = struct {
    stream: *genicam.Stream,
    pipeline: *gstreamer.Pipeline,
    should_stop: *std.atomic.Value(bool),
};

fn frameThreadFn(ctx: FrameThreadCtx) void {
    const stream = ctx.stream;
    const pipeline = ctx.pipeline;

    var pts: u64 = 0;
    var frame_count: u64 = 0;
    var drop_count: u64 = 0;
    var skip_count: u64 = 0;
    const frame_duration: u64 = 33_333_333; // ~30fps in nanoseconds

    std.log.info("Frame thread started", .{});

    while (!ctx.should_stop.load(.acquire)) {
        var buffer = stream.popBuffer(100_000) orelse continue; // 100ms timeout

        // Drain queued buffers — keep only the latest for real-time display
        while (true) {
            const newer = stream.popBuffer(0) orelse break; // non-blocking
            stream.pushBuffer(buffer); // recycle old
            buffer = newer;
            skip_count += 1;
        }
        defer stream.pushBuffer(buffer); // recycle after use

        if (!buffer.isValid()) {
            drop_count += 1;
            if (drop_count % 30 == 1) {
                std.log.warn("Frame thread: invalid buffer (status={s}, dropped {d})", .{ @tagName(buffer.status), drop_count });
            }
            continue;
        }

        pipeline.pushFrame(buffer.data[0..buffer.size], pts, frame_duration) catch {
            std.log.warn("Failed to push frame to GStreamer", .{});
            continue;
        };

        frame_count += 1;
        if (frame_count % 30 == 1) {
            std.log.info("Frame thread: pushed {d} frames, skipped {d}, dropped {d}", .{ frame_count, skip_count, drop_count });
        }

        pts += frame_duration;
    }

    std.log.info("Frame thread stopped after {d} frames ({d} dropped)", .{ frame_count, drop_count });
}

fn mapPixelFormat(pfnc_val: u32) gstreamer.PixelFormat {
    return switch (pfnc_val) {
        0x01080001 => .mono8,
        0x0108000b => .bayer_bg8,
        0x0108000a => .bayer_gb8,
        0x01080008 => .bayer_gr8,
        0x01080009 => .bayer_rg8,
        0x02180014 => .rgb8,
        0x02180015 => .bgr8,
        else => .mono8, // fallback
    };
}

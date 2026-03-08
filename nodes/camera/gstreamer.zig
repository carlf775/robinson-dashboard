const std = @import("std");
const Allocator = std.mem.Allocator;

const shim = @cImport(@cInclude("gst_shim.h"));

pub const PixelFormat = enum {
    mono8,
    bayer_bg8,
    bayer_gb8,
    bayer_gr8,
    bayer_rg8,
    rgb8,
    bgr8,

    /// GStreamer video/x-raw format string
    pub fn toGstFormat(self: PixelFormat) []const u8 {
        return switch (self) {
            .mono8 => "GRAY8",
            .rgb8 => "RGB",
            .bgr8 => "BGR",
            .bayer_bg8, .bayer_gb8, .bayer_gr8, .bayer_rg8 => "GRAY8",
        };
    }

    /// GStreamer bayer format string (only for bayer patterns)
    pub fn toBayerFormat(self: PixelFormat) ?[]const u8 {
        return switch (self) {
            .bayer_bg8 => "bggr",
            .bayer_gb8 => "gbrg",
            .bayer_gr8 => "grbg",
            .bayer_rg8 => "rggb",
            else => null,
        };
    }

    pub fn isBayer(self: PixelFormat) bool {
        return self.toBayerFormat() != null;
    }
};

pub const Pipeline = struct {
    pipeline: *anyopaque,
    appsrc: *anyopaque,
    appsink: *anyopaque,
    allocator: Allocator,

    pub fn pushFrame(self: *Pipeline, data: []const u8, pts: u64, duration: u64) !void {
        const ret = shim.gst_shim_push_frame(self.appsrc, data.ptr, data.len, pts, duration);
        if (ret != 0) return error.PushFrameFailed;
    }

    /// Pull the latest JPEG frame from the pipeline. Caller must free the returned slice.
    pub fn pullJpeg(self: *Pipeline) ?[]const u8 {
        var size: usize = 0;
        const ptr: ?[*]u8 = @ptrCast(shim.gst_shim_pull_jpeg(self.appsink, &size, 0));
        if (ptr == null or size == 0) return null;
        return ptr.?[0..size];
    }

    /// Free a JPEG buffer returned by pullJpeg.
    pub fn freeJpeg(_: *Pipeline, data: []const u8) void {
        shim.gst_shim_free(@constCast(@ptrCast(data.ptr)));
    }

    pub fn start(self: *Pipeline) !void {
        if (shim.gst_shim_set_state_playing(self.pipeline) == 0) return error.SetStateFailed;
    }

    pub fn stop(self: *Pipeline) void {
        _ = shim.gst_shim_set_state_null(self.pipeline);
    }

    pub fn destroy(self: *Pipeline) void {
        _ = shim.gst_shim_set_state_null(self.pipeline);
        shim.gst_shim_unref(self.appsrc);
        shim.gst_shim_unref(self.appsink);
        shim.gst_shim_unref(self.pipeline);

        self.allocator.destroy(self);
    }
};

pub fn init() void {
    shim.gst_shim_init();
}

pub fn deinit() void {
    shim.gst_shim_deinit();
}

pub fn createPipeline(alloc: Allocator, width: u32, height: u32, pixel_format: PixelFormat) !*Pipeline {
    var desc_buf: [1024]u8 = undefined;
    const desc = try buildPipelineDesc(&desc_buf, width, height, pixel_format);

    const desc_z = try alloc.alloc(u8, desc.len + 1);
    defer alloc.free(desc_z);
    @memcpy(desc_z[0..desc.len], desc);
    desc_z[desc.len] = 0;

    var err_msg: [*c]const u8 = null;
    const pipeline_ptr = shim.gst_shim_create_pipeline(desc_z.ptr, &err_msg);
    if (pipeline_ptr == null) {
        if (err_msg != null) {
            std.log.err("GStreamer pipeline creation failed: {s}", .{std.mem.sliceTo(err_msg, 0)});
            shim.gst_shim_free(@constCast(@ptrCast(err_msg)));
        }
        return error.PipelineCreationFailed;
    }

    const appsrc_ptr = shim.gst_shim_get_element(pipeline_ptr, "src");
    if (appsrc_ptr == null) {
        shim.gst_shim_unref(pipeline_ptr);
        return error.ElementNotFound;
    }

    const appsink_ptr = shim.gst_shim_get_element(pipeline_ptr, "sink");
    if (appsink_ptr == null) {
        shim.gst_shim_unref(appsrc_ptr);
        shim.gst_shim_unref(pipeline_ptr);
        return error.ElementNotFound;
    }

    const pipe = try alloc.create(Pipeline);
    pipe.* = .{
        .pipeline = pipeline_ptr.?,
        .appsrc = appsrc_ptr.?,
        .appsink = appsink_ptr.?,
        .allocator = alloc,
    };

    return pipe;
}

fn buildPipelineDesc(buf: *[1024]u8, width: u32, height: u32, pixel_format: PixelFormat) ![]const u8 {
    const fmt = pixel_format.toGstFormat();

    // Pipeline: appsrc → videoconvert → jpegenc → appsink
    // sync=false: don't wait for PTS — release frames immediately
    // drop=true + max-buffers=1: only keep the latest JPEG
    const sink = "jpegenc quality=70 ! appsink name=sink max-buffers=1 drop=true sync=false";

    if (pixel_format.isBayer()) {
        const bayer_fmt = pixel_format.toBayerFormat().?;
        return std.fmt.bufPrint(buf, "appsrc name=src is-live=true do-timestamp=true format=time " ++
            "! video/x-bayer,format={s},width={d},height={d},framerate=0/1 " ++
            "! bayer2rgb " ++
            "! videoconvert " ++
            "! " ++ sink, .{ bayer_fmt, width, height }) catch error.PipelineDescTooLong;
    }

    return std.fmt.bufPrint(buf, "appsrc name=src is-live=true do-timestamp=true format=time " ++
        "! video/x-raw,format={s},width={d},height={d},framerate=0/1 " ++
        "! videoconvert " ++
        "! " ++ sink, .{ fmt, width, height }) catch error.PipelineDescTooLong;
}

#include "gst_shim.h"
#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <stdlib.h>
#include <string.h>

// ============================================================================
// Lifecycle
// ============================================================================

void gst_shim_init(void) {
    gst_init(NULL, NULL);
}

void gst_shim_deinit(void) {
    gst_deinit();
}

// ============================================================================
// Pipeline
// ============================================================================

void* gst_shim_create_pipeline(const char* desc, const char** err_msg) {
    GError* error = NULL;
    GstElement* pipeline = gst_parse_launch(desc, &error);
    if (error) {
        if (err_msg) {
            *err_msg = strdup(error->message);
        }
        g_error_free(error);
        if (pipeline) {
            gst_object_unref(pipeline);
        }
        return NULL;
    }
    return pipeline;
}

void* gst_shim_get_element(void* pipeline, const char* name) {
    if (!pipeline || !name) return NULL;
    return gst_bin_get_by_name(GST_BIN(pipeline), name);
}

int gst_shim_set_state_playing(void* pipeline) {
    if (!pipeline) return 0;
    GstStateChangeReturn ret = gst_element_set_state(GST_ELEMENT(pipeline), GST_STATE_PLAYING);
    return (ret != GST_STATE_CHANGE_FAILURE) ? 1 : 0;
}

int gst_shim_set_state_null(void* pipeline) {
    if (!pipeline) return 0;
    GstStateChangeReturn ret = gst_element_set_state(GST_ELEMENT(pipeline), GST_STATE_NULL);
    return (ret != GST_STATE_CHANGE_FAILURE) ? 1 : 0;
}

void gst_shim_unref(void* element) {
    if (element) {
        gst_object_unref(element);
    }
}

// ============================================================================
// AppSrc
// ============================================================================

void gst_shim_set_appsrc_caps(void* appsrc, const char* caps_str) {
    if (!appsrc || !caps_str) return;
    GstCaps* caps = gst_caps_from_string(caps_str);
    if (caps) {
        gst_app_src_set_caps(GST_APP_SRC(appsrc), caps);
        gst_caps_unref(caps);
    }
}

int gst_shim_push_frame(void* appsrc, const void* data, size_t size, uint64_t pts, uint64_t duration) {
    if (!appsrc || !data || size == 0) return -1;

    GstBuffer* buffer = gst_buffer_new_allocate(NULL, size, NULL);
    if (!buffer) return -1;

    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_WRITE)) {
        gst_buffer_unref(buffer);
        return -1;
    }
    memcpy(map.data, data, size);
    gst_buffer_unmap(buffer, &map);

    GST_BUFFER_PTS(buffer) = pts;
    GST_BUFFER_DURATION(buffer) = duration;

    GstFlowReturn ret = gst_app_src_push_buffer(GST_APP_SRC(appsrc), buffer);
    return (ret == GST_FLOW_OK) ? 0 : -1;
}

void gst_shim_end_of_stream(void* appsrc) {
    if (appsrc) {
        gst_app_src_end_of_stream(GST_APP_SRC(appsrc));
    }
}

// ============================================================================
// AppSink - pull JPEG
// ============================================================================

void* gst_shim_pull_jpeg(void* appsink, size_t* out_size, uint64_t timeout_ns) {
    if (!appsink || !out_size) return NULL;
    *out_size = 0;

    GstSample* sample = NULL;
    if (timeout_ns == 0) {
        sample = gst_app_sink_try_pull_sample(GST_APP_SINK(appsink), 0);
    } else {
        sample = gst_app_sink_try_pull_sample(GST_APP_SINK(appsink), timeout_ns);
    }
    if (!sample) return NULL;

    GstBuffer* buffer = gst_sample_get_buffer(sample);
    if (!buffer) {
        gst_sample_unref(sample);
        return NULL;
    }

    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) {
        gst_sample_unref(sample);
        return NULL;
    }

    // Copy JPEG data out
    void* jpeg_data = malloc(map.size);
    if (jpeg_data) {
        memcpy(jpeg_data, map.data, map.size);
        *out_size = map.size;
    }

    gst_buffer_unmap(buffer, &map);
    gst_sample_unref(sample);
    return jpeg_data;
}

// ============================================================================
// Memory
// ============================================================================

void gst_shim_free(void* ptr) {
    free(ptr);
}

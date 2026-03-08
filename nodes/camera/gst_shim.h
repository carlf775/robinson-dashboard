#ifndef GST_SHIM_H
#define GST_SHIM_H

#include <stddef.h>
#include <stdint.h>

// Lifecycle
void gst_shim_init(void);
void gst_shim_deinit(void);

// Pipeline
void* gst_shim_create_pipeline(const char* desc, const char** err_msg);
void* gst_shim_get_element(void* pipeline, const char* name);
int gst_shim_set_state_playing(void* pipeline);
int gst_shim_set_state_null(void* pipeline);
void gst_shim_unref(void* element);

// AppSrc
void gst_shim_set_appsrc_caps(void* appsrc, const char* caps_str);
int gst_shim_push_frame(void* appsrc, const void* data, size_t size, uint64_t pts, uint64_t duration);
void gst_shim_end_of_stream(void* appsrc);

// AppSink - pull JPEG frame
// Returns pointer to JPEG data and sets *out_size. Caller must free with gst_shim_free.
// Returns NULL if no frame available (timeout_ns = 0 for non-blocking).
void* gst_shim_pull_jpeg(void* appsink, size_t* out_size, uint64_t timeout_ns);

// Memory
void gst_shim_free(void* ptr);

#endif // GST_SHIM_H

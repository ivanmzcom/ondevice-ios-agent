// C ABI of libunified_ffi.a (see ../src/lib.rs). Hand-written; keep in sync.
#ifndef UNIFIED_FFI_H
#define UNIFIED_FFI_H

#include <stddef.h>
#include <stdint.h>

#define ODR_OK 0
#define ODR_ERR_ARGUMENT -1
#define ODR_ERR_PAIRING_FILE -2
#define ODR_ERR_LOCKDOWN -3
#define ODR_ERR_INSTALLATION_PROXY -4
#define ODR_ERR_XCTEST_LAUNCH -5
#define ODR_ERR_WDA_SESSION -6
#define ODR_ERR_WDA_SOURCE -7
#define ODR_ERR_RUNTIME -8
#define ODR_ERR_TIMEOUT -9
#define ODR_ERR_PANIC -10
#define ODR_ERR_HEARTBEAT -11
#define ODR_ERR_NOT_FOREGROUND -12
#define ODR_ERR_TAP_UNCERTAIN -13
#define ODR_ERR_TAP_REJECTED -14
#define ODR_ERR_TAP_NOT_SENT -15

// Each call blocks; run off the main thread. Exactly one of *out_json /
// *out_err is set; free it with uni_string_free.
int32_t uni_probe(const uint8_t *pairing, size_t pairing_len, const char *device_ip,
                  uint32_t timeout_secs, char **out_json, char **out_err);

// State-preserving WDA observation; target_bundle_id is required.
int32_t uni_observe(const uint8_t *pairing, size_t pairing_len, const char *device_ip,
                    const char *runner_bundle_id, const char *target_bundle_id,
                    int32_t heartbeat, uint32_t timeout_secs, char **out_json, char **out_err);

// Persistent WDA session (src/session.rs): the runner is launched once and
// serves observations/screenshots until closed. Calls on one session are
// serialized; never call close concurrently with another call.
typedef struct UniSession UniSession;
int32_t uni_session_open(const uint8_t *pairing, size_t pairing_len, const char *device_ip,
                         const char *runner_bundle_id, int32_t heartbeat, uint32_t timeout_secs,
                         UniSession **out_session, char **out_json, char **out_err);
// Source read options as JSON {"animation_cool_off_s","wait_for_idle_s","excluded_attributes","source_deadline_s"}
// (all optional). Idle waits are set via POST /appium/settings and confirmed by readback; the answer carries the
// effective values. An unconfirmed or invalid config stores nothing.
int32_t uni_session_configure_source(UniSession *s, const char *config_json, uint32_t timeout_secs,
                                     char **out_json, char **out_err);
int32_t uni_session_observe(UniSession *s, const char *target_bundle_id, uint32_t timeout_secs,
                            char **out_json, char **out_err);
int32_t uni_session_screenshot(UniSession *s, uint32_t timeout_secs, char **out_json, char **out_err);
// Exactly one POST /session/{id}/wda/tap {"x","y"} at window points (x, y) of a
// width x height window; refused unless strictly inside. Never retried.
// ODR_ERR_TAP_UNCERTAIN: written, result unknown (may have landed): stop, do not replay.
int32_t uni_session_tap(UniSession *s, double x, double y, double width, double height,
                        uint32_t timeout_secs, char **out_json, char **out_err);
// Observation of the real foreground app, bound by GET /session/{id}/wda/activeAppInfo before and after; never
// activates. expected_bundle_id NULL = whatever is in front; otherwise ODR_ERR_NOT_FOREGROUND unless it is.
int32_t uni_session_observe_foreground(UniSession *s, const char *expected_bundle_id, uint32_t timeout_secs,
                                       char **out_json, char **out_err);
// Pre-action revalidation of one chosen target (POST /session/{id}/hermes/target, runner endpoint version 3; compact
// observer sessions only). One request, never retried; returns {"stage","target_read","target"} with the target's
// selector matches and keyboards only. Identity refusals are ODR_ERR_NOT_FOREGROUND.
int32_t uni_session_revalidate_target(UniSession *s, const char *request_json, uint32_t timeout_secs, char **out_json,
                                      char **out_err);
// Read-only: {"bundle_id","pid","name"} of the foreground app (GET /session/{id}/wda/activeAppInfo).
int32_t uni_session_active_app(UniSession *s, uint32_t timeout_secs, char **out_json, char **out_err);
// Read-only /source comparison: one GET per format ("json" with format=json, then "xml" = the task's exact request)
// with the session's stored excluded_attributes and source deadline, each bound by activeAppInfo before and after.
// Never activates, taps or retries. Answer: {"samples":[{"format","outcome","http_status","duration_ms",
// "response_bytes","value_kind","wda_error","foreground_stable"}],"void",...}; bodies are dropped, never returned.
int32_t uni_session_compare_source(UniSession *s, const char *expected_bundle_id, uint32_t timeout_secs,
                                   char **out_json, char **out_err);
// Exactly one POST /session/{id}/wda/pressButton {"name":"home"}. Tap error codes; never retried.
int32_t uni_session_press_home(UniSession *s, uint32_t timeout_secs, char **out_json, char **out_err);
// Exactly one POST /session/{id}/wda/apps/activate (explicit open-app action). Tap error codes; never retried.
int32_t uni_session_activate(UniSession *s, const char *bundle_id, uint32_t timeout_secs, char **out_json,
                             char **out_err);
// Exactly one POST /session/{id}/wda/keys {"value":[text]} into the focused field. Tap error codes; only a 404
// is "rejected" (any other error after the write is uncertain: some characters may be typed). Never retried.
// Text with control characters (newline/return) or over 500 characters is refused before sending.
int32_t uni_session_type_text(UniSession *s, const char *text, uint32_t timeout_secs, char **out_json, char **out_err);
void uni_session_close(UniSession *s);

void uni_string_free(char *s);
const char *uni_version(void);

#endif

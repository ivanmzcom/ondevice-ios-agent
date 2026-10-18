//! Persistent WDA session for the agent loop (`uni_session_*`).
//!
//! `uni_observe` launches the WDA runner through testmanagerd for every call
//! (15–90 s). The ESP32 click gate needs an observation younger than a few
//! seconds and a cursor sighting younger than one second, which a per-call
//! launch can never satisfy. A session launches the runner once, opens one WDA
//! session without a tested application (same reason as `observe` in lib.rs:
//! no relaunch, no terminate on delete) and then serves observations and bare
//! screenshots until `uni_session_close`.
//!
//! The observation JSON is the same `uni-observation/1` object `uni_observe`
//! returns; the read sequence is a copy of lib.rs `observe` so that verified
//! path stays untouched.

use std::ffi::c_char;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use idevice::services::{
    dvt::xctest::{TestConfig, WdaRunHandle, XCUITestService},
    heartbeat::HeartbeatClient,
    installation_proxy::InstallationProxyClient,
    wda::WdaClient,
};

use crate::*;

/// Opaque to C.
pub struct UniSession {
    rt: tokio::runtime::Runtime,
    target: Target,
    handle: WdaRunHandle,
    sid: String,
    hb_stop: Arc<AtomicBool>,
    hb_task: Option<tokio::task::JoinHandle<Result<serde_json::Value, StageError>>>,
    lock: Mutex<()>,
    /// Source read options (`uni_session_configure_source`); default = baseline.
    source_cfg: Mutex<wda_apps::SourceConfig>,
    /// Set when a source read failed (its connection was dropped); reported once by the next read.
    source_failed: AtomicBool,
    /// Where this session talks to (runner port, session id prefix, open time, pre-launch listener probe).
    endpoint: serde_json::Value,
    /// Set by the first call that proved the session dead (`loss_reason`); every later call is refused unsent.
    lost: Mutex<Option<serde_json::Value>>,
}

async fn open_wda(t: &Target, runner: &str, ready: Duration) -> Result<(WdaRunHandle, String, serde_json::Value), StageError> {
    let cfg = {
        let mut proxy = InstallationProxyClient::connect(&*t.provider)
            .await
            .map_err(at(ODR_ERR_INSTALLATION_PROXY, "installation_proxy_connect"))?;
        TestConfig::from_installation_proxy(&mut proxy, runner, None)
            .await
            .map_err(at(ODR_ERR_INSTALLATION_PROXY, "resolve_runner"))?
    };
    // Connect-only, before the launch: a listener already on WDA's port means the readiness poll below (idevice
    // `run_until_wda_ready` polls `GET /status`) cannot tell this launch's XCTest server from a leftover one.
    let before_launch = wda_apps::connect_probe(&*t.provider, WDA_DEFAULT_HTTP_PORT, PROBE_TIMEOUT).await;
    let launched = std::time::Instant::now();
    let handle = XCUITestService::new(t.provider.clone())
        .run_until_wda_ready(cfg, ready)
        .await
        .map_err(at(ODR_ERR_XCTEST_LAUNCH, "testmanagerd_launch_wda"))?;
    let mut wda = WdaClient::new(&*t.provider).with_ports(handle.ports());
    match wda.start_session(None).await {
        Ok(sid) => {
            let endpoint = serde_json::json!({
                "http_port": handle.ports().http,
                "sid_prefix": sid.chars().take(8).collect::<String>(),
                "opened_unix_ms": now_ms(),
                "ready_ms": launched.elapsed().as_millis() as u64,
                "listener_before_launch": { "port": WDA_DEFAULT_HTTP_PORT, "probe": before_launch },
            });
            Ok((handle, sid, endpoint))
        }
        Err(e) => {
            handle.abort();
            Err(StageError::new(ODR_ERR_WDA_SESSION, "wda_start_session", describe(&e)))
        }
    }
}

async fn observe_in(s: &UniSession, target_bundle_id: &str) -> Result<serde_json::Value, StageError> {
    let (p, port, sid) = (&*s.target.provider, s.handle.ports().http, s.sid.as_str());
    let wda = WdaClient::new(p).with_ports(s.handle.ports());
    let sref = Some(sid);
    wda_apps::activate_app(p, port, WDA_APPS_TIMEOUT, sid, target_bundle_id)
        .await
        .map_err(at(ODR_ERR_WDA_SESSION, "wda_activate_app"))?;
    if compact_observer(s) {
        return observe_bound_in(s, Some(target_bundle_id), "observe", 1).await;
    }
    let before = wda_apps::app_state(p, port, WDA_APPS_TIMEOUT, sid, target_bundle_id)
        .await
        .map_err(at(ODR_ERR_WDA_SESSION, "wda_query_app_state"))?;
    foreground(before, "target_not_foreground_before")?;
    let window = wda.window_size(sref).await.map_err(at(ODR_ERR_WDA_SOURCE, "wda_window_size"))?;
    let orientation = wda.orientation(sref).await.map_err(at(ODR_ERR_WDA_SOURCE, "wda_orientation"))?;
    let (source_key, source, mut source_read) = source_in(s).await?;
    let source_at = now_ms();
    // activate, state, window, orientation, source, state: no screenshot (no consumer; `uni_session_screenshot` is
    // the explicit diagnostic read).
    source_read["wda_requests"] = serde_json::json!(6);
    source_read["screenshot"] = serde_json::json!(false);
    let after = wda_apps::app_state(p, port, WDA_APPS_TIMEOUT, sid, target_bundle_id)
        .await
        .map_err(at(ODR_ERR_WDA_SESSION, "wda_query_app_state"))?;
    foreground(after, "target_not_foreground_after")?;
    let mut obs = serde_json::json!({
        "schema": OBSERVATION_SCHEMA,
        "stage": "observe",
        "session": true,
        "target_bundle_id": target_bundle_id,
        "app_state_before": before,
        "app_state_after": after,
        "window_size": window,
        "orientation": orientation,
        "source_unix_ms": source_at,
        "source_read": source_read,
        "screenshot_captured": false,
    });
    // `source_xml` (baseline) or `source_compact` (Hermes runner); Core refuses the one the operator did not choose.
    obs[source_key] = source;
    Ok(obs)
}

fn compact_observer(s: &UniSession) -> bool {
    s.source_cfg.lock().unwrap_or_else(|e| e.into_inner()).observer == wda_apps::Observer::Compact
}

fn compact_stage(e: &wda_apps::SourceError) -> &'static str {
    match e {
        wda_apps::SourceError::Connect(_) => "wda_compact_connect",
        wda_apps::SourceError::Deadline(_) => "wda_compact_deadline",
        wda_apps::SourceError::Bad(m) if m.starts_with(wda_apps::COMPACT_UNAVAILABLE) => "wda_compact_unavailable",
        wda_apps::SourceError::Bad(m) if m.starts_with(wda_apps::COMPACT_INVALID_SESSION) => "wda_compact_invalid_session",
        wda_apps::SourceError::Bad(m) if m.starts_with(wda_apps::COMPACT_404_UNRECOGNIZED) => "wda_compact_404_unrecognized",
        wda_apps::SourceError::Bad(_) => "wda_compact_bad_answer",
    }
}

/// Compact observer: one bound runner read (`wda_apps::bound_observation`) replaces the separate foreground/app-state
/// reads before and after, `/window/size`, `/orientation` and the screenshot. The runner checks the identity around
/// its snapshot; `check_bound` re-checks it here and Core (`WDACompactSource`) a third time. `requests_before`: WDA
/// requests this observation already made (the target activation). Same `uni-observation/1` fields, no
/// `screenshot_png_b64`. Identity refusals are `ODR_ERR_NOT_FOREGROUND` with the stage the XML path uses.
async fn observe_bound_in(
    s: &UniSession,
    expected: Option<&str>,
    stage: &'static str,
    requests_before: u64,
) -> Result<serde_json::Value, StageError> {
    let cfg = s.source_cfg.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let after_failure = s.source_failed.swap(false, Ordering::SeqCst);
    let deadline = cfg.deadline.unwrap_or(wda_apps::IDEVICE_DEFAULT_REQUEST_TIMEOUT);
    let started = std::time::Instant::now();
    let r = wda_apps::bound_observation(&*s.target.provider, s.handle.ports().http, deadline, &s.sid, expected).await;
    let meta = serde_json::json!({
        "route": cfg.route(),
        "observer": cfg.observer.as_str(),
        "endpoint_version": wda_apps::COMPACT_BOUND_ENDPOINT_VERSION,
        "excluded_attributes": cfg.excluded,
        "deadline_ms": deadline.as_millis() as u64,
        "elapsed_ms": started.elapsed().as_millis() as u64,
        "after_source_failure": after_failure,
        "wda_requests": requests_before + 1,
        "screenshot": false,
    });
    let mut meta = meta;
    // Runner-measured stage durations (monotonic, runner process); absent on runners without them.
    if let Some(t) = r.as_ref().ok().and_then(|v| v.get("timings_ms")).filter(|t| t.is_object()) {
        meta["runner_timings_ms"] = t.clone();
    }
    let value = r.map_err(|e| {
        s.source_failed.store(true, Ordering::SeqCst);
        StageError::new(ODR_ERR_WDA_SOURCE, compact_stage(&e), format!("{e}; source_read={meta}"))
    })?;
    let b = wda_apps::check_bound(value, expected).map_err(|e| match e {
        wda_apps::BoundError::Bad(m) => {
            s.source_failed.store(true, Ordering::SeqCst);
            StageError::new(ODR_ERR_WDA_SOURCE, "wda_compact_bad_answer", format!("{m}; source_read={meta}"))
        }
        wda_apps::BoundError::Identity(stage, m) => StageError::new(ODR_ERR_NOT_FOREGROUND, stage, m),
    })?;
    let mut obs = serde_json::json!({
        "schema": OBSERVATION_SCHEMA,
        "stage": stage,
        "session": true,
        "foreground_basis": "GET /session/{id}/hermes/observation?bind=1 (runner identity before/after)",
        "foreground_pid": b.pid,
        "target_bundle_id": b.bundle_id,
        "app_state_before": b.state_before,
        "app_state_after": b.state_after,
        "window_size": b.window,
        "orientation": b.orientation,
        "source_unix_ms": now_ms(),
        "source_read": meta,
        "screenshot_captured": false,
    });
    obs["source_compact"] = b.value;
    Ok(obs)
}

/// The observation read with the session's options. `observer: compact` reads the Hermes runner route
/// (`wda_apps::compact_observation`) and nothing else: an unavailable route or a bad answer fails the observation, it
/// never falls back to `/source`. Otherwise XML as before: baseline keeps idevice's `WdaClient::source`, any option
/// switches to the direct route with its own deadline. Either way a failure drops that request's connection (fresh
/// `Connection: close` socket per request), nothing partial is returned, and the next read is flagged.
/// Returns the observation key (`source_xml` or `source_compact`), its value, and `source_read` (route, observer,
/// options and timings only, never hierarchy text).
async fn source_in(s: &UniSession) -> Result<(&'static str, serde_json::Value, serde_json::Value), StageError> {
    let cfg = s.source_cfg.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let after_failure = s.source_failed.swap(false, Ordering::SeqCst);
    let route = cfg.route();
    let deadline = cfg.deadline.unwrap_or(wda_apps::IDEVICE_DEFAULT_REQUEST_TIMEOUT);
    let started = std::time::Instant::now();
    let r: Result<(&'static str, serde_json::Value), (&'static str, String)> = if cfg.observer == wda_apps::Observer::Compact {
        wda_apps::compact_observation(&*s.target.provider, s.handle.ports().http, deadline, &s.sid)
            .await
            .map(|v| ("source_compact", v))
            .map_err(|e| (compact_stage(&e), e.to_string()))
    } else if cfg.is_baseline() {
        let wda = WdaClient::new(&*s.target.provider).with_ports(s.handle.ports());
        wda.source(Some(s.sid.as_str()))
            .await
            .map(|xml| ("source_xml", serde_json::Value::String(xml)))
            .map_err(|e| ("wda_source", describe(&e)))
    } else {
        wda_apps::source(&*s.target.provider, s.handle.ports().http, deadline, &s.sid, &cfg.excluded)
            .await
            .map(|xml| ("source_xml", serde_json::Value::String(xml)))
            .map_err(|e| {
                let stage = match e {
                    wda_apps::SourceError::Connect(_) => "wda_source_connect",
                    wda_apps::SourceError::Deadline(_) => "wda_source_deadline",
                    wda_apps::SourceError::Bad(_) => "wda_source_bad_answer",
                };
                (stage, e.to_string())
            })
    };
    let elapsed_ms = started.elapsed().as_millis() as u64;
    let meta = serde_json::json!({
        "route": route,
        "observer": cfg.observer.as_str(),
        "excluded_attributes": cfg.excluded,
        "deadline_ms": deadline.as_millis() as u64,
        "elapsed_ms": elapsed_ms,
        "after_source_failure": after_failure,
    });
    match r {
        Ok((key, source)) => Ok((key, source, meta)),
        Err((stage, why)) => {
            s.source_failed.store(true, Ordering::SeqCst);
            Err(StageError::new(ODR_ERR_WDA_SOURCE, stage, &format!("{why}; source_read={meta}")))
        }
    }
}

/// Pre-action revalidation of the chosen target (`wda_apps::target_revalidation`): compact observer sessions only,
/// one request, never retried, never replaced by a full observation. The answer carries matches and keyboards only.
async fn revalidate_target_in(s: &UniSession, request: &serde_json::Value) -> Result<serde_json::Value, StageError> {
    if !compact_observer(s) {
        return Err(StageError::new(ODR_ERR_ARGUMENT, "target_revalidation_needs_compact", "target revalidation needs the compact observer; nothing was sent"));
    }
    let body = wda_apps::target_request_body(request).map_err(|m| StageError::new(ODR_ERR_ARGUMENT, "target_request_invalid", m))?;
    let bundle = body["expected_bundle_id"].as_str().unwrap_or_default().to_owned();
    let pid = body["expected_pid"].as_i64().unwrap_or_default();
    let cfg = s.source_cfg.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let deadline = cfg.deadline.unwrap_or(wda_apps::IDEVICE_DEFAULT_REQUEST_TIMEOUT);
    let started = std::time::Instant::now();
    let r = wda_apps::target_revalidation(&*s.target.provider, s.handle.ports().http, deadline, &s.sid, &body).await;
    let meta = serde_json::json!({
        "route": "POST /session/{id}/hermes/target",
        "endpoint_version": wda_apps::TARGET_ENDPOINT_VERSION,
        "deadline_ms": deadline.as_millis() as u64,
        "elapsed_ms": started.elapsed().as_millis() as u64,
        "wda_requests": 1,
        "full_snapshot_projected": false,
    });
    let stage = |e: &wda_apps::SourceError| match e {
        wda_apps::SourceError::Connect(_) => "wda_target_connect",
        wda_apps::SourceError::Deadline(_) => "wda_target_deadline",
        wda_apps::SourceError::Bad(m) if m.starts_with(wda_apps::COMPACT_UNAVAILABLE) => "wda_target_unavailable",
        wda_apps::SourceError::Bad(m) if m.starts_with(wda_apps::COMPACT_INVALID_SESSION) => "wda_target_invalid_session",
        wda_apps::SourceError::Bad(_) => "wda_target_bad_answer",
    };
    let value = r.map_err(|e| StageError::new(ODR_ERR_WDA_SOURCE, stage(&e), format!("{e}; target_read={meta}")))?;
    let value = wda_apps::check_target(value, &bundle, pid).map_err(|e| match e {
        wda_apps::BoundError::Bad(m) => StageError::new(ODR_ERR_WDA_SOURCE, "wda_target_bad_answer", format!("{m}; target_read={meta}")),
        wda_apps::BoundError::Identity(stage, m) => StageError::new(ODR_ERR_NOT_FOREGROUND, stage, m),
    })?;
    Ok(serde_json::json!({ "stage": "revalidate_target", "target_read": meta, "target": value }))
}

async fn screenshot_in(s: &UniSession) -> Result<serde_json::Value, StageError> {
    let wda = WdaClient::new(&*s.target.provider).with_ports(s.handle.ports());
    let started = now_ms();
    let png = wda
        .screenshot(Some(s.sid.as_str()))
        .await
        .map_err(at(ODR_ERR_WDA_SOURCE, "wda_screenshot"))?;
    Ok(serde_json::json!({
        "stage": "screenshot",
        "screenshot_png_b64": base64(&png),
        "requested_unix_ms": started,
        "screenshot_unix_ms": now_ms(),
    }))
}

/// Per-request deadline of the single tap write + answer.
const WDA_TAP_TIMEOUT: Duration = Duration::from_secs(10);

/// The tap point must be finite and strictly inside the observed window (points); never clamped.
pub fn tap_in_bounds(x: f64, y: f64, width: f64, height: f64) -> bool {
    [x, y, width, height].iter().all(|v| v.is_finite()) && width > 0.0 && height > 0.0
        && 0.0 < x && x < width && 0.0 < y && y < height
}

async fn tap_in(s: &UniSession, x: f64, y: f64, width: f64, height: f64) -> Result<serde_json::Value, StageError> {
    if !tap_in_bounds(x, y, width, height) {
        return Err(StageError::new(ODR_ERR_TAP_NOT_SENT, "tap_out_of_bounds", format!("({x}, {y}) not inside {width}x{height}")));
    }
    let started = now_ms();
    wda_apps::tap(&*s.target.provider, s.handle.ports().http, WDA_TAP_TIMEOUT, &s.sid, x, y)
        .await
        .map_err(|e| match e {
            wda_apps::TapError::NotSent(m) => StageError::new(ODR_ERR_TAP_NOT_SENT, "wda_tap_not_sent", m),
            wda_apps::TapError::Rejected(m) => StageError::new(ODR_ERR_TAP_REJECTED, "wda_tap_rejected", m),
            wda_apps::TapError::Uncertain(m) => StageError::new(ODR_ERR_TAP_UNCERTAIN, "wda_tap_uncertain", m),
        })?;
    Ok(serde_json::json!({
        "stage": "tap",
        "route": "POST /session/{id}/wda/tap",
        "x": x,
        "y": y,
        "requested_unix_ms": started,
        "acked_unix_ms": now_ms(),
    }))
}

/// The foreground app must be `expected` (when given) and the same process before and after the read; nothing
/// is activated to make it so.
pub(crate) fn check_foreground(
    expected: Option<&str>,
    before: &wda_apps::ActiveApp,
    after: Option<&wda_apps::ActiveApp>,
) -> Result<(), StageError> {
    if let Some(e) = expected
        && before.bundle_id != e
    {
        return Err(StageError::new(
            ODR_ERR_NOT_FOREGROUND,
            "foreground_mismatch",
            format!("expected {e} in front, foreground is {}", before.bundle_id),
        ));
    }
    if let Some(a) = after
        && (a.bundle_id != before.bundle_id || a.pid != before.pid)
    {
        return Err(StageError::new(
            ODR_ERR_NOT_FOREGROUND,
            "foreground_changed_during_observation",
            format!("{} (pid {}) became {} (pid {})", before.bundle_id, before.pid, a.bundle_id, a.pid),
        ));
    }
    Ok(())
}

/// Observation of whatever app is really in front, bound by `activeAppInfo` before and after: no activate, no
/// relaunch. Same `uni-observation/1` fields; app states are 4 only because that app was the active one both times.
async fn observe_foreground_in(s: &UniSession, expected: Option<&str>) -> Result<serde_json::Value, StageError> {
    let (p, port, sid) = (&*s.target.provider, s.handle.ports().http, s.sid.as_str());
    let wda = WdaClient::new(p).with_ports(s.handle.ports());
    let sref = Some(sid);
    if compact_observer(s) {
        return observe_bound_in(s, expected, "observe_foreground", 0).await;
    }
    let before = wda_apps::active_app(p, port, WDA_APPS_TIMEOUT, sid)
        .await
        .map_err(at(ODR_ERR_WDA_SESSION, "wda_active_app_info"))?;
    check_foreground(expected, &before, None)?;
    let window = wda.window_size(sref).await.map_err(at(ODR_ERR_WDA_SOURCE, "wda_window_size"))?;
    let orientation = wda.orientation(sref).await.map_err(at(ODR_ERR_WDA_SOURCE, "wda_orientation"))?;
    let (source_key, source, mut source_read) = source_in(s).await?;
    let source_at = now_ms();
    // activeAppInfo, window, orientation, source, activeAppInfo: no screenshot.
    source_read["wda_requests"] = serde_json::json!(5);
    source_read["screenshot"] = serde_json::json!(false);
    let after = wda_apps::active_app(p, port, WDA_APPS_TIMEOUT, sid)
        .await
        .map_err(at(ODR_ERR_WDA_SESSION, "wda_active_app_info"))?;
    check_foreground(expected, &before, Some(&after))?;
    let mut obs = serde_json::json!({
        "schema": OBSERVATION_SCHEMA,
        "stage": "observe_foreground",
        "session": true,
        "foreground_basis": "GET /session/{id}/wda/activeAppInfo",
        "foreground_pid": before.pid,
        "target_bundle_id": before.bundle_id,
        "app_state_before": 4,
        "app_state_after": 4,
        "window_size": window,
        "orientation": orientation,
        "source_unix_ms": source_at,
        "source_read": source_read,
        "screenshot_captured": false,
    });
    // `source_xml` (baseline) or `source_compact` (Hermes runner); Core refuses the one the operator did not choose.
    obs[source_key] = source;
    Ok(obs)
}

/// Read-only `/source` comparison (WDA_500_DIAGNOSIS.md §7 R0/R1): one read per `COMPARE_FORMATS` entry with the
/// session's stored options and deadline, each bound by `activeAppInfo` before and after. No activate, tap, Home or
/// retry. A foreground mismatch or change voids the run (samples so far are kept). The answer holds formats,
/// outcomes, statuses, durations and body sizes only; bodies are dropped. Any failed read flags the next observation.
async fn compare_source_in(s: &UniSession, expected: Option<&str>) -> Result<serde_json::Value, StageError> {
    let (p, port, sid) = (&*s.target.provider, s.handle.ports().http, s.sid.as_str());
    let cfg = s.source_cfg.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let deadline = cfg.deadline.unwrap_or(wda_apps::IDEVICE_DEFAULT_REQUEST_TIMEOUT);
    let after_failure = s.source_failed.load(Ordering::SeqCst);
    let mut samples = Vec::new();
    let mut first: Option<wda_apps::ActiveApp> = None;
    let mut void: Option<&'static str> = None;
    for format in wda_apps::COMPARE_FORMATS {
        let before = wda_apps::active_app(p, port, WDA_APPS_TIMEOUT, sid)
            .await
            .map_err(at(ODR_ERR_WDA_SESSION, "wda_active_app_info"))?;
        if let Err(e) = check_foreground(expected, &before, None) {
            void = Some(e.stage);
            break;
        }
        if let Some(f) = &first
            && check_foreground(None, f, Some(&before)).is_err()
        {
            void = Some("foreground_changed_between_samples");
            break;
        }
        first.get_or_insert(before.clone());
        let started = std::time::Instant::now();
        let r = wda_apps::probe_source(p, port, deadline, sid, format, &cfg.excluded).await;
        let duration_ms = started.elapsed().as_millis() as u64;
        let mut sample = match &r {
            Ok(probe) => probe.to_json(),
            Err(wda_apps::SourceError::Connect(_)) => serde_json::json!({ "outcome": "connect" }),
            Err(wda_apps::SourceError::Deadline(_)) => serde_json::json!({ "outcome": "deadline" }),
            Err(wda_apps::SourceError::Bad(_)) => serde_json::json!({ "outcome": "read_error" }),
        };
        if !matches!(&r, Ok(probe) if probe.outcome == "ok") {
            s.source_failed.store(true, Ordering::SeqCst);
        }
        sample["format"] = serde_json::json!(format);
        sample["duration_ms"] = serde_json::json!(duration_ms);
        let after = wda_apps::active_app(p, port, WDA_APPS_TIMEOUT, sid)
            .await
            .map_err(at(ODR_ERR_WDA_SESSION, "wda_active_app_info"))?;
        let stable = check_foreground(expected, &before, Some(&after)).is_ok();
        sample["foreground_stable"] = serde_json::json!(stable);
        samples.push(sample);
        if !stable {
            void = Some("foreground_changed_during_sample");
            break;
        }
    }
    Ok(serde_json::json!({
        "stage": "compare_source",
        "foreground_bundle_id": first.as_ref().map(|f| f.bundle_id.clone()),
        "order": wda_apps::COMPARE_FORMATS,
        "route": "direct",
        "excluded_attributes": cfg.excluded,
        "deadline_ms": deadline.as_millis() as u64,
        "after_source_failure": after_failure,
        "void": void,
        "samples": samples,
    }))
}

async fn active_app_in(s: &UniSession) -> Result<serde_json::Value, StageError> {
    let a = wda_apps::active_app(&*s.target.provider, s.handle.ports().http, WDA_APPS_TIMEOUT, &s.sid)
        .await
        .map_err(at(ODR_ERR_WDA_SESSION, "wda_active_app_info"))?;
    Ok(serde_json::json!({
        "stage": "active_app",
        "route": "GET /session/{id}/wda/activeAppInfo",
        "bundle_id": a.bundle_id,
        "pid": a.pid,
        "name": a.name,
        "unix_ms": now_ms(),
    }))
}

fn mutation_error(e: wda_apps::TapError, what: &'static str) -> StageError {
    let stage = |s: &'static str| s;
    match e {
        wda_apps::TapError::NotSent(m) => StageError::new(ODR_ERR_TAP_NOT_SENT, stage("wda_mutation_not_sent"), format!("{what}: {m}")),
        wda_apps::TapError::Rejected(m) => StageError::new(ODR_ERR_TAP_REJECTED, stage("wda_mutation_rejected"), format!("{what}: {m}")),
        wda_apps::TapError::Uncertain(m) => StageError::new(ODR_ERR_TAP_UNCERTAIN, stage("wda_mutation_uncertain"), format!("{what}: {m}")),
    }
}

async fn press_home_in(s: &UniSession) -> Result<serde_json::Value, StageError> {
    let started = now_ms();
    wda_apps::press_home(&*s.target.provider, s.handle.ports().http, WDA_TAP_TIMEOUT, &s.sid)
        .await
        .map_err(|e| mutation_error(e, "home"))?;
    Ok(serde_json::json!({ "stage": "press_home", "route": "POST /session/{id}/wda/pressButton", "requested_unix_ms": started, "acked_unix_ms": now_ms() }))
}

async fn activate_in(s: &UniSession, bundle_id: &str) -> Result<serde_json::Value, StageError> {
    let started = now_ms();
    wda_apps::activate_once(&*s.target.provider, s.handle.ports().http, WDA_TAP_TIMEOUT, &s.sid, bundle_id)
        .await
        .map_err(|e| mutation_error(e, "activate"))?;
    Ok(serde_json::json!({ "stage": "activate", "route": "POST /session/{id}/wda/apps/activate", "bundle_id": bundle_id, "requested_unix_ms": started, "acked_unix_ms": now_ms() }))
}

async fn type_text_in(s: &UniSession, text: &str, timeout: Duration) -> Result<serde_json::Value, StageError> {
    let started = now_ms();
    wda_apps::type_text(&*s.target.provider, s.handle.ports().http, timeout, &s.sid, text)
        .await
        .map_err(|e| mutation_error(e, "type"))?;
    // The text itself is not echoed back (it may be private); only its length.
    Ok(serde_json::json!({ "stage": "type_text", "route": "POST /session/{id}/wda/keys", "chars": text.chars().count(), "requested_unix_ms": started, "acked_unix_ms": now_ms() }))
}

/// Per-request deadline for typing: WDA types at a bounded frequency, so longer text needs longer.
fn typing_timeout(text: &str) -> Duration {
    WDA_TAP_TIMEOUT + Duration::from_millis(100 * text.chars().count() as u64)
}

/// A mutation's overall deadline after the write is "uncertain", never a retryable timeout.
fn mutation_deadline(timeout_secs: u32) -> Duration {
    Duration::from_secs(timeout_secs.max(1) as u64).max(WDA_TAP_TIMEOUT * 2 + Duration::from_secs(1))
}

fn uncertain_on_timeout(e: StageError) -> StageError {
    if e.code == ODR_ERR_TIMEOUT {
        StageError::new(ODR_ERR_TAP_UNCERTAIN, "wda_mutation_uncertain", "overall deadline; it may have happened")
    } else {
        e
    }
}

/// Observation of the real foreground app (no activation). `expected_bundle_id` null = whatever is in front;
/// otherwise refused (`ODR_ERR_NOT_FOREGROUND`) unless that app is in front before and after the read.
///
/// # Safety
/// As `uni_session_observe`; `expected_bundle_id` null or a C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_session_observe_foreground(
    s: *mut UniSession,
    expected_bundle_id: *const c_char,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { session(s) }?;
        let expected = if expected_bundle_id.is_null() { None } else { Some(unsafe { req_str(expected_bundle_id, "expected_bundle_id") }?) };
        on(s, Duration::from_secs(timeout_secs.max(1) as u64), observe_foreground_in(s, expected))
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// The foreground app per `GET /session/{id}/wda/activeAppInfo`. Read-only.
///
/// # Safety
/// As `uni_session_observe`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_session_active_app(
    s: *mut UniSession,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { session(s) }?;
        on(s, Duration::from_secs(timeout_secs.max(1) as u64), active_app_in(s))
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// Read-only `/source` JSON/XML comparison with the session's stored options (see `compare_source_in`).
/// `expected_bundle_id` null = whatever is in front. One request per format, never retried.
///
/// # Safety
/// As `uni_session_observe`; `expected_bundle_id` null or a C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_session_compare_source(
    s: *mut UniSession,
    expected_bundle_id: *const c_char,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { session(s) }?;
        let expected = if expected_bundle_id.is_null() { None } else { Some(unsafe { req_str(expected_bundle_id, "expected_bundle_id") }?) };
        on(s, Duration::from_secs(timeout_secs.max(1) as u64), compare_source_in(s, expected))
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// Exactly one Home press (`POST /session/{id}/wda/pressButton {"name":"home"}`); tap error codes, never retried.
///
/// # Safety
/// As `uni_session_observe`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_session_press_home(
    s: *mut UniSession,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { session(s) }?;
        on(s, mutation_deadline(timeout_secs), press_home_in(s)).map_err(uncertain_on_timeout)
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// Exactly one `POST /session/{id}/wda/keys` typing `text` (UTF-8) into the focused field; tap error codes,
/// never retried. Text with control characters or over 500 characters is refused before anything is written.
///
/// # Safety
/// As `uni_session_observe`; `text` a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_session_type_text(
    s: *mut UniSession,
    text: *const c_char,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { session(s) }?;
        if text.is_null() {
            return Err(StageError::new(ODR_ERR_TAP_NOT_SENT, "wda_mutation_not_sent", "type: no text"));
        }
        let text = unsafe { std::ffi::CStr::from_ptr(text) }
            .to_str()
            .map_err(|_| StageError::new(ODR_ERR_TAP_NOT_SENT, "wda_mutation_not_sent", "type: text is not UTF-8"))?
            .to_owned();
        let per_request = typing_timeout(&text);
        let deadline = mutation_deadline(timeout_secs).max(per_request * 2 + Duration::from_secs(1));
        on(s, deadline, type_text_in(s, &text, per_request)).map_err(uncertain_on_timeout)
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// Exactly one explicit open-app action (`POST /session/{id}/wda/apps/activate`); tap error codes, never retried.
///
/// # Safety
/// As `uni_session_observe`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_session_activate(
    s: *mut UniSession,
    bundle_id: *const c_char,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { session(s) }?;
        let bundle = unsafe { req_str(bundle_id, "bundle_id") }?;
        on(s, mutation_deadline(timeout_secs), activate_in(s, bundle)).map_err(uncertain_on_timeout)
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// Connect-only probe deadline (`wda_apps::connect_probe`).
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);
/// lockdownd's TCP port: a connect accepted there means the tunnel route reaches the phone.
const LOCKDOWN_PORT: u16 = 62078;
/// WDA's default `USE_PORT`, probed before a launch (`open_wda`).
const WDA_DEFAULT_HTTP_PORT: u16 = 8100;

/// Why a failed call proves this session dead, or None. `connection_refused`: the phone's stack answered RST on the
/// runner's HTTP port (CONNECTION_REFUSED_REPORT.md §2), nothing listens there for this session. `invalid_session`:
/// WDA answered 404 for the session id (the route exists; the id is not WDA's active session). A missing route
/// (`unknown command`), a deadline or an identity refusal is not a session loss.
pub fn loss_reason(stage: &str, detail: &str) -> Option<&'static str> {
    let d = detail.to_ascii_lowercase();
    if d.contains("connectionrefused") || d.contains("connection refused") {
        Some("connection_refused")
    } else if stage == "wda_compact_invalid_session" || d.contains("invalid session id") || d.contains("session does not exist") {
        Some("invalid_session")
    } else {
        None
    }
}

/// What the two connect-only probes after a refusal say about the endpoint.
pub fn probe_verdict(wda_port: &str, lockdown_port: &str) -> &'static str {
    match (wda_port, lockdown_port) {
        ("accepted", _) => "wda_port_accepts_again",
        (_, "accepted") => "runner_not_listening",
        (_, "refused") => "lockdown_refused",
        _ => "tunnel_or_device_unreachable",
    }
}

/// The loss record: reason, failing stage, this session's endpoint and, after a refusal, one connect-only probe of
/// the runner's HTTP port and one of lockdownd (no byte written, no pairing use, the failed call is not retried).
async fn loss_record(s: &UniSession, reason: &'static str, stage: &'static str) -> serde_json::Value {
    let mut rec = serde_json::json!({ "reason": reason, "stage": stage, "at_unix_ms": now_ms(), "endpoint": s.endpoint });
    if reason == "connection_refused" {
        let p = &*s.target.provider;
        let wda = wda_apps::connect_probe(p, s.handle.ports().http, PROBE_TIMEOUT).await;
        let lockdown = wda_apps::connect_probe(p, LOCKDOWN_PORT, PROBE_TIMEOUT).await;
        rec["probe"] = serde_json::json!({ "wda_port": wda, "lockdown_port": lockdown, "verdict": probe_verdict(wda, lockdown) });
    }
    rec
}

fn on<F>(s: &UniSession, timeout: Duration, fut: F) -> Result<serde_json::Value, StageError>
where
    F: std::future::Future<Output = Result<serde_json::Value, StageError>>,
{
    let _serial = s.lock.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(rec) = s.lost.lock().unwrap_or_else(|e| e.into_inner()).clone() {
        let mut e = StageError::new(ODR_ERR_WDA_SESSION, "session_unusable", "this session was lost earlier; nothing was sent, open a new session");
        e.session_lost = Some(rec);
        return Err(e);
    }
    s.rt.block_on(async {
        let r = tokio::time::timeout(timeout, fut)
            .await
            .unwrap_or_else(|_| Err(StageError::new(ODR_ERR_TIMEOUT, "timeout", "overall deadline")));
        match r {
            Err(mut e) => {
                if let Some(reason) = loss_reason(e.stage, &e.detail) {
                    let rec = loss_record(s, reason, e.stage).await;
                    *s.lost.lock().unwrap_or_else(|e| e.into_inner()) = Some(rec.clone());
                    e.session_lost = Some(rec);
                }
                Err(e)
            }
            ok => ok,
        }
    })
}

unsafe fn session<'a>(p: *mut UniSession) -> Result<&'a UniSession, StageError> {
    unsafe { p.as_ref() }.ok_or_else(|| StageError::new(ODR_ERR_ARGUMENT, "argument", "session is required"))
}

/// Launch the WDA runner once and open a WDA session without a tested app.
/// On success `*out_session` owns it until `uni_session_close`. With
/// `heartbeat != 0` the prototype's heartbeat runs for the session's lifetime.
///
/// # Safety
/// As `uni_probe`; `out_session` must be a valid pointer.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn uni_session_open(
    pairing: *const u8,
    pairing_len: usize,
    device_ip: *const c_char,
    runner_bundle_id: *const c_char,
    heartbeat: i32,
    timeout_secs: u32,
    out_session: *mut *mut UniSession,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    if !out_session.is_null() {
        unsafe { *out_session = std::ptr::null_mut() };
    }
    let r = catch_unwind(AssertUnwindSafe(|| {
        if out_session.is_null() {
            return Err(StageError::new(ODR_ERR_ARGUMENT, "argument", "out_session is required"));
        }
        let ip = unsafe { req_str(device_ip, "device_ip") }?;
        let runner = unsafe { req_str(runner_bundle_id, "runner_bundle_id") }?;
        let target = build_provider(unsafe { bytes(pairing, pairing_len) }?, ip)?;
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| StageError::new(ODR_ERR_RUNTIME, "runtime", e))?;
        let total = Duration::from_secs(timeout_secs.max(10) as u64);
        let hb_stop = Arc::new(AtomicBool::new(false));
        let hb_task = (heartbeat != 0).then(|| {
            let provider = target.provider.clone();
            let stop = hb_stop.clone();
            rt.spawn(async move {
                heartbeat::with_heartbeat(
                    HeartbeatClient::connect(&*provider),
                    heartbeat::FIRST_MARCO_WAIT_SECS,
                    Duration::from_secs(24 * 3600),
                    || async move {
                        while !stop.load(Ordering::Relaxed) {
                            tokio::time::sleep(Duration::from_millis(250)).await;
                        }
                        Ok(serde_json::json!({ "stage": "session_heartbeat" }))
                    },
                )
                .await
            })
        });
        let opened = rt.block_on(async {
            tokio::time::timeout(total, open_wda(&target, runner, total.saturating_sub(Duration::from_secs(8))))
                .await
                .unwrap_or_else(|_| Err(StageError::new(ODR_ERR_TIMEOUT, "timeout", "overall deadline")))
        });
        let (handle, sid, endpoint) = match opened {
            Ok(v) => v,
            Err(e) => {
                hb_stop.store(true, Ordering::Relaxed);
                return Err(e);
            }
        };
        let status = handle.status().clone();
        let s = Box::new(UniSession { rt, target, handle, sid, hb_stop, hb_task, lock: Mutex::new(()),
            source_cfg: Mutex::new(Default::default()), source_failed: AtomicBool::new(false), endpoint: endpoint.clone(),
            lost: Mutex::new(None) });
        unsafe { *out_session = Box::into_raw(s) };
        Ok(serde_json::json!({ "stage": "session_open", "wda_status": status, "heartbeat": heartbeat != 0, "endpoint": endpoint }))
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// Applies source options: `{"animation_cool_off_s","wait_for_idle_s","excluded_attributes","source_deadline_s"}`
/// (all optional). Idle waits go through `POST /session/{id}/appium/settings` and must be confirmed by its readback
/// (WDA skips unknown keys silently); otherwise nothing is stored and the error carries requested vs effective
/// values. WDA settings are process-wide in the runner and outlive this session until set back or the runner exits.
///
/// # Safety
/// `s` from `uni_session_open` and not closed; `config_json` a C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_session_configure_source(
    s: *mut UniSession,
    config_json: *const c_char,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { session(s) }?;
        let raw = unsafe { req_str(config_json, "config_json") }?;
        let v: serde_json::Value = serde_json::from_str(raw)
            .map_err(|_| StageError::new(ODR_ERR_ARGUMENT, "source_config", "config is not JSON"))?;
        let (settings, cfg) =
            wda_apps::parse_source_config(&v).map_err(|m| StageError::new(ODR_ERR_ARGUMENT, "source_config", &m))?;
        let effective = if settings.is_empty() {
            serde_json::Value::Null
        } else {
            let t = Duration::from_secs(timeout_secs.max(1) as u64);
            let (p, port, sid) = (&*s.target.provider, s.handle.ports().http, s.sid.as_str());
            let all = on(s, t, async {
                wda_apps::apply_settings(p, port, t, sid, &settings)
                    .await
                    .map(serde_json::Value::Object)
                    .map_err(at(ODR_ERR_WDA_SESSION, "wda_settings"))
            })?;
            let all = all.as_object().cloned().unwrap_or_default();
            let relevant: serde_json::Map<_, _> = wda_apps::SOURCE_SETTING_KEYS
                .iter()
                .map(|k| ((*k).to_owned(), all.get(*k).cloned().unwrap_or(serde_json::Value::Null)))
                .collect();
            let missing = wda_apps::unconfirmed_settings(&settings, &all);
            if !missing.is_empty() {
                return Err(StageError::new(
                    ODR_ERR_WDA_SESSION,
                    "wda_settings_unconfirmed",
                    &format!("requested={} effective={} unconfirmed={missing:?}", serde_json::Value::Object(settings), serde_json::Value::Object(relevant)),
                ));
            }
            serde_json::Value::Object(relevant)
        };
        *s.source_cfg.lock().unwrap_or_else(|e| e.into_inner()) = cfg.clone();
        Ok(serde_json::json!({
            "stage": "configure_source",
            "requested_settings": settings,
            "effective_settings": effective,
            "source_route": cfg.route(),
            "observer": cfg.observer.as_str(),
            "excluded_attributes": cfg.excluded,
            "source_deadline_ms": cfg.deadline.unwrap_or(wda_apps::IDEVICE_DEFAULT_REQUEST_TIMEOUT).as_millis() as u64,
        }))
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// Same observation as `uni_observe`, inside the open session (no relaunch).
///
/// # Safety
/// `s` from `uni_session_open` and not closed; no concurrent close.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_session_observe(
    s: *mut UniSession,
    target_bundle_id: *const c_char,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { session(s) }?;
        let target = unsafe { req_str(target_bundle_id, "target_bundle_id") }?;
        on(s, Duration::from_secs(timeout_secs.max(1) as u64), observe_in(s, target))
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// Pre-action revalidation of one target (`POST /session/{id}/hermes/target`); see `revalidate_target_in`.
///
/// # Safety
/// As `uni_session_observe`; `request_json` a NUL-terminated JSON object.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_session_revalidate_target(
    s: *mut UniSession,
    request_json: *const c_char,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { session(s) }?;
        let raw = unsafe { req_str(request_json, "request_json") }?;
        let v: serde_json::Value = serde_json::from_str(raw).map_err(|e| StageError::new(ODR_ERR_ARGUMENT, "target_request_invalid", e.to_string()))?;
        on(s, Duration::from_secs(timeout_secs.max(1) as u64), revalidate_target_in(s, &v))
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// A bare WDA screenshot (no source, no app activation): used to see the pointer.
///
/// # Safety
/// As `uni_session_observe`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_session_screenshot(
    s: *mut UniSession,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { session(s) }?;
        on(s, Duration::from_secs(timeout_secs.max(1) as u64), screenshot_in(s))
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// Exactly one direct WDA tap at (x, y) window points of a `width` x `height` window. Never retried, never
/// replaced by another route; an overall deadline after the write is reported as uncertain, not as a timeout.
///
/// # Safety
/// As `uni_session_observe`.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn uni_session_tap(
    s: *mut UniSession,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { session(s) }?;
        let deadline = Duration::from_secs(timeout_secs.max(1) as u64).max(WDA_TAP_TIMEOUT * 2 + Duration::from_secs(1));
        on(s, deadline, tap_in(s, x, y, width, height)).map_err(|e| {
            if e.code == ODR_ERR_TIMEOUT {
                StageError::new(ODR_ERR_TAP_UNCERTAIN, "wda_tap_uncertain", "overall deadline; the tap may have landed")
            } else {
                e
            }
        })
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// Delete the WDA session (the target is not terminated), stop the runner and
/// the heartbeat, free the session. Null is a no-op.
///
/// # Safety
/// `s` null or from `uni_session_open`, closed at most once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_session_close(s: *mut UniSession) {
    if s.is_null() {
        return;
    }
    let s = unsafe { Box::from_raw(s) };
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let mut s = s;
        // A call still inside `on` on another thread holds the serial lock: tear down only after it returned.
        drop(s.lock.lock().unwrap_or_else(|e| e.into_inner()));
        // A lost session gets no DELETE: its port refused or its id is unknown, and whatever listens there now (a
        // newer runner) is not this session's.
        if s.lost.lock().unwrap_or_else(|e| e.into_inner()).is_none() {
            let wda = WdaClient::new(&*s.target.provider).with_ports(s.handle.ports());
            let _ = s.rt.block_on(tokio::time::timeout(Duration::from_secs(5), wda.delete_session(&s.sid)));
        }
        s.handle.abort();
        s.hb_stop.store(true, Ordering::Relaxed);
        if let Some(t) = s.hb_task.take() {
            let _ = s.rt.block_on(tokio::time::timeout(Duration::from_secs(2), t));
        }
        let UniSession { rt, .. } = *s;
        rt.shutdown_timeout(Duration::from_secs(1));
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use wda_apps::ActiveApp;

    fn app(b: &str, pid: i64) -> ActiveApp {
        ActiveApp { bundle_id: b.into(), pid, name: String::new() }
    }

    #[test]
    fn foreground_binding_refuses_mismatch_and_changes() {
        let sb = app("com.apple.springboard", 40);
        assert!(check_foreground(Some("com.apple.springboard"), &sb, Some(&sb)).is_ok());
        assert!(check_foreground(None, &app("net.whatsapp.WhatsApp", 9), Some(&app("net.whatsapp.WhatsApp", 9))).is_ok());
        let e = check_foreground(Some("com.apple.Preferences"), &sb, None).unwrap_err();
        assert_eq!((e.code, e.stage), (ODR_ERR_NOT_FOREGROUND, "foreground_mismatch"));
        let e = check_foreground(None, &sb, Some(&app("net.whatsapp.WhatsApp", 9))).unwrap_err();
        assert_eq!((e.code, e.stage), (ODR_ERR_NOT_FOREGROUND, "foreground_changed_during_observation"));
        let e = check_foreground(None, &sb, Some(&app("com.apple.springboard", 41))).unwrap_err();
        assert_eq!(e.stage, "foreground_changed_during_observation", "same bundle, relaunched process");
    }

    /// Offline guard (LATENCY_IMPROVEMENTS_REPORT.md): the agent's observation paths never request a screenshot;
    /// only `screenshot_in` (the explicit diagnostic) does.
    #[test]
    fn observation_paths_request_no_screenshot() {
        let src = include_str!("session.rs");
        for f in ["async fn observe_in(", "async fn observe_foreground_in(", "async fn observe_bound_in(", "async fn source_in("] {
            let start = src.find(f).unwrap_or_else(|| panic!("{f} not found"));
            let end = start + src[start..].find("\n}\n").expect("function end");
            let body = &src[start..end];
            assert!(!body.contains(".screenshot("), "{f} requests a screenshot");
            assert!(!body.contains("screenshot_png_b64"), "{f} returns a PNG");
        }
        assert!(src[src.find("async fn screenshot_in(").unwrap()..].contains(".screenshot("), "diagnostic screenshot kept");
    }

    /// SESSION_RECOVERY_REPORT.md: a refusal on any read, activation or mutation, or WDA's 404 for the session id,
    /// loses the session; a missing route, a deadline or an identity refusal does not.
    #[test]
    fn refusals_and_unknown_ids_lose_the_session_routes_and_deadlines_do_not() {
        let refused = "idevice socket io failed (kind=ConnectionRefused)";
        for stage in ["wda_activate_app", "wda_active_app_info", "wda_query_app_state", "wda_compact_connect", "wda_source", "wda_window_size", "wda_settings"] {
            assert_eq!(loss_reason(stage, refused), Some("connection_refused"), "{stage}");
        }
        assert_eq!(loss_reason("wda_tap_not_sent", "tap not sent: Connection refused (os error 61)"), Some("connection_refused"));
        let invalid = format!("{} (HTTP 404 invalid session id): the route exists; open a new session", wda_apps::COMPACT_INVALID_SESSION);
        assert_eq!(loss_reason("wda_compact_invalid_session", &invalid), Some("invalid_session"));
        assert_eq!(loss_reason("wda_query_app_state", "WDA error (status=404) Session does not exist"), Some("invalid_session"));
        let route = format!("{} (HTTP 404 unknown command)", wda_apps::COMPACT_UNAVAILABLE);
        assert_eq!(loss_reason("wda_compact_unavailable", &route), None, "a missing route is not a lost session");
        assert_eq!(loss_reason("timeout", "overall deadline"), None);
        assert_eq!(loss_reason("wda_compact_deadline", "source deadline"), None);
        assert_eq!(loss_reason("foreground_mismatch", "expected a in front, foreground is b"), None);
    }

    #[test]
    fn probe_verdict_names_the_endpoint() {
        assert_eq!(probe_verdict("refused", "accepted"), "runner_not_listening");
        assert_eq!(probe_verdict("accepted", "accepted"), "wda_port_accepts_again");
        assert_eq!(probe_verdict("refused", "refused"), "lockdown_refused");
        assert_eq!(probe_verdict("timeout", "timeout"), "tunnel_or_device_unreachable");
        assert_eq!(probe_verdict("error", "error"), "tunnel_or_device_unreachable");
    }

    /// Source guard: a lost session refuses before any request; close waits for the running call and sends no
    /// DELETE for a lost session; the loss is recorded where every entry point passes (`on`).
    #[test]
    fn lost_session_is_refused_unsent_and_closed_after_the_running_call() {
        let src = include_str!("session.rs");
        let on = &src[src.find("fn on<F>(").unwrap()..];
        let on = &on[..on.find("\n}\n").unwrap()];
        assert!(on.find("session_unusable").unwrap() < on.find("block_on").unwrap(), "refused before any request");
        assert!(on.contains("loss_reason(e.stage"), "every entry point records a loss");
        let close = &src[src.find("pub unsafe extern \"C\" fn uni_session_close(").unwrap()..];
        assert!(close.find("drop(s.lock.lock()").unwrap() < close.find("handle.abort()").unwrap(), "close waits for the call");
        assert!(close.find(".is_none()").unwrap() < close.find("delete_session").unwrap(), "no DELETE for a lost session");
    }
}

//! C ABI for the unified on-device agent (see ../../UNIFIED_APP_REPORT.md).
//!
//! * `uni_probe`: lockdown session through the in-app loopback tunnel.
//! * `uni_observe`: launch the separately signed WDA runner via testmanagerd
//!   and read the hierarchy + screenshot of a target app *without* relaunching
//!   or terminating it, so a post-action observation sees the state the action
//!   produced.
//!
//! Why not `../../real/runner-ffi`'s `odr_dump_source`: it opens the WDA
//! session with a `bundleId` capability. WDA (v16.15.3,
//! `FBSessionCommands.m` `prepareApplicationForSessionWithBundleID`) treats a
//! missing `forceAppLaunch` as true and relaunches a running app, and
//! `FBSession` terminates the tested application on session delete
//! (`shouldTerminateApp`). Both reset Settings to its root screen, which makes
//! "act, then observe again to verify" impossible. Here the session has no
//! tested application; the target is brought forward with WDA's own
//! `POST /session/{id}/wda/apps/activate` (plain `XCUIApplication activate`,
//! no relaunch) and checked with `POST /session/{id}/wda/apps/state` (4 =
//! running in foreground). See `wda_apps` for why not idevice's
//! `activate_app`/`query_app_state` (Appium `execute` scripts, 404 on WDA).
//!
//! The heartbeat module is the prototype's own file, included unchanged.

use std::ffi::{CStr, CString, c_char};
use std::net::IpAddr;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

mod heartbeat;
pub mod session;
pub mod wda_apps;

use idevice::{
    IdeviceError, IdeviceService,
    pairing_file::PairingFile,
    provider::{IdeviceProvider, TcpProvider},
    services::{
        dvt::xctest::{TestConfig, XCUITestService},
        heartbeat::HeartbeatClient,
        installation_proxy::InstallationProxyClient,
        lockdown::LockdownClient,
        wda::WdaClient,
    },
};

// Same codes as the prototype (heartbeat.rs refers to them by these names).
pub const ODR_OK: i32 = 0;
pub const ODR_ERR_ARGUMENT: i32 = -1;
pub const ODR_ERR_PAIRING_FILE: i32 = -2;
pub const ODR_ERR_LOCKDOWN: i32 = -3;
pub const ODR_ERR_INSTALLATION_PROXY: i32 = -4;
pub const ODR_ERR_XCTEST_LAUNCH: i32 = -5;
pub const ODR_ERR_WDA_SESSION: i32 = -6;
pub const ODR_ERR_WDA_SOURCE: i32 = -7;
pub const ODR_ERR_RUNTIME: i32 = -8;
pub const ODR_ERR_TIMEOUT: i32 = -9;
pub const ODR_ERR_PANIC: i32 = -10;
pub const ODR_ERR_HEARTBEAT: i32 = -11;
/// The target app was not in the foreground before or after the reads.
pub const ODR_ERR_NOT_FOREGROUND: i32 = -12;
/// `uni_session_tap`: the request was written but its result is unknown (may have landed). Never replay.
pub const ODR_ERR_TAP_UNCERTAIN: i32 = -13;
/// `uni_session_tap`: WDA refused the tap with a 4xx before tapping.
pub const ODR_ERR_TAP_REJECTED: i32 = -14;
/// `uni_session_tap`: nothing was written (bad coordinate, out of the window, connect failed).
pub const ODR_ERR_TAP_NOT_SENT: i32 = -15;

/// XCUIApplicationState.runningForeground.
const APP_STATE_FOREGROUND: i64 = 4;
/// Per-request deadline for the `wda_apps` routes (`activate` can wait for
/// the app to come forward).
const WDA_APPS_TIMEOUT: Duration = Duration::from_secs(30);
/// Observation JSON schema, checked by CoordinateCore (`Observation.schema`).
pub const OBSERVATION_SCHEMA: &str = "uni-observation/1";

#[derive(Debug)]
struct StageError {
    code: i32,
    stage: &'static str,
    detail: String,
    heartbeat: Option<serde_json::Value>,
    /// `session.rs` loss record (reason, stage, endpoint, connect-only probe); sent as `session_lost`.
    session_lost: Option<serde_json::Value>,
}

impl StageError {
    fn new(code: i32, stage: &'static str, detail: impl ToString) -> Self {
        Self {
            code,
            stage,
            detail: detail.to_string(),
            heartbeat: None,
            session_lost: None,
        }
    }
}

fn at(code: i32, stage: &'static str) -> impl FnOnce(IdeviceError) -> StageError {
    move |e| StageError::new(code, stage, describe(&e))
}

/// Socket errors keep only `io::ErrorKind` (never peer text); same rule as the prototype.
fn describe(e: &IdeviceError) -> String {
    match e {
        IdeviceError::Socket(io) => {
            let inner = if io.get_ref().is_some() { " wrapped" } else { "" };
            format!("{e} (kind={:?}{inner})", io.kind())
        }
        _ => e.to_string(),
    }
}

struct Target {
    provider: Arc<dyn IdeviceProvider>,
}

fn build_provider(pairing: &[u8], device_ip: &str) -> Result<Target, StageError> {
    let addr: IpAddr = device_ip
        .parse()
        .map_err(|_| StageError::new(ODR_ERR_ARGUMENT, "argument", "device_ip is not an IP address"))?;
    let pairing_file = PairingFile::from_bytes(pairing).map_err(|_| {
        StageError::new(ODR_ERR_PAIRING_FILE, "pairing_file", "not a valid pairing record")
    })?;
    Ok(Target {
        provider: Arc::new(TcpProvider {
            addr,
            scope_id: None,
            pairing_file,
            label: "unified-agent".into(),
        }),
    })
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Standard base64 (RFC 4648, padded). Local so the lockfile stays identical
/// to the prototype's.
fn base64(data: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= c.len() {
                out.push(A[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

async fn probe(t: &Target) -> Result<serde_json::Value, StageError> {
    let mut lockdown = LockdownClient::connect(&*t.provider)
        .await
        .map_err(at(ODR_ERR_LOCKDOWN, "lockdown_connect"))?;
    let pairing = t
        .provider
        .get_pairing_file()
        .await
        .map_err(at(ODR_ERR_PAIRING_FILE, "pairing_file"))?;
    lockdown
        .start_session(&pairing)
        .await
        .map_err(at(ODR_ERR_LOCKDOWN, "lockdown_session"))?;
    let version = lockdown
        .get_value(Some("ProductVersion"), None)
        .await
        .map_err(at(ODR_ERR_LOCKDOWN, "lockdown_get_value"))?;
    Ok(serde_json::json!({ "stage": "probe", "product_version": version.as_string() }))
}

fn foreground(state: i64, stage: &'static str) -> Result<(), StageError> {
    if state == APP_STATE_FOREGROUND {
        Ok(())
    } else {
        Err(StageError::new(ODR_ERR_NOT_FOREGROUND, stage, format!("app_state={state}")))
    }
}

async fn observe(
    t: &Target,
    runner_bundle_id: &str,
    target_bundle_id: &str,
    wda_ready_timeout: Duration,
) -> Result<serde_json::Value, StageError> {
    let cfg = {
        let mut proxy = InstallationProxyClient::connect(&*t.provider)
            .await
            .map_err(at(ODR_ERR_INSTALLATION_PROXY, "installation_proxy_connect"))?;
        // No XCTest target application: WDA addresses apps by bundle id itself,
        // and a target here would be launched by the test runner.
        TestConfig::from_installation_proxy(&mut proxy, runner_bundle_id, None)
            .await
            .map_err(at(ODR_ERR_INSTALLATION_PROXY, "resolve_runner"))?
    };
    let handle = XCUITestService::new(t.provider.clone())
        .run_until_wda_ready(cfg, wda_ready_timeout)
        .await
        .map_err(at(ODR_ERR_XCTEST_LAUNCH, "testmanagerd_launch_wda"))?;

    let result = async {
        let mut wda = WdaClient::new(&*t.provider).with_ports(handle.ports());
        let sid = wda
            .start_session(None)
            .await
            .map_err(at(ODR_ERR_WDA_SESSION, "wda_start_session"))?;
        let s = Some(sid.as_str());
        let read = async {
            let (p, port) = (&*t.provider, handle.ports().http);
            wda_apps::activate_app(p, port, WDA_APPS_TIMEOUT, &sid, target_bundle_id)
                .await
                .map_err(at(ODR_ERR_WDA_SESSION, "wda_activate_app"))?;
            let before = wda_apps::app_state(p, port, WDA_APPS_TIMEOUT, &sid, target_bundle_id)
                .await
                .map_err(at(ODR_ERR_WDA_SESSION, "wda_query_app_state"))?;
            foreground(before, "target_not_foreground_before")?;
            let window = wda.window_size(s).await.map_err(at(ODR_ERR_WDA_SOURCE, "wda_window_size"))?;
            let orientation = wda.orientation(s).await.map_err(at(ODR_ERR_WDA_SOURCE, "wda_orientation"))?;
            let source = wda.source(s).await.map_err(at(ODR_ERR_WDA_SOURCE, "wda_source"))?;
            let source_at = now_ms();
            let png = wda.screenshot(s).await.map_err(at(ODR_ERR_WDA_SOURCE, "wda_screenshot"))?;
            let screenshot_at = now_ms();
            let after = wda_apps::app_state(p, port, WDA_APPS_TIMEOUT, &sid, target_bundle_id)
                .await
                .map_err(at(ODR_ERR_WDA_SESSION, "wda_query_app_state"))?;
            foreground(after, "target_not_foreground_after")?;
            Ok::<_, StageError>(serde_json::json!({
                "schema": OBSERVATION_SCHEMA,
                "stage": "observe",
                "target_bundle_id": target_bundle_id,
                "app_state_before": before,
                "app_state_after": after,
                "window_size": window,
                "orientation": orientation,
                "source_xml": source,
                "source_unix_ms": source_at,
                "screenshot_png_b64": base64(&png),
                "screenshot_unix_ms": screenshot_at,
                "wda_status": handle.status(),
            }))
        }
        .await;
        // Session without a tested application: delete does not terminate the target.
        let _ = wda.delete_session(&sid).await;
        read
    }
    .await;
    handle.abort();
    result
}

fn run<F>(timeout: Duration, fut: F) -> Result<serde_json::Value, StageError>
where
    F: std::future::Future<Output = Result<serde_json::Value, StageError>>,
{
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|e| StageError::new(ODR_ERR_RUNTIME, "runtime", e))?;
    rt.block_on(async {
        tokio::time::timeout(timeout, fut)
            .await
            .unwrap_or_else(|_| Err(StageError::new(ODR_ERR_TIMEOUT, "timeout", "overall deadline")))
    })
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

unsafe fn req_str<'a>(p: *const c_char, name: &'static str) -> Result<&'a str, StageError> {
    if p.is_null() {
        return Err(StageError::new(ODR_ERR_ARGUMENT, "argument", format!("{name} is required")));
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .ok()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| StageError::new(ODR_ERR_ARGUMENT, "argument", format!("{name} is required UTF-8")))
}

unsafe fn bytes<'a>(p: *const u8, len: usize) -> Result<&'a [u8], StageError> {
    if p.is_null() || len == 0 {
        return Err(StageError::new(ODR_ERR_ARGUMENT, "argument", "pairing bytes are required"));
    }
    Ok(unsafe { std::slice::from_raw_parts(p, len) })
}

fn to_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "\u{FFFD}")).unwrap().into_raw()
}

unsafe fn finish(
    r: std::thread::Result<Result<serde_json::Value, StageError>>,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = r.unwrap_or_else(|_| Err(StageError::new(ODR_ERR_PANIC, "panic", "internal panic")));
    unsafe {
        if !out_json.is_null() {
            *out_json = std::ptr::null_mut();
        }
        if !out_err.is_null() {
            *out_err = std::ptr::null_mut();
        }
    }
    match r {
        Ok(v) => {
            if !out_json.is_null() {
                unsafe { *out_json = to_c(v.to_string()) };
            }
            ODR_OK
        }
        Err(e) => {
            if !out_err.is_null() {
                let mut msg = serde_json::json!({ "code": e.code, "stage": e.stage, "detail": e.detail });
                if let Some(hb) = e.heartbeat {
                    msg["heartbeat"] = hb;
                }
                if let Some(lost) = e.session_lost {
                    msg["session_lost"] = lost;
                }
                unsafe { *out_err = to_c(msg.to_string()) };
            }
            e.code
        }
    }
}

/// Lockdown session + `ProductVersion` through the tunnel at `device_ip`.
///
/// # Safety
/// `pairing` must point to `pairing_len` readable bytes; strings NUL-terminated; out pointers may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_probe(
    pairing: *const u8,
    pairing_len: usize,
    device_ip: *const c_char,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let ip = unsafe { req_str(device_ip, "device_ip") }?;
        let t = build_provider(unsafe { bytes(pairing, pairing_len) }?, ip)?;
        run(Duration::from_secs(timeout_secs.max(1) as u64), probe(&t))
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// State-preserving observation of `target_bundle_id` (required). With
/// `heartbeat != 0` the prototype's heartbeat is held for the whole call and
/// its snapshot is attached to the result or error.
///
/// # Safety
/// Same as [`uni_probe`].
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn uni_observe(
    pairing: *const u8,
    pairing_len: usize,
    device_ip: *const c_char,
    runner_bundle_id: *const c_char,
    target_bundle_id: *const c_char,
    heartbeat: i32,
    timeout_secs: u32,
    out_json: *mut *mut c_char,
    out_err: *mut *mut c_char,
) -> i32 {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let ip = unsafe { req_str(device_ip, "device_ip") }?;
        let runner = unsafe { req_str(runner_bundle_id, "runner_bundle_id") }?;
        let target = unsafe { req_str(target_bundle_id, "target_bundle_id") }?;
        let t = build_provider(unsafe { bytes(pairing, pairing_len) }?, ip)?;
        let total = Duration::from_secs(timeout_secs.max(10) as u64);
        let wda_ready = total.saturating_sub(Duration::from_secs(8));
        if heartbeat == 0 {
            return run(total, observe(&t, runner, target, wda_ready));
        }
        run(
            total + Duration::from_secs(1),
            heartbeat::with_heartbeat(
                HeartbeatClient::connect(&*t.provider),
                heartbeat::FIRST_MARCO_WAIT_SECS,
                total,
                || observe(&t, runner, target, wda_ready),
            ),
        )
    }));
    unsafe { finish(r, out_json, out_err) }
}

/// # Safety
/// `s` must be null or a pointer previously returned by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uni_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn uni_version() -> *const c_char {
    c"unified_ffi 0.1.0 (idevice 3854a5df4a5a, v0.1.68; heartbeat from runner-ffi 0.1.1-heartbeat-exp)".as_ptr()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_rfc4648_vectors() {
        let v = [("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"), ("foob", "Zm9vYg=="), ("fooba", "Zm9vYmE="), ("foobar", "Zm9vYmFy")];
        for (i, o) in v {
            assert_eq!(base64(i.as_bytes()), o);
        }
        assert_eq!(base64(&[0xff, 0xfe, 0x00]), "//4A");
    }

    #[test]
    fn only_running_foreground_passes() {
        assert!(foreground(4, "s").is_ok());
        for s in [0, 1, 2, 3] {
            let e = foreground(s, "target_not_foreground_before").unwrap_err();
            assert_eq!((e.code, e.stage), (ODR_ERR_NOT_FOREGROUND, "target_not_foreground_before"));
        }
    }
}

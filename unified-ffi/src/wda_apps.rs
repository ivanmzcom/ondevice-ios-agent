//! Direct WDA routes: activate and query app state, and one coordinate tap.
//!
//! idevice's `WdaClient::{activate_app, query_app_state}` send Appium
//! `mobile:` scripts to `/session/{id}/execute` and fall back to
//! `/execute/sync`. Those are Appium *server* routes; the standalone WDA
//! runner (v16.15.3, 02cb92f) answers them with 404 "Unhandled endpoint",
//! which is the physical failure at stage `wda_activate_app`. The runner's own
//! routes (`FBSessionCommands.m` `+routes`) are:
//!
//! * `POST /session/{id}/wda/apps/activate {"bundleId"}` →
//!   `[XCUIApplication activate]` (no relaunch, no terminate), value null.
//! * `POST /session/{id}/wda/apps/state {"bundleId"}` →
//!   `XCUIApplicationState` as an integer value.
//!
//! * `POST /session/{id}/wda/tap {"x","y"}` (`FBElementCommands.m` `+routes`
//!   line 119, `handleTap:`): with no `:uuid` the target is the session's
//!   active application, and `targetWithXyCoordinatesFromRequest` turns
//!   (x, y) into an `XCUICoordinate` offset from the app's (0, 0) on the main
//!   screen, i.e. window points as in `/source` frames. It answers 400 (invalid
//!   argument) before `[target tap]` when the coordinate cannot be built, and
//!   `FBResponseWithOK` after it.
//!
//! * `GET /session/{id}/wda/activeAppInfo` (`FBCustomCommands.m` line 60): the
//!   session's active app = the real foreground app (no tested app). Read-only.
//! * `POST /session/{id}/wda/pressButton {"name":"home"}` (line 69): Home.
//!
//! Same transport as `WdaClient::request_json` (fresh device connection,
//! `Connection: close`, JSON body), which is private upstream. There is no
//! fallback to any execute route.

use std::time::Duration;

use idevice::{IdeviceError, provider::IdeviceProvider};
use serde_json::{Value, json};

pub fn activate_path(session_id: &str) -> String {
    format!("/session/{session_id}/wda/apps/activate")
}

/// Connect error text with the socket's `io::ErrorKind` (same shape as lib.rs `describe`), so a refusal is
/// recognizable (`session::loss_reason`) whatever the OS wording is.
pub fn connect_text(e: &IdeviceError) -> String {
    match e {
        IdeviceError::Socket(io) => format!("{e} (kind={:?})", io.kind()),
        _ => e.to_string(),
    }
}

/// One connect-only probe of a device port through the provider (the tunnel): no byte is written, the connection
/// is dropped at once, never retried. `accepted` | `refused` | `timeout` | `error`.
pub async fn connect_probe(provider: &dyn IdeviceProvider, port: u16, timeout: Duration) -> &'static str {
    match tokio::time::timeout(timeout, provider.connect(port)).await {
        Err(_) => "timeout",
        Ok(Ok(_)) => "accepted",
        Ok(Err(IdeviceError::Socket(io))) if io.kind() == std::io::ErrorKind::ConnectionRefused => "refused",
        Ok(Err(_)) => "error",
    }
}

pub fn state_path(session_id: &str) -> String {
    format!("/session/{session_id}/wda/apps/state")
}

/// Brings `bundle_id` to the foreground without relaunching it.
pub async fn activate_app(
    provider: &dyn IdeviceProvider,
    port: u16,
    timeout: Duration,
    session_id: &str,
    bundle_id: &str,
) -> Result<(), IdeviceError> {
    post(provider, port, timeout, &activate_path(session_id), bundle_id)
        .await
        .map(|_| ())
}

/// Returns the `XCUIApplicationState` of `bundle_id` (4 = running foreground).
pub async fn app_state(
    provider: &dyn IdeviceProvider,
    port: u16,
    timeout: Duration,
    session_id: &str,
    bundle_id: &str,
) -> Result<i64, IdeviceError> {
    let response = post(provider, port, timeout, &state_path(session_id), bundle_id).await?;
    response
        .get("value")
        .and_then(Value::as_i64)
        .ok_or_else(|| IdeviceError::UnexpectedResponse("wda/apps/state value is not an integer".into()))
}

pub fn tap_path(session_id: &str) -> String {
    format!("/session/{session_id}/wda/tap")
}

/// Why a tap failed, split by whether it may have reached the screen.
#[derive(Debug, Clone, PartialEq)]
pub enum TapError {
    /// No request byte was written (bad coordinate, connect failed): nothing was tapped.
    NotSent(String),
    /// WDA answered 4xx: `handleTap` refuses before `[target tap]` (or the session is unknown).
    Rejected(String),
    /// The request was written but no clear answer came back (deadline, closed socket, 5xx, garbage).
    /// The tap may have landed; the caller must stop, never replay.
    Uncertain(String),
}

impl std::fmt::Display for TapError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TapError::NotSent(m) => write!(f, "tap not sent: {m}"),
            TapError::Rejected(m) => write!(f, "tap rejected by WDA: {m}"),
            TapError::Uncertain(m) => write!(f, "tap result uncertain: {m}"),
        }
    }
}

/// Exactly one `POST /session/{id}/wda/tap {"x","y"}` (window points). One connection, one write, no retry and
/// no other route on any failure.
pub async fn tap(
    provider: &dyn IdeviceProvider,
    port: u16,
    timeout: Duration,
    session_id: &str,
    x: f64,
    y: f64,
) -> Result<(), TapError> {
    if !x.is_finite() || !y.is_finite() {
        return Err(TapError::NotSent("coordinate is not finite".into()));
    }
    mutate(provider, port, timeout, &tap_path(session_id), &json!({ "x": x, "y": y }), client_error).await
}

pub fn active_app_info_path(session_id: &str) -> String {
    format!("/session/{session_id}/wda/activeAppInfo")
}

pub fn press_button_path(session_id: &str) -> String {
    format!("/session/{session_id}/wda/pressButton")
}

/// The app WDA's session acts on right now (`FBCustomCommands.m` `handleActiveAppInfo:`: the session's
/// `activeApplication`, which without a tested app is `fb_activeApplication`, the real foreground app). The same
/// app `/source` and `/wda/tap` use.
#[derive(Debug, Clone, PartialEq)]
pub struct ActiveApp {
    pub bundle_id: String,
    pub pid: i64,
    pub name: String,
}

/// `GET /session/{id}/wda/activeAppInfo`: read-only. A missing or empty `bundleId` is an error, never guessed.
pub async fn active_app(
    provider: &dyn IdeviceProvider,
    port: u16,
    timeout: Duration,
    session_id: &str,
) -> Result<ActiveApp, IdeviceError> {
    let request = format!(
        "GET {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        active_app_info_path(session_id)
    );
    let mut idevice = tokio::time::timeout(timeout, provider.connect(port))
        .await
        .map_err(|_| IdeviceError::UnknownErrorType("wda activeAppInfo connect timed out".into()))??;
    let json = tokio::time::timeout(timeout, async {
        idevice.send_raw(request.as_bytes()).await?;
        parse(&read_response(&mut idevice).await?)
    })
    .await
    .map_err(|_| IdeviceError::UnknownErrorType("wda activeAppInfo request timed out".into()))??;
    let value = json.get("value").and_then(Value::as_object);
    let bundle_id = value
        .and_then(|v| v.get("bundleId"))
        .and_then(Value::as_str)
        .filter(|b| !b.trim().is_empty())
        .ok_or_else(|| IdeviceError::UnexpectedResponse("activeAppInfo has no bundleId".into()))?;
    Ok(ActiveApp {
        bundle_id: bundle_id.to_owned(),
        pid: value.and_then(|v| v.get("pid")).and_then(Value::as_i64).unwrap_or(0),
        name: value.and_then(|v| v.get("name")).and_then(Value::as_str).unwrap_or("").to_owned(),
    })
}

/// Exactly one `POST /session/{id}/wda/pressButton {"name":"home"}` (`handlePressButtonCommand:`,
/// `XCUIDeviceButtonHome`). Same single-write semantics as `tap`.
pub async fn press_home(
    provider: &dyn IdeviceProvider,
    port: u16,
    timeout: Duration,
    session_id: &str,
) -> Result<(), TapError> {
    mutate(provider, port, timeout, &press_button_path(session_id), &json!({ "name": "home" }), client_error).await
}

/// Exactly one `POST /session/{id}/wda/apps/activate {"bundleId"}` as an explicit open-app action (the operator
/// chose direct activation for the requested app). Same single-write semantics as `tap`; `activate_app` stays the
/// observation path's call.
pub async fn activate_once(
    provider: &dyn IdeviceProvider,
    port: u16,
    timeout: Duration,
    session_id: &str,
    bundle_id: &str,
) -> Result<(), TapError> {
    if bundle_id.trim().is_empty() {
        return Err(TapError::NotSent("empty bundle id".into()));
    }
    mutate(provider, port, timeout, &activate_path(session_id), &json!({ "bundleId": bundle_id }), client_error).await
}

pub fn keys_path(session_id: &str) -> String {
    format!("/session/{session_id}/wda/keys")
}

/// Longest text typed in one request.
pub const MAX_TYPED_CHARS: usize = 500;

/// Why `text` is not typed (checked before anything is written). Control characters (newline, return, tab…)
/// and line/paragraph separators are refused: a typed return can submit a form or send a message, so submitting
/// is always a separate, explicit tap.
pub fn text_problem(text: &str) -> Option<&'static str> {
    if text.is_empty() {
        return Some("empty text");
    }
    if text.chars().count() > MAX_TYPED_CHARS {
        return Some("text longer than 500 characters");
    }
    if text.chars().any(|c| c.is_control() || c == '\u{2028}' || c == '\u{2029}') {
        return Some("text has a newline/return or another control character; submit with a separate tap");
    }
    None
}

/// Exactly one `POST /session/{id}/wda/keys {"value":[text]}` (`FBElementCommands.m` `handleKeys:`: `FBTypeText`
/// into whatever has keyboard focus in the active app). Same single-write semantics as `tap`, except that only
/// a 404 (unknown session or route) counts as "nothing typed": any other error after the write may come after
/// some characters were typed, so it is uncertain and never retyped.
pub async fn type_text(
    provider: &dyn IdeviceProvider,
    port: u16,
    timeout: Duration,
    session_id: &str,
    text: &str,
) -> Result<(), TapError> {
    if let Some(why) = text_problem(text) {
        return Err(TapError::NotSent(why.into()));
    }
    mutate(provider, port, timeout, &keys_path(session_id), &json!({ "value": [text] }), |s| s == 404).await
}

fn client_error(status: u16) -> bool {
    (400..500).contains(&status)
}

/// One connection, one write of `POST path body`, no retry, no other route. Classified by whether it may have
/// reached the screen.
async fn mutate(
    provider: &dyn IdeviceProvider,
    port: u16,
    timeout: Duration,
    path: &str,
    body: &Value,
    refused_before_acting: fn(u16) -> bool,
) -> Result<(), TapError> {
    let request = http_post(path, &body.to_string());
    let mut idevice = tokio::time::timeout(timeout, provider.connect(port))
        .await
        .map_err(|_| TapError::NotSent("connect timed out".into()))?
        .map_err(|e| TapError::NotSent(connect_text(&e)))?;
    // From the first written byte on, any failure is "may have landed".
    let response = tokio::time::timeout(timeout, async {
        idevice.send_raw(request.as_bytes()).await?;
        read_response(&mut idevice).await
    })
    .await
    .map_err(|_| TapError::Uncertain("no answer before the deadline".into()))?
    .map_err(|e| TapError::Uncertain(e.to_string()))?;
    match parse(&response) {
        Ok(_) => Ok(()),
        Err(e) => match status(&response) {
            Some(s) if refused_before_acting(s) => Err(TapError::Rejected(e.to_string())),
            _ => Err(TapError::Uncertain(e.to_string())),
        },
    }
}

fn http_post(path: &str, body: &str) -> String {
    format!(
        "POST {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: {}\r\nContent-Type: application/json\r\n\r\n{body}",
        body.len()
    )
}

async fn post(
    provider: &dyn IdeviceProvider,
    port: u16,
    timeout: Duration,
    path: &str,
    bundle_id: &str,
) -> Result<Value, IdeviceError> {
    let request = http_post(path, &json!({ "bundleId": bundle_id }).to_string());
    let mut idevice = provider.connect(port).await?;
    tokio::time::timeout(timeout, async {
        idevice.send_raw(request.as_bytes()).await?;
        parse(&read_response(&mut idevice).await?)
    })
    .await
    .map_err(|_| IdeviceError::UnknownErrorType("wda apps request timed out".into()))?
}

async fn read_response(idevice: &mut idevice::Idevice) -> Result<Vec<u8>, IdeviceError> {
    let mut response = Vec::new();
    loop {
        let chunk = match idevice.read_any(8192).await {
            Ok(c) => c,
            // Peer closed after a complete close-delimited response.
            Err(_) if complete(&response).is_some() => break,
            Err(e) => return Err(e),
        };
        if chunk.is_empty() {
            break;
        }
        response.extend_from_slice(&chunk);
        if complete(&response) == Some(true) {
            break;
        }
    }
    Ok(response)
}

fn status(response: &[u8]) -> Option<u16> {
    let end = find(response, b"\r\n\r\n")?;
    String::from_utf8_lossy(&response[..end]).lines().next()?.split_whitespace().nth(1)?.parse().ok()
}

/// `Some(true)` once headers and the full `Content-Length` body arrived,
/// `Some(false)` if headers arrived without a length, `None` before headers.
fn complete(response: &[u8]) -> Option<bool> {
    let end = find(response, b"\r\n\r\n")?;
    let headers = String::from_utf8_lossy(&response[..end]);
    Some(match content_length(&headers) {
        Some(len) => response.len() >= end + 4 + len,
        None => false,
    })
}

fn content_length(headers: &str) -> Option<usize> {
    headers.lines().skip(1).find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.trim().eq_ignore_ascii_case("content-length").then(|| v.trim().parse().ok())?
    })
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// The body after the header delimiter, cut to `Content-Length` when present. Framing only: no status check.
fn http_body(response: &[u8]) -> Option<&[u8]> {
    let end = find(response, b"\r\n\r\n")?;
    let body = &response[end + 4..];
    match content_length(&String::from_utf8_lossy(&response[..end])) {
        Some(len) => body.get(..len),
        None => Some(body),
    }
}

/// The JSON body of a non-2xx answer (`parse` refuses those, so it cannot be used to read a 404's `value.error`).
fn error_body(response: &[u8]) -> Option<Value> {
    serde_json::from_slice(http_body(response)?).ok()
}

fn parse(response: &[u8]) -> Result<Value, IdeviceError> {
    let bad = || IdeviceError::UnexpectedResponse("malformed WDA HTTP response".into());
    let end = find(response, b"\r\n\r\n").ok_or_else(bad)?;
    let headers = String::from_utf8_lossy(&response[..end]);
    let status: u16 = headers
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .ok_or_else(bad)?;
    let json: Value = serde_json::from_slice(http_body(response).ok_or_else(bad)?).map_err(|_| bad())?;
    let legacy_ok = match json.get("status") {
        None | Some(Value::Null) => true,
        Some(Value::Number(n)) => n.as_i64() == Some(0),
        Some(Value::String(s)) => s == "0",
        Some(_) => false,
    };
    if !(200..300).contains(&status) || !legacy_ok {
        let message = match json.get("value") {
            Some(Value::Object(o)) => o.get("message").or_else(|| o.get("error")).cloned().unwrap_or(Value::Null),
            Some(v) => v.clone(),
            None => Value::Null,
        };
        return Err(IdeviceError::UnknownErrorType(format!(
            "WDA error (status={status}): {message}"
        )));
    }
    Ok(json)
}

/// Attributes `UIElementSnapshot`'s parser and the gate read from `/source` XML: never excludable.
pub const PARSER_ATTRIBUTES: &[&str] = &["type", "name", "label", "value", "enabled", "visible", "x", "y", "width", "height"];

/// Attributes the pinned WDA (16.15.3, `FBXPath.m` `supportedAttributes`) writes by default that the parser never
/// reads. `accessible` is the costly one: `isWDAccessible` → `fb_isAccessibilityElement`
/// (`XCUIElement+FBAccessibility.m` 28–43) can issue one AX attribute request per element plus a parent walk.
/// The others are snapshot fields (payload size only).
pub const EXCLUDABLE_SOURCE_ATTRIBUTES: &[&str] = &["accessible", "index", "traits", "placeholderValue"];

/// `GET /session/{id}/source[?excluded_attributes=a,b]` (`FBDebugCommands.m` `handleGetSourceCommand:`, XML
/// format; `FBHTTPServer.m` copies URL query items into `request.parameters`). Names are from the fixed list above,
/// so they need no escaping.
pub fn source_path(session_id: &str, excluded: &[String]) -> String {
    if excluded.is_empty() {
        format!("/session/{session_id}/source")
    } else {
        format!("/session/{session_id}/source?excluded_attributes={}", excluded.join(","))
    }
}

/// Why a direct `/source` read failed.
#[derive(Debug, Clone, PartialEq)]
pub enum SourceError {
    /// The connection could not be opened before the deadline: nothing was requested.
    Connect(String),
    /// No complete answer before the source deadline. The connection is dropped here (each request owns a fresh
    /// `Connection: close` socket), so a late answer can never be read as another request's reply.
    Deadline(String),
    /// A complete answer that is an error, truncated or not an XML string. Never used as an observation.
    Bad(String),
}

impl std::fmt::Display for SourceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SourceError::Connect(m) => write!(f, "source connect failed: {m}"),
            SourceError::Deadline(m) => write!(f, "source deadline: {m}"),
            SourceError::Bad(m) => write!(f, "source answer unusable: {m}"),
        }
    }
}

/// One direct `/source` read with its own deadline (distinct from mutation and heartbeat deadlines).
pub async fn source(
    provider: &dyn IdeviceProvider,
    port: u16,
    deadline: Duration,
    session_id: &str,
    excluded: &[String],
) -> Result<String, SourceError> {
    let request = format!(
        "GET {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        source_path(session_id, excluded)
    );
    let started = tokio::time::Instant::now();
    let mut idevice = tokio::time::timeout(deadline, provider.connect(port))
        .await
        .map_err(|_| SourceError::Connect("connect timed out".into()))?
        .map_err(|e| SourceError::Connect(connect_text(&e)))?;
    let left = deadline.saturating_sub(started.elapsed());
    let response = tokio::time::timeout(left, async {
        idevice.send_raw(request.as_bytes()).await?;
        read_response(&mut idevice).await
    })
    .await
    .map_err(|_| SourceError::Deadline(format!("no complete answer within {} ms; connection dropped", deadline.as_millis())))?
    .map_err(|e| SourceError::Bad(e.to_string()))?;
    drop(idevice);
    let json = parse(&response).map_err(|e| SourceError::Bad(e.to_string()))?;
    json.get("value")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| SourceError::Bad("source value is not a string".into()))
}

/// Schema and endpoint version of the Hermes runner's compact observation (pinned WDA checkout,
/// `FBDebugCommands.m` `FBHermesObservationCommands`). Both must match exactly: the separately signed runner and this
/// app are version-gated against each other.
pub const COMPACT_OBSERVATION_SCHEMA: &str = "hermes-observation/1";
pub const COMPACT_ENDPOINT_VERSION: u64 = 1;
/// Prefix of the error for a runner without the route (an unpatched WDA answers 404 unknown command).
pub const COMPACT_UNAVAILABLE: &str = "compact observation endpoint unavailable on this runner";

/// `GET /session/{id}/hermes/observation` (session-bound `FBRoute GET:`, the same prefix as `/source`).
pub fn compact_observation_path(session_id: &str) -> String {
    format!("/session/{session_id}/hermes/observation")
}

/// One compact observation read with the source deadline, on a fresh `Connection: close` socket, never retried and
/// never replaced by `/source`. Only the envelope is checked here; Core (`WDACompactSource`) validates every node.
pub async fn compact_observation(
    provider: &dyn IdeviceProvider,
    port: u16,
    deadline: Duration,
    session_id: &str,
) -> Result<Value, SourceError> {
    let json = compact_get(provider, port, deadline, &compact_observation_path(session_id)).await?;
    check_compact(json.get("value").cloned().unwrap_or(Value::Null))
}

/// One `GET path` on a fresh `Connection: close` socket within `deadline`; a 404 is classified by `classify_compact_404`.
async fn compact_get(provider: &dyn IdeviceProvider, port: u16, deadline: Duration, path: &str) -> Result<Value, SourceError> {
    compact_request(provider, port, deadline, "GET", path, None).await
}

/// One request on its own `Connection: close` socket; GET (no body) or POST with a JSON body. Never retried.
async fn compact_request(
    provider: &dyn IdeviceProvider,
    port: u16,
    deadline: Duration,
    method: &str,
    path: &str,
    body: Option<&Value>,
) -> Result<Value, SourceError> {
    let request = match body {
        None => format!("{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"),
        Some(b) => {
            let b = b.to_string();
            format!(
                "{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{b}",
                b.len()
            )
        }
    };
    let started = tokio::time::Instant::now();
    let mut idevice = tokio::time::timeout(deadline, provider.connect(port))
        .await
        .map_err(|_| SourceError::Connect("connect timed out".into()))?
        .map_err(|e| SourceError::Connect(connect_text(&e)))?;
    let left = deadline.saturating_sub(started.elapsed());
    let response = tokio::time::timeout(left, async {
        idevice.send_raw(request.as_bytes()).await?;
        read_response(&mut idevice).await
    })
    .await
    .map_err(|_| SourceError::Deadline(format!("no complete answer within {} ms; connection dropped", deadline.as_millis())))?
    .map_err(|e| SourceError::Bad(e.to_string()))?;
    drop(idevice);
    if status(&response) == Some(404) {
        return Err(SourceError::Bad(compact_404_message(error_body(&response).as_ref())));
    }
    parse(&response).map_err(|e| SourceError::Bad(e.to_string()))
}

/// The kind of a compact-route 404. WDA answers two different 404s for `GET /session/{id}/hermes/observation`
/// (`FBCommandStatus.m`): `unknown command` from the catch-all `FBUnknownCommands` when no registered route matched the
/// path (the route is not in this runner), and `invalid session id` from `FBRoute decorateRequest:` when the route
/// matched but `{id}` is not the runner's one active session. Only `value.error` is read; the runner's `message`
/// echoes the request URL and parameters and is never copied.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Compact404 {
    RouteMissing,
    InvalidSession,
    Other,
}

pub fn classify_compact_404(body: Option<&Value>) -> Compact404 {
    match body.and_then(|b| b.get("value")).and_then(|v| v.get("error")).and_then(Value::as_str) {
        Some("unknown command") => Compact404::RouteMissing,
        Some("invalid session id") => Compact404::InvalidSession,
        _ => Compact404::Other,
    }
}

/// Prefix of the error for a 404 whose route matched but whose session id is not the runner's active session.
pub const COMPACT_INVALID_SESSION: &str = "compact observation session id is not the runner's active session";
/// Prefix of the error for a 404 that is neither WDA kind (no JSON body or another `value.error`).
pub const COMPACT_404_UNRECOGNIZED: &str = "compact observation HTTP 404 of unrecognized kind";

fn compact_404_message(body: Option<&Value>) -> String {
    match classify_compact_404(body) {
        Compact404::RouteMissing => format!(
            "{COMPACT_UNAVAILABLE} (HTTP 404 unknown command): install the Hermes-patched runner or choose the XML observer"
        ),
        Compact404::InvalidSession => {
            format!("{COMPACT_INVALID_SESSION} (HTTP 404 invalid session id): the route exists; open a new session")
        }
        Compact404::Other => format!("{COMPACT_404_UNRECOGNIZED} (body not a WDA unknown command/invalid session id)"),
    }
}

/// The bound compact observation (`?bind=1`, runner endpoint version 2): one request whose runner reads the foreground
/// identity (bundle, pid, orientation; the expected app's state) before and after its one snapshot and refuses any
/// difference. It replaces the separate `activeAppInfo`/`apps/state`, `/window/size`, `/orientation` reads and the
/// screenshot of a compact observation.
pub const COMPACT_BOUND_SCHEMA: &str = "hermes-observation/2";
pub const COMPACT_BOUND_ENDPOINT_VERSION: u64 = 2;

/// `GET /session/{id}/hermes/observation?bind=1[&expected_bundle_id=B]`. Bundle ids are refused, not escaped, unless
/// they are plain reverse-DNS characters.
pub fn bound_observation_path(session_id: &str, expected: Option<&str>) -> Result<String, String> {
    let base = format!("{}?bind=1", compact_observation_path(session_id));
    match expected {
        None => Ok(base),
        Some(b) if !b.is_empty() && b.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'.' || c == b'-' || c == b'_') => {
            Ok(format!("{base}&expected_bundle_id={b}"))
        }
        Some(_) => Err("expected bundle id has characters outside [A-Za-z0-9._-]".into()),
    }
}

/// One bound observation read: same transport, deadline and no-retry rules as `compact_observation`.
pub async fn bound_observation(
    provider: &dyn IdeviceProvider,
    port: u16,
    deadline: Duration,
    session_id: &str,
    expected: Option<&str>,
) -> Result<Value, SourceError> {
    let path = bound_observation_path(session_id, expected).map_err(SourceError::Bad)?;
    let json = compact_get(provider, port, deadline, &path).await?;
    Ok(json.get("value").cloned().unwrap_or(Value::Null))
}

/// A bound observation whose identity this client re-checked itself (the runner's `stable` flag alone is not trusted).
#[derive(Debug, Clone, PartialEq)]
pub struct BoundObservation {
    pub value: Value,
    pub bundle_id: String,
    pub pid: i64,
    pub window: Value,
    pub orientation: String,
    /// The expected app's `XCUIApplicationState` before/after; 4 for an unbound (foreground) read, as before.
    pub state_before: i64,
    pub state_after: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum BoundError {
    /// Not a usable version-2 answer (schema, version, missing or malformed identity, window, nodes).
    Bad(String),
    /// The foreground app or orientation was not the expected one, or changed during the read: (stage, detail).
    Identity(&'static str, String),
}

/// Fixed token for an `XCUIApplicationState` (never an app name).
fn app_state_token(s: Option<i64>) -> &'static str {
    match s {
        Some(1) => "not_running",
        Some(2) => "running_background_suspended",
        Some(3) => "running_background",
        Some(4) => "running_foreground",
        Some(0) => "unknown",
        Some(_) => "other",
        None => "absent",
    }
}

fn orientation_token(o: Option<&str>) -> &'static str {
    match o {
        Some("PORTRAIT") => "portrait",
        Some("LANDSCAPE") => "landscape",
        Some(_) => "other",
        None => "absent",
    }
}

/// Safe detail of an identity refusal: the refusal token and expected/actual state enums, never bundle ids or pids.
/// `FailureDetail.swift` parses exactly this shape.
fn identity_detail(stage: &str, id: &Value, expected: Option<&str>) -> String {
    let side = |k: &str| id.get(k).filter(|v| v.is_object());
    let field = |k: &str, f: &str| side(k).and_then(|o| o.get(f)).cloned();
    let (exp, act): (&str, &str) = match stage {
        "foreground_mismatch" => {
            let same = expected.is_some() && field("before", "bundle_id").and_then(|v| v.as_str().map(|b| Some(b) == expected)) == Some(true);
            ("target_app", if same { "target_app" } else { "other_app" })
        }
        "target_not_foreground_before" => ("running_foreground", app_state_token(field("before", "expected_state").and_then(|v| v.as_i64()))),
        "target_not_foreground_after" => ("running_foreground", app_state_token(field("after", "expected_state").and_then(|v| v.as_i64()))),
        "foreground_changed_during_observation" => {
            let changed = |f: &str| side("before").is_some() && side("after").is_some() && field("before", f) != field("after", f);
            ("same_app_pid", if changed("bundle_id") { "app_changed" } else if changed("pid") { "pid_changed" } else { "snapshot_app_differs" })
        }
        "orientation_changed_during_observation" => (
            orientation_token(field("before", "orientation").as_ref().and_then(Value::as_str)),
            orientation_token(field("after", "orientation").as_ref().and_then(Value::as_str)),
        ),
        _ => ("none", "none"),
    };
    format!("identity_refused reason={stage} expected={exp} actual={act}")
}

fn identity_stage(reason: &str) -> Option<&'static str> {
    Some(match reason {
        "foreground_mismatch" => "foreground_mismatch",
        "target_not_foreground_before" => "target_not_foreground_before",
        "target_not_foreground_after" => "target_not_foreground_after",
        "foreground_changed_during_observation" => "foreground_changed_during_observation",
        "orientation_changed_during_observation" => "orientation_changed_during_observation",
        _ => return None,
    })
}

/// Checks a bound answer: exact schema and version, the runner's verdict, and then independently that before and
/// after agree (bundle, pid, orientation), match `expected` (running foreground both times), match the snapshot's
/// own app and root pid, and that window and orientation are present and finite.
pub fn check_bound(value: Value, expected: Option<&str>) -> Result<BoundObservation, BoundError> {
    let bad = |m: String| BoundError::Bad(m);
    let schema = value.get("schema").and_then(Value::as_str);
    if schema != Some(COMPACT_BOUND_SCHEMA) {
        return Err(bad(format!("bound observation schema {schema:?}, expected {COMPACT_BOUND_SCHEMA}")));
    }
    let version = value.get("runner").and_then(|r| r.get("endpoint_version")).and_then(Value::as_u64);
    if version != Some(COMPACT_BOUND_ENDPOINT_VERSION) {
        return Err(bad(format!("runner endpoint_version {version:?}, this app needs {COMPACT_BOUND_ENDPOINT_VERSION}")));
    }
    let id = value.get("identity").ok_or_else(|| bad("no identity".into()))?;
    if let Some(reason) = id.get("refused").and_then(Value::as_str) {
        let stage = identity_stage(reason).ok_or_else(|| bad("unknown identity refusal".into()))?;
        // Before the before/after shape checks: an early refusal has `after: null` and no snapshot.
        return Err(BoundError::Identity(stage, identity_detail(stage, id, expected)));
    }
    let refuse = |stage: &'static str| BoundError::Identity(stage, identity_detail(stage, id, expected));
    if id.get("expected_bundle_id").and_then(Value::as_str) != expected {
        return Err(bad("identity is not bound to the requested app".into()));
    }
    let side = |k: &str| -> Result<(String, i64, String, Option<i64>), BoundError> {
        let o = id.get(k).ok_or_else(|| bad(format!("no identity.{k}")))?;
        let b = o.get("bundle_id").and_then(Value::as_str).filter(|b| !b.is_empty()).ok_or_else(|| bad(format!("identity.{k} without bundle_id")))?;
        let pid = o.get("pid").and_then(Value::as_i64).filter(|p| *p > 0).ok_or_else(|| bad(format!("identity.{k} without pid")))?;
        let ori = o.get("orientation").and_then(Value::as_str).ok_or_else(|| bad(format!("identity.{k} without orientation")))?;
        Ok((b.to_owned(), pid, ori.to_owned(), o.get("expected_state").and_then(Value::as_i64)))
    };
    let (before, after) = (side("before")?, side("after")?);
    // `true`; or `1` from runners that boxed the C comparison `@(nil == refused)` (`refused` is null here).
    let stable = id.get("stable");
    if !(stable.and_then(Value::as_bool) == Some(true) || stable.and_then(Value::as_u64) == Some(1)) {
        return Err(bad("runner did not mark the identity stable".into()));
    }
    if let Some(e) = expected {
        if before.0 != e {
            return Err(refuse("foreground_mismatch"));
        }
        if before.3 != Some(4) {
            return Err(refuse("target_not_foreground_before"));
        }
        if after.3 != Some(4) {
            return Err(refuse("target_not_foreground_after"));
        }
    }
    if before.0 != after.0 || before.1 != after.1 {
        return Err(refuse("foreground_changed_during_observation"));
    }
    if before.2 != after.2 {
        return Err(refuse("orientation_changed_during_observation"));
    }
    let app = value.get("app").ok_or_else(|| bad("no app".into()))?;
    let (ab, ap, rp) = (
        app.get("bundle_id").and_then(Value::as_str),
        app.get("pid").and_then(Value::as_i64),
        app.get("root_pid").and_then(Value::as_i64),
    );
    if ab != Some(before.0.as_str()) || ap != Some(before.1) || rp != Some(before.1) {
        return Err(refuse("foreground_changed_during_observation"));
    }
    if value.get("orientation").and_then(Value::as_str) != Some(after.2.as_str()) {
        return Err(bad("orientation is not the one read after the snapshot".into()));
    }
    let window = value.get("window").cloned().unwrap_or(Value::Null);
    let dim = |k: &str| window.get(k).and_then(Value::as_f64).filter(|v| v.is_finite() && *v > 0.0);
    if dim("width").is_none() || dim("height").is_none() {
        return Err(bad("no finite window from the snapshot".into()));
    }
    if !value.get("nodes").and_then(Value::as_array).is_some_and(|n| !n.is_empty()) {
        return Err(bad("bound observation without nodes".into()));
    }
    let (state_before, state_after) = match expected {
        Some(_) => (before.3.unwrap_or_default(), after.3.unwrap_or_default()),
        None => (4, 4),
    };
    Ok(BoundObservation { bundle_id: before.0, pid: before.1, window, orientation: after.2, state_before, state_after, value })
}

/// Pre-action target revalidation (`POST /session/{id}/hermes/target`, runner endpoint version 3). An explicit
/// capability of the Hermes runner: an older runner answers 404 `unknown command`, which fails the step before any tap;
/// nothing ever falls back to a full observation or to another route.
pub const TARGET_SCHEMA: &str = "hermes-target/1";
pub const TARGET_ENDPOINT_VERSION: u64 = 3;
pub const TARGET_MAX_MATCHES: u64 = 32;

/// `s1:` + 64 lowercase hex characters (runner `FBHermesScreenDigest`).
pub fn is_screen_digest(d: &str) -> bool {
    d.len() == 67 && d.starts_with("s1:") && d[3..].bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

pub fn target_path(session_id: &str) -> String {
    format!("/session/{session_id}/hermes/target")
}

/// Only these keys reach the runner; values typed as the runner requires.
pub fn target_request_body(v: &Value) -> Result<Value, String> {
    let o = v.as_object().ok_or("target request must be a JSON object")?;
    for k in o.keys() {
        if !["expected_bundle_id", "expected_pid", "expected_orientation", "name", "label", "max_matches"].contains(&k.as_str()) {
            return Err(format!("unknown target request key '{k}'"));
        }
    }
    let b = o.get("expected_bundle_id").and_then(Value::as_str).unwrap_or_default();
    if b.is_empty() || !b.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'.' || c == b'-' || c == b'_') {
        return Err("expected_bundle_id must be plain reverse-DNS characters".into());
    }
    if !o.get("expected_pid").and_then(Value::as_i64).is_some_and(|p| p > 0) {
        return Err("expected_pid must be a positive integer".into());
    }
    if !matches!(o.get("expected_orientation").and_then(Value::as_str), Some("PORTRAIT" | "LANDSCAPE")) {
        return Err("expected_orientation must be PORTRAIT or LANDSCAPE".into());
    }
    let text = |k: &str| match o.get(k) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::String(_)) => Ok(true),
        _ => Err(format!("{k} must be a string or null")),
    };
    if !(text("name")? | text("label")?) {
        return Err("target request needs a name and/or label".into());
    }
    if let Some(m) = o.get("max_matches")
        && !m.as_u64().is_some_and(|m| (1..=TARGET_MAX_MATCHES).contains(&m))
    {
        return Err(format!("max_matches must be within 1..={TARGET_MAX_MATCHES}"));
    }
    Ok(v.clone())
}

/// One target revalidation request: a fresh `Connection: close` socket, one write, no retry. A deadline is reported as
/// such and the request is not repeated.
pub async fn target_revalidation(
    provider: &dyn IdeviceProvider,
    port: u16,
    deadline: Duration,
    session_id: &str,
    body: &Value,
) -> Result<Value, SourceError> {
    let body = target_request_body(body).map_err(SourceError::Bad)?;
    let json = compact_request(provider, port, deadline, "POST", &target_path(session_id), Some(&body)).await?;
    Ok(json.get("value").cloned().unwrap_or(Value::Null))
}

/// Envelope + identity check of a target answer (Core re-checks every match against the observation). Identity
/// refusals keep their runner token; `process_changed`/`orientation_changed` are this route's own.
pub fn check_target(value: Value, expected_bundle: &str, expected_pid: i64) -> Result<Value, BoundError> {
    let bad = |m: String| BoundError::Bad(m);
    if value.get("schema").and_then(Value::as_str) != Some(TARGET_SCHEMA) {
        return Err(bad(format!("target answer schema is not {TARGET_SCHEMA}")));
    }
    if value.get("runner").and_then(|r| r.get("endpoint_version")).and_then(Value::as_u64) != Some(TARGET_ENDPOINT_VERSION) {
        return Err(bad(format!("target runner endpoint_version is not {TARGET_ENDPOINT_VERSION}")));
    }
    let id = value.get("identity").ok_or_else(|| bad("no identity".into()))?;
    if let Some(reason) = id.get("refused").and_then(Value::as_str) {
        let stage = match reason {
            "process_changed" => "target_process_changed",
            "orientation_changed" => "target_orientation_changed",
            r => identity_stage(r).ok_or_else(|| bad("unknown identity refusal".into()))?,
        };
        return Err(BoundError::Identity(stage, format!("identity_refused reason={reason}")));
    }
    if id.get("stable").and_then(Value::as_bool) != Some(true) {
        return Err(bad("runner did not mark the identity stable".into()));
    }
    let side = |k: &str| id.get(k).map(|o| (o.get("bundle_id").and_then(Value::as_str), o.get("pid").and_then(Value::as_i64),
                                          o.get("orientation").and_then(Value::as_str), o.get("expected_state").and_then(Value::as_i64)));
    let (b, a) = (side("before"), side("after"));
    let want = Some((Some(expected_bundle), Some(expected_pid)));
    if b.map(|s| (s.0, s.1)) != want || a.map(|s| (s.0, s.1)) != want {
        return Err(BoundError::Identity("foreground_changed_during_observation", "identity_refused reason=foreground_changed_during_observation".into()));
    }
    if b.map(|s| s.2) != a.map(|s| s.2) {
        return Err(BoundError::Identity("orientation_changed_during_observation", "identity_refused reason=orientation_changed_during_observation".into()));
    }
    if b.map(|s| s.3) != Some(Some(4)) || a.map(|s| s.3) != Some(Some(4)) {
        return Err(BoundError::Identity("target_not_foreground_after", "identity_refused reason=target_not_foreground_after".into()));
    }
    if !value.get("matches").is_some_and(Value::is_array) || !value.get("keyboards").is_some_and(Value::is_array) {
        return Err(bad("target answer without matches/keyboards arrays".into()));
    }
    // The fresh pre-tap baseline the post-tap verification compares against; without it nothing is tapped.
    if !value.get("screen_digest").and_then(Value::as_str).is_some_and(is_screen_digest) {
        return Err(bad("target answer without a valid screen_digest".into()));
    }
    Ok(value)
}

/// Envelope check of a compact observation: exact schema, exact runner endpoint version, a `nodes` array.
pub fn check_compact(value: Value) -> Result<Value, SourceError> {
    let schema = value.get("schema").and_then(Value::as_str);
    if schema != Some(COMPACT_OBSERVATION_SCHEMA) {
        return Err(SourceError::Bad(format!("compact observation schema {schema:?}, expected {COMPACT_OBSERVATION_SCHEMA}")));
    }
    let version = value.get("runner").and_then(|r| r.get("endpoint_version")).and_then(Value::as_u64);
    if version != Some(COMPACT_ENDPOINT_VERSION) {
        return Err(SourceError::Bad(format!(
            "runner endpoint_version {version:?}, this app needs {COMPACT_ENDPOINT_VERSION}"
        )));
    }
    if !value.get("nodes").is_some_and(Value::is_array) {
        return Err(SourceError::Bad("compact observation without a nodes array".into()));
    }
    Ok(value)
}

/// `/source` formats the read-only comparison sends, in order (`FBDebugCommands.m` 37–39). `json` goes through
/// `fb_tree:` (no libxml); `xml` is the task's exact request. Comparable reads, not one shared snapshot.
pub const COMPARE_FORMATS: &[&str] = &["json", "xml"];

/// The comparison route for `format`: `xml` is `source_path` unchanged (no `format` query, byte-for-byte the
/// task's direct request); `json` adds `format=json` before the same `excluded_attributes`.
pub fn compare_source_path(session_id: &str, format: &str, excluded: &[String]) -> String {
    if format == "xml" {
        return source_path(session_id, excluded);
    }
    let mut q = format!("/session/{session_id}/source?format={format}");
    if !excluded.is_empty() {
        q.push_str(&format!("&excluded_attributes={}", excluded.join(",")));
    }
    q
}

/// What one comparison read is allowed to report: status, sizes and fixed tokens, never body text.
#[derive(Debug, Clone, PartialEq)]
pub struct SourceProbe {
    /// `ok`, `http_error`, `truncated` or `bad_answer`.
    pub outcome: &'static str,
    pub http_status: Option<u16>,
    /// HTTP body bytes received (the body itself is dropped unread beyond JSON validity).
    pub response_bytes: usize,
    /// JSON type of `value`: `string`, `object`, `array`, `other` or `unparsed`.
    pub value_kind: &'static str,
    /// Fixed token for a WDA error message (`cannot_get_source`, `invalid_session`, `other`); the message is not kept.
    pub wda_error: Option<&'static str>,
}

impl SourceProbe {
    pub fn to_json(&self) -> Value {
        json!({
            "outcome": self.outcome,
            "http_status": self.http_status,
            "response_bytes": self.response_bytes,
            "value_kind": self.value_kind,
            "wda_error": self.wda_error,
        })
    }
}

/// Classifies a raw `/source` answer without keeping any of its text. Success needs a 2xx, a legacy status of 0 and
/// a `value` of the format's kind (`xml` → string, `json` → object).
pub fn classify_source_response(format: &str, response: &[u8]) -> SourceProbe {
    let mut p = SourceProbe { outcome: "bad_answer", http_status: status(response), response_bytes: 0, value_kind: "unparsed", wda_error: None };
    let Some(end) = find(response, b"\r\n\r\n") else { return p };
    let headers = String::from_utf8_lossy(&response[..end]);
    let mut body = &response[end + 4..];
    if let Some(len) = content_length(&headers) {
        if body.len() < len {
            p.response_bytes = body.len();
            p.outcome = "truncated";
            return p;
        }
        body = &body[..len];
    }
    p.response_bytes = body.len();
    let Ok(v) = serde_json::from_slice::<Value>(body) else { return p };
    let value = v.get("value");
    p.value_kind = match value {
        Some(Value::String(_)) => "string",
        Some(Value::Object(_)) => "object",
        Some(Value::Array(_)) => "array",
        _ => "other",
    };
    let legacy_ok = match v.get("status") {
        None | Some(Value::Null) => true,
        Some(Value::Number(n)) => n.as_i64() == Some(0),
        Some(Value::String(s)) => s == "0",
        Some(_) => false,
    };
    let ok_status = p.http_status.is_some_and(|s| (200..300).contains(&s));
    if ok_status && legacy_ok {
        let want = if format == "xml" { "string" } else { "object" };
        p.outcome = if p.value_kind == want { "ok" } else { "bad_answer" };
        return p;
    }
    p.outcome = "http_error";
    let message = value
        .and_then(|v| v.get("message").and_then(Value::as_str).or_else(|| v.as_str()))
        .unwrap_or("")
        .to_lowercase();
    p.wda_error = Some(if message.starts_with("cannot get '") && message.contains("source of the current application") {
        "cannot_get_source"
    } else if message.contains("session does not exist") || message.contains("invalid session id") {
        "invalid_session"
    } else {
        "other"
    });
    p
}

/// One comparison `/source` read: a fresh `Connection: close` socket, one request, never retried. Connect and
/// deadline failures are `SourceError`s (the socket is dropped); any complete answer is classified, not returned.
pub async fn probe_source(
    provider: &dyn IdeviceProvider,
    port: u16,
    deadline: Duration,
    session_id: &str,
    format: &str,
    excluded: &[String],
) -> Result<SourceProbe, SourceError> {
    let request = format!(
        "GET {} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        compare_source_path(session_id, format, excluded)
    );
    let started = tokio::time::Instant::now();
    let mut idevice = tokio::time::timeout(deadline, provider.connect(port))
        .await
        .map_err(|_| SourceError::Connect("connect timed out".into()))?
        .map_err(|e| SourceError::Connect(connect_text(&e)))?;
    let left = deadline.saturating_sub(started.elapsed());
    let response = tokio::time::timeout(left, async {
        idevice.send_raw(request.as_bytes()).await?;
        read_response(&mut idevice).await
    })
    .await
    .map_err(|_| SourceError::Deadline(format!("no complete answer within {} ms; connection dropped", deadline.as_millis())))?
    .map_err(|e| SourceError::Bad(e.to_string()))?;
    drop(idevice);
    Ok(classify_source_response(format, &response))
}

pub fn settings_path(session_id: &str) -> String {
    format!("/session/{session_id}/appium/settings")
}

/// `POST /session/{id}/appium/settings {"settings":{…}}` (`FBSessionCommands.m` `handleSetSettings:`): applies the
/// known keys and answers the full current settings (`FBSettingsHandler currentSettingsForSession:`). Unknown keys
/// are skipped silently upstream, so the caller must compare the readback.
pub async fn apply_settings(
    provider: &dyn IdeviceProvider,
    port: u16,
    timeout: Duration,
    session_id: &str,
    settings: &serde_json::Map<String, Value>,
) -> Result<serde_json::Map<String, Value>, IdeviceError> {
    let request = http_post(&settings_path(session_id), &json!({ "settings": settings }).to_string());
    let mut idevice = tokio::time::timeout(timeout, provider.connect(port))
        .await
        .map_err(|_| IdeviceError::UnknownErrorType("wda settings connect timed out".into()))??;
    let json = tokio::time::timeout(timeout, async {
        idevice.send_raw(request.as_bytes()).await?;
        parse(&read_response(&mut idevice).await?)
    })
    .await
    .map_err(|_| IdeviceError::UnknownErrorType("wda settings request timed out".into()))??;
    json.get("value")
        .and_then(Value::as_object)
        .cloned()
        .ok_or_else(|| IdeviceError::UnexpectedResponse("settings readback is not an object".into()))
}

/// Requested numeric settings the readback does not confirm (missing or different value).
pub fn unconfirmed_settings(requested: &serde_json::Map<String, Value>, effective: &serde_json::Map<String, Value>) -> Vec<String> {
    requested
        .iter()
        .filter(|(k, v)| match (v.as_f64(), effective.get(*k).and_then(Value::as_f64)) {
            (Some(a), Some(b)) => (a - b).abs() > 1e-6,
            _ => true,
        })
        .map(|(k, _)| k.clone())
        .collect()
}

/// Source read options kept by the session. Default = baseline (idevice's `WdaClient::source`, 10 s request timeout).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SourceConfig {
    pub excluded: Vec<String>,
    pub deadline: Option<Duration>,
    /// Which read serves observations. `Xml` (default) keeps the `/source` routes above unchanged.
    pub observer: Observer,
}

impl SourceConfig {
    pub fn is_baseline(&self) -> bool {
        self.excluded.is_empty() && self.deadline.is_none() && self.observer == Observer::Xml
    }

    /// `compact` (Hermes runner route), `idevice_default` (baseline XML) or `direct` (XML with options).
    pub fn route(&self) -> &'static str {
        match self.observer {
            Observer::Compact => "compact",
            Observer::Xml if self.is_baseline() => "idevice_default",
            Observer::Xml => "direct",
        }
    }
}

/// The observation read the operator chose: WDA `/source` XML (baseline) or the compact projection of the
/// Hermes-patched runner (`GET /session/{id}/hermes/observation`). Never switched automatically.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Observer {
    #[default]
    Xml,
    Compact,
}

impl Observer {
    pub fn as_str(self) -> &'static str {
        match self {
            Observer::Xml => "xml",
            Observer::Compact => "compact",
        }
    }
}

/// idevice `WdaClient::new` per-request timeout (`wda.rs` line 65), the baseline source deadline.
pub const IDEVICE_DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
/// The source deadline must leave room inside the app's 45 s overall observe deadline.
pub const MAX_SOURCE_DEADLINE_S: f64 = 40.0;
/// Idle waits may only be lowered from WDA's defaults (`FBConfiguration.m` 352–353), never raised.
pub const MAX_ANIMATION_COOL_OFF_S: f64 = 2.0;
pub const MAX_WAIT_FOR_IDLE_S: f64 = 10.0;
/// Settings keys this app may set and reads back.
pub const SOURCE_SETTING_KEYS: &[&str] = &["animationCoolOffTimeout", "waitForIdleTimeout"];

/// Validates `{"animation_cool_off_s","wait_for_idle_s","excluded_attributes","source_deadline_s","observer"}` (all optional,
/// nothing else accepted) into WDA settings to apply and the session's source options.
pub fn parse_source_config(v: &Value) -> Result<(serde_json::Map<String, Value>, SourceConfig), String> {
    let o = v.as_object().ok_or("source config must be a JSON object")?;
    let mut settings = serde_json::Map::new();
    let mut cfg = SourceConfig::default();
    for (k, val) in o {
        let num = |max: f64, min: f64| -> Result<f64, String> {
            let n = val.as_f64().filter(|n| n.is_finite()).ok_or(format!("{k} must be a number"))?;
            if n < min || n > max {
                return Err(format!("{k} must be within {min}..={max}"));
            }
            Ok(n)
        };
        match k.as_str() {
            "animation_cool_off_s" => {
                settings.insert("animationCoolOffTimeout".into(), json!(num(MAX_ANIMATION_COOL_OFF_S, 0.0)?));
            }
            "wait_for_idle_s" => {
                settings.insert("waitForIdleTimeout".into(), json!(num(MAX_WAIT_FOR_IDLE_S, 0.0)?));
            }
            "source_deadline_s" => cfg.deadline = Some(Duration::from_secs_f64(num(MAX_SOURCE_DEADLINE_S, 1.0)?)),
            "observer" => {
                cfg.observer = match val.as_str() {
                    Some("xml") => Observer::Xml,
                    Some("compact") => Observer::Compact,
                    _ => return Err("observer must be \"xml\" or \"compact\"".into()),
                }
            }
            "excluded_attributes" => {
                let list = val.as_array().ok_or("excluded_attributes must be an array of names")?;
                for a in list {
                    let a = a.as_str().ok_or("excluded_attributes must be an array of names")?;
                    if PARSER_ATTRIBUTES.iter().any(|p| p.eq_ignore_ascii_case(a)) {
                        return Err(format!("'{a}' is read by the observation parser and cannot be excluded"));
                    }
                    let known = EXCLUDABLE_SOURCE_ATTRIBUTES
                        .iter()
                        .find(|e| e.eq_ignore_ascii_case(a))
                        .ok_or(format!("'{a}' is not an excludable source attribute"))?;
                    if !cfg.excluded.iter().any(|x| x == known) {
                        cfg.excluded.push((*known).to_owned());
                    }
                }
            }
            _ => return Err(format!("unknown source config key '{k}'")),
        }
    }
    Ok((settings, cfg))
}

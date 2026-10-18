//! Regression for the physical failure `-6 wda_activate_app: WDA error
//! (status=404) Unhandled endpoint /session/<id>/execute/sync`: activate and
//! state must use the standalone WDA runner's own routes. A scripted HTTP peer
//! on 127.0.0.1 stands in for WDA (reached through idevice's real
//! `TcpProvider::connect`, as on device) and records every request.

use std::net::{IpAddr, Ipv4Addr};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use idevice::{IdeviceError, pairing_file::PairingFile, provider::TcpProvider};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use unified_ffi::wda_apps;

const SID: &str = "6F1C-SESSION";
const BUNDLE: &str = "com.apple.Preferences";
const T: Duration = Duration::from_secs(5);

#[derive(Debug, Clone)]
struct Seen {
    method: String,
    path: String,
    content_type: Option<String>,
    body: serde_json::Value,
}

/// Structurally valid, entirely fake pairing plist (TcpProvider needs one; it
/// is never used for a TLS handshake on the WDA port).
fn provider() -> TcpProvider {
    let pem = |l: &str| format!("-----BEGIN {l}-----\nU1lOVEhFVElD\n-----END {l}-----\n").into_bytes();
    let mut d = plist::Dictionary::new();
    for k in ["DeviceCertificate", "HostCertificate", "RootCertificate"] {
        d.insert(k.into(), plist::Value::Data(pem("CERTIFICATE")));
    }
    d.insert("HostPrivateKey".into(), plist::Value::Data(pem("PRIVATE KEY")));
    d.insert("RootPrivateKey".into(), plist::Value::Data(pem("PRIVATE KEY")));
    d.insert("SystemBUID".into(), "00000000-SYNTHETIC".into());
    d.insert("HostID".into(), "00000000-SYNTHETIC-HOST".into());
    d.insert("WiFiMACAddress".into(), "00:00:00:00:00:00".into());
    let mut out = Vec::new();
    plist::Value::Dictionary(d).to_writer_xml(&mut out).unwrap();
    TcpProvider {
        addr: IpAddr::V4(Ipv4Addr::LOCALHOST),
        scope_id: None,
        pairing_file: PairingFile::from_bytes(&out).unwrap(),
        label: "wda-routes-test".into(),
    }
}

/// Serves one scripted raw HTTP response per accepted connection, in order,
/// and records each request. Anything unscripted gets WDA's real 404.
async fn peer(responses: Vec<String>) -> (u16, Arc<Mutex<Vec<Seen>>>) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    tokio::spawn(async move {
        let mut responses = responses.into_iter();
        loop {
            let Ok((mut sock, _)) = listener.accept().await else { return };
            let mut buf = Vec::new();
            let mut chunk = [0u8; 4096];
            let (head, body) = loop {
                let n = sock.read(&mut chunk).await.unwrap();
                buf.extend_from_slice(&chunk[..n]);
                if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    let head = String::from_utf8(buf[..i].to_vec()).unwrap();
                    let len: usize = header(&head, "content-length").map_or(0, |v| v.parse().unwrap());
                    while buf.len() < i + 4 + len {
                        let n = sock.read(&mut chunk).await.unwrap();
                        assert!(n > 0, "client closed before sending body");
                        buf.extend_from_slice(&chunk[..n]);
                    }
                    break (head, buf[i + 4..i + 4 + len].to_vec());
                }
                assert!(n > 0, "client closed before headers");
            };
            let mut start = head.lines().next().unwrap().split_whitespace();
            let (method, path) = (start.next().unwrap().to_owned(), start.next().unwrap().to_owned());
            log.lock().unwrap().push(Seen {
                method,
                path: path.clone(),
                content_type: header(&head, "content-type"),
                body: serde_json::from_slice(&body).unwrap_or(serde_json::Value::Null),
            });
            let reply = responses.next().unwrap_or_else(|| {
                http(404, &format!(r#"{{"value":{{"error":"unknown command","message":"Unhandled endpoint: {path}"}},"sessionId":"{SID}"}}"#))
            });
            let _ = sock.write_all(reply.as_bytes()).await;
            let _ = sock.shutdown().await;
        }
    });
    (port, seen)
}

fn header(head: &str, name: &str) -> Option<String> {
    head.lines().skip(1).find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.trim().eq_ignore_ascii_case(name).then(|| v.trim().to_owned())
    })
}

fn http(status: u16, body: &str) -> String {
    format!("HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len())
}

fn ok(value: &str) -> String {
    http(200, &format!(r#"{{"value":{value},"sessionId":"{SID}"}}"#))
}

fn assert_no_execute(seen: &[Seen]) {
    for s in seen {
        assert!(!s.path.contains("/execute"), "Appium execute route used: {}", s.path);
    }
}

#[tokio::test]
async fn activate_then_state_use_direct_wda_routes() {
    let (port, seen) = peer(vec![ok("null"), ok("4")]).await;
    let p = provider();
    wda_apps::activate_app(&p, port, T, SID, BUNDLE).await.unwrap();
    assert_eq!(wda_apps::app_state(&p, port, T, SID, BUNDLE).await.unwrap(), 4);

    let seen = seen.lock().unwrap().clone();
    assert_no_execute(&seen);
    let expected = [
        format!("/session/{SID}/wda/apps/activate"),
        format!("/session/{SID}/wda/apps/state"),
    ];
    assert_eq!(seen.len(), 2, "{seen:?}");
    for (s, path) in seen.iter().zip(expected) {
        assert_eq!(s.method, "POST");
        assert_eq!(s.path, path);
        assert_eq!(s.content_type.as_deref(), Some("application/json"));
        assert_eq!(s.body, serde_json::json!({ "bundleId": BUNDLE }));
    }
}

#[tokio::test]
async fn background_state_is_returned_not_coerced() {
    let (port, _) = peer(vec![ok("3")]).await;
    assert_eq!(wda_apps::app_state(&provider(), port, T, SID, BUNDLE).await.unwrap(), 3);
}

#[tokio::test]
async fn http_404_is_an_error_without_any_fallback_request() {
    // No scripted replies: the peer answers like a WDA lacking the route.
    let (port, seen) = peer(vec![]).await;
    let err = wda_apps::activate_app(&provider(), port, T, SID, BUNDLE).await.unwrap_err();
    let msg = err.to_string();
    assert!(msg.contains("status=404") && msg.contains("Unhandled endpoint"), "{msg}");
    let seen = seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1, "must not retry another route: {seen:?}");
    assert_no_execute(&seen);
}

#[tokio::test]
async fn legacy_nonzero_status_is_an_error() {
    let body = format!(r#"{{"status":13,"value":"boom","sessionId":"{SID}"}}"#);
    let (port, _) = peer(vec![http(200, &body)]).await;
    let err = wda_apps::app_state(&provider(), port, T, SID, BUNDLE).await.unwrap_err();
    assert!(err.to_string().contains("boom"), "{err}");
}

#[tokio::test]
async fn non_integer_state_is_rejected() {
    let (port, _) = peer(vec![ok(r#""4""#)]).await;
    let err = wda_apps::app_state(&provider(), port, T, SID, BUNDLE).await.unwrap_err();
    assert!(matches!(err, IdeviceError::UnexpectedResponse(_)), "{err:?}");
}

#[tokio::test]
async fn malformed_and_truncated_responses_are_errors() {
    let truncated = "HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n{\"value\":4".to_owned();
    let (port, _) = peer(vec!["garbage".into(), truncated]).await;
    let p = provider();
    assert!(wda_apps::app_state(&p, port, T, SID, BUNDLE).await.is_err());
    assert!(wda_apps::app_state(&p, port, T, SID, BUNDLE).await.is_err());
}

#[tokio::test]
async fn closed_port_is_an_error() {
    let port = {
        let l = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        l.local_addr().unwrap().port()
    };
    assert!(wda_apps::activate_app(&provider(), port, T, SID, BUNDLE).await.is_err());
}

// --- direct coordinate tap: POST /session/{id}/wda/tap {"x","y"} (FBElementCommands.m, v16.15.3) ---

/// Accepts connections, records each request, and never answers (holds the socket open).
async fn silent_peer() -> (u16, Arc<Mutex<Vec<Seen>>>, Arc<Mutex<usize>>) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (seen, conns) = (Arc::new(Mutex::new(Vec::new())), Arc::new(Mutex::new(0usize)));
    let (log, count) = (seen.clone(), conns.clone());
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else { return };
            *count.lock().unwrap() += 1;
            let log = log.clone();
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                loop {
                    let n = sock.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 { return; }
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8(buf[..i].to_vec()).unwrap();
                        let len: usize = header(&head, "content-length").map_or(0, |v| v.parse().unwrap());
                        if buf.len() >= i + 4 + len {
                            let mut start = head.lines().next().unwrap().split_whitespace();
                            log.lock().unwrap().push(Seen {
                                method: start.next().unwrap().into(),
                                path: start.next().unwrap().into(),
                                content_type: header(&head, "content-type"),
                                body: serde_json::from_slice(&buf[i + 4..i + 4 + len]).unwrap_or(serde_json::Value::Null),
                            });
                            tokio::time::sleep(Duration::from_secs(30)).await;
                            return;
                        }
                    }
                }
            });
        }
    });
    (port, seen, conns)
}

#[tokio::test]
async fn tap_posts_exact_route_and_body_once() {
    let (port, seen) = peer(vec![ok("null")]).await;
    wda_apps::tap(&provider(), port, T, SID, 195.0, 122.5).await.unwrap();
    let seen = seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1, "{seen:?}");
    assert_no_execute(&seen);
    assert_eq!(seen[0].method, "POST");
    assert_eq!(seen[0].path, format!("/session/{SID}/wda/tap"));
    assert_eq!(wda_apps::tap_path(SID), format!("/session/{SID}/wda/tap"));
    assert_eq!(seen[0].content_type.as_deref(), Some("application/json"));
    assert_eq!(seen[0].body, serde_json::json!({ "x": 195.0, "y": 122.5 }));
    assert_eq!(seen[0].body.as_object().unwrap().len(), 2, "no element, no extra keys");
}

#[tokio::test]
async fn tap_timeout_is_uncertain_after_exactly_one_send() {
    let (port, seen, conns) = silent_peer().await;
    let err = wda_apps::tap(&provider(), port, Duration::from_millis(400), SID, 10.0, 20.0).await.unwrap_err();
    assert!(matches!(err, wda_apps::TapError::Uncertain(_)), "{err:?}");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(*conns.lock().unwrap(), 1, "one connection, no replay");
    let seen = seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1, "{seen:?}");
    assert_eq!(seen[0].path, format!("/session/{SID}/wda/tap"));
    assert_no_execute(&seen);
}

#[tokio::test]
async fn tap_4xx_is_rejected_without_fallback() {
    let body = format!(r#"{{"value":{{"error":"invalid argument","message":"bad"}},"sessionId":"{SID}"}}"#);
    let (port, seen) = peer(vec![http(400, &body)]).await;
    let err = wda_apps::tap(&provider(), port, T, SID, 1.0, 1.0).await.unwrap_err();
    assert!(matches!(&err, wda_apps::TapError::Rejected(m) if m.contains("status=400")), "{err:?}");
    // unknown session (WDA 404) is also a refusal before any tap
    let (port2, seen2) = peer(vec![]).await;
    assert!(matches!(wda_apps::tap(&provider(), port2, T, SID, 1.0, 1.0).await, Err(wda_apps::TapError::Rejected(_))));
    assert_eq!(seen.lock().unwrap().len(), 1);
    assert_eq!(seen2.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn tap_5xx_and_garbage_are_uncertain() {
    let (port, _) = peer(vec![http(500, r#"{"value":{"message":"boom"}}"#), "garbage".into()]).await;
    let p = provider();
    assert!(matches!(wda_apps::tap(&p, port, T, SID, 1.0, 1.0).await, Err(wda_apps::TapError::Uncertain(_))));
    assert!(matches!(wda_apps::tap(&p, port, T, SID, 1.0, 1.0).await, Err(wda_apps::TapError::Uncertain(_))));
}

#[tokio::test]
async fn tap_refused_port_and_nonfinite_are_not_sent() {
    let port = {
        let l = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        l.local_addr().unwrap().port()
    };
    assert!(matches!(wda_apps::tap(&provider(), port, T, SID, 1.0, 1.0).await, Err(wda_apps::TapError::NotSent(_))));
    let (port, seen) = peer(vec![]).await;
    assert!(matches!(wda_apps::tap(&provider(), port, T, SID, f64::NAN, 1.0).await, Err(wda_apps::TapError::NotSent(_))));
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn tap_bounds_are_strict_and_never_clamped() {
    use unified_ffi::session::tap_in_bounds as b;
    assert!(b(195.0, 422.0, 390.0, 844.0));
    for (x, y) in [(0.0, 1.0), (390.0, 1.0), (1.0, 844.0), (-1.0, 1.0), (1.0, f64::INFINITY), (f64::NAN, 1.0)] {
        assert!(!b(x, y, 390.0, 844.0), "({x}, {y})");
    }
    assert!(!b(1.0, 1.0, 0.0, 844.0));
}

// ---- cross-app: activeAppInfo (read-only), pressButton home and explicit activate (single-write mutations) ----

#[tokio::test]
async fn active_app_info_is_one_get_of_the_session_route() {
    let (port, seen) = peer(vec![ok(r#"{"pid":812,"bundleId":"com.apple.springboard","name":"SpringBoard","processArguments":{}}"#)]).await;
    let a = wda_apps::active_app(&provider(), port, T, SID).await.unwrap();
    assert_eq!(a, wda_apps::ActiveApp { bundle_id: "com.apple.springboard".into(), pid: 812, name: "SpringBoard".into() });
    let seen = seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1, "{seen:?}");
    assert_no_execute(&seen);
    assert_eq!(seen[0].method, "GET");
    assert_eq!(seen[0].path, format!("/session/{SID}/wda/activeAppInfo"));
}

#[tokio::test]
async fn active_app_without_bundle_id_is_refused_not_guessed() {
    for value in [r#"{"pid":1,"name":"x"}"#, r#"{"pid":1,"bundleId":""}"#, "null", r#""com.apple.springboard""#] {
        let (port, seen) = peer(vec![ok(value)]).await;
        assert!(wda_apps::active_app(&provider(), port, T, SID).await.is_err(), "{value}");
        assert_eq!(seen.lock().unwrap().len(), 1, "no second request for {value}");
    }
}

#[tokio::test]
async fn active_app_404_and_timeout_are_errors_without_fallback() {
    let (port, seen) = peer(vec![]).await;
    assert!(wda_apps::active_app(&provider(), port, T, SID).await.is_err());
    let seen = seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1, "{seen:?}");
    assert_no_execute(&seen);
    let (port, seen, conns) = silent_peer().await;
    assert!(wda_apps::active_app(&provider(), port, Duration::from_millis(400), SID).await.is_err());
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(*conns.lock().unwrap(), 1);
    assert_eq!(seen.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn press_home_posts_exact_route_and_body_once() {
    let (port, seen) = peer(vec![ok("null")]).await;
    wda_apps::press_home(&provider(), port, T, SID).await.unwrap();
    let seen = seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1, "{seen:?}");
    assert_no_execute(&seen);
    assert_eq!((seen[0].method.as_str(), seen[0].path.clone()), ("POST", format!("/session/{SID}/wda/pressButton")));
    assert_eq!(seen[0].body, serde_json::json!({ "name": "home" }));
    assert!(!seen.iter().any(|s| s.path.contains("homescreen")), "no session-less homescreen route");
}

#[tokio::test]
async fn press_home_timeout_is_uncertain_and_not_replayed() {
    let (port, seen, conns) = silent_peer().await;
    let err = wda_apps::press_home(&provider(), port, Duration::from_millis(400), SID).await.unwrap_err();
    assert!(matches!(err, wda_apps::TapError::Uncertain(_)), "{err:?}");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(*conns.lock().unwrap(), 1, "one connection, no replay");
    assert_eq!(seen.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn press_home_4xx_rejected_5xx_uncertain() {
    let (port, _) = peer(vec![http(400, r#"{"value":{"error":"invalid argument","message":"not supported"}}"#)]).await;
    assert!(matches!(wda_apps::press_home(&provider(), port, T, SID).await, Err(wda_apps::TapError::Rejected(_))));
    let (port, seen) = peer(vec![http(500, r#"{"value":{"error":"unknown error","message":"x"}}"#)]).await;
    assert!(matches!(wda_apps::press_home(&provider(), port, T, SID).await, Err(wda_apps::TapError::Uncertain(_))));
    assert_eq!(seen.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn explicit_activate_once_posts_bundle_once_and_never_on_empty() {
    let (port, seen) = peer(vec![ok("null")]).await;
    wda_apps::activate_once(&provider(), port, T, SID, "net.whatsapp.WhatsApp").await.unwrap();
    let seen = seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].path, format!("/session/{SID}/wda/apps/activate"));
    assert_eq!(seen[0].body, serde_json::json!({ "bundleId": "net.whatsapp.WhatsApp" }));
    let (port, seen) = peer(vec![]).await;
    assert!(matches!(wda_apps::activate_once(&provider(), port, T, SID, " ").await, Err(wda_apps::TapError::NotSent(_))));
    assert!(seen.lock().unwrap().is_empty());
}

#[tokio::test]
async fn type_text_posts_wda_keys_once_with_utf8_text() {
    let (port, seen) = peer(vec![ok("null")]).await;
    wda_apps::type_text(&provider(), port, T, SID, "Hola, ¿qué tal? 👋").await.unwrap();
    let seen = seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1, "{seen:?}");
    assert_no_execute(&seen);
    assert_eq!((seen[0].method.as_str(), seen[0].path.clone()), ("POST", format!("/session/{SID}/wda/keys")));
    assert_eq!(seen[0].body, serde_json::json!({ "value": ["Hola, ¿qué tal? 👋"] }));
}

#[tokio::test]
async fn type_text_timeout_and_non_404_errors_are_uncertain_never_retyped() {
    let (port, seen, conns) = silent_peer().await;
    let err = wda_apps::type_text(&provider(), port, Duration::from_millis(400), SID, "hola").await.unwrap_err();
    assert!(matches!(err, wda_apps::TapError::Uncertain(_)), "{err:?}");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!((*conns.lock().unwrap(), seen.lock().unwrap().len()), (1, 1), "one connection, one write");
    // FBTypeText failing part-way answers 400 invalid element state: some keys may already be typed
    let body = format!(r#"{{"value":{{"error":"invalid element state","message":"x"}},"sessionId":"{SID}"}}"#);
    let (port, seen) = peer(vec![http(400, &body), http(500, "{}")]).await;
    let p = provider();
    assert!(matches!(wda_apps::type_text(&p, port, T, SID, "a").await, Err(wda_apps::TapError::Uncertain(_))));
    assert!(matches!(wda_apps::type_text(&p, port, T, SID, "a").await, Err(wda_apps::TapError::Uncertain(_))));
    assert_eq!(seen.lock().unwrap().len(), 2);
    // unknown session / route: nothing was typed
    let (port, _) = peer(vec![]).await;
    assert!(matches!(wda_apps::type_text(&provider(), port, T, SID, "a").await, Err(wda_apps::TapError::Rejected(_))));
}

#[tokio::test]
async fn type_text_refuses_newline_control_empty_and_long_before_writing() {
    let (port, seen) = peer(vec![]).await;
    let long = "x".repeat(wda_apps::MAX_TYPED_CHARS + 1);
    for t in ["", "hola\n", "a\rb", "tab\t", "sep\u{2028}", long.as_str()] {
        assert!(matches!(wda_apps::type_text(&provider(), port, T, SID, t).await, Err(wda_apps::TapError::NotSent(_))), "{t:?}");
    }
    assert!(wda_apps::text_problem(&"x".repeat(wda_apps::MAX_TYPED_CHARS)).is_none());
    assert!(seen.lock().unwrap().is_empty());
}

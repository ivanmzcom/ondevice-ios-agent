//! Source-timeout levers against a scripted WDA peer on 127.0.0.1 (idevice's real `TcpProvider::connect`):
//! exact `/source` route and query, `/appium/settings` body and readback check, the source-specific deadline,
//! truncated answers, and that a late answer on a dropped connection is never read as the next reply.

use std::net::{IpAddr, Ipv4Addr};
use std::time::Duration;

use idevice::{pairing_file::PairingFile, provider::TcpProvider};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use unified_ffi::session;
use unified_ffi::wda_apps::{self, SourceError};

const SID: &str = "6F1C-SESSION";
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

fn ok(value: serde_json::Value) -> String {
    let body = json!({ "value": value, "sessionId": SID }).to_string();
    format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len())
}

/// Reads one request (head + Content-Length body) and returns (request line, body).
async fn read_request(sock: &mut TcpStream) -> (String, String) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = sock.read(&mut chunk).await.unwrap();
        assert!(n > 0, "client closed early");
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8(buf[..i].to_vec()).unwrap();
            let len: usize = head
                .lines()
                .find_map(|l| l.split_once(':').filter(|(k, _)| k.eq_ignore_ascii_case("content-length")).map(|(_, v)| v.trim().parse().unwrap()))
                .unwrap_or(0);
            while buf.len() < i + 4 + len {
                let n = sock.read(&mut chunk).await.unwrap();
                buf.extend_from_slice(&chunk[..n]);
            }
            return (head.lines().next().unwrap().to_owned(), String::from_utf8(buf[i + 4..i + 4 + len].to_vec()).unwrap());
        }
    }
}

/// One scripted raw answer per connection, each after its delay; request lines and bodies go to the channel.
async fn peer(script: Vec<(Duration, String)>) -> (u16, tokio::sync::mpsc::UnboundedReceiver<(String, String)>) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    tokio::spawn(async move {
        for (delay, answer) in script {
            let Ok((mut sock, _)) = listener.accept().await else { return };
            let tx = tx.clone();
            tokio::spawn(async move {
                let req = read_request(&mut sock).await;
                let _ = tx.send(req);
                tokio::time::sleep(delay).await;
                let _ = sock.write_all(answer.as_bytes()).await;
                let _ = sock.shutdown().await;
            });
        }
    });
    (port, rx)
}

const XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?><AppiumAUT><XCUIElementTypeApplication type="XCUIElementTypeApplication" name="Synthetic" label="Synthetic" enabled="true" visible="true" x="0" y="0" width="390" height="844"><XCUIElementTypeButton type="XCUIElementTypeButton" name="send" label="Send" enabled="true" visible="true" x="300" y="780" width="60" height="44"/></XCUIElementTypeApplication></AppiumAUT>"#;

#[test]
fn source_path_is_the_pinned_route_with_optional_query() {
    assert_eq!(wda_apps::source_path(SID, &[]), format!("/session/{SID}/source"));
    let ex = vec!["accessible".to_owned(), "index".to_owned()];
    assert_eq!(wda_apps::source_path(SID, &ex), format!("/session/{SID}/source?excluded_attributes=accessible,index"));
    assert_eq!(wda_apps::settings_path(SID), format!("/session/{SID}/appium/settings"));
}

#[test]
fn config_validation_never_drops_parser_attributes_or_raises_idle_waits() {
    let (settings, cfg) = wda_apps::parse_source_config(&json!({
        "animation_cool_off_s": 0.5, "wait_for_idle_s": 3, "excluded_attributes": ["Accessible", "traits", "accessible"],
        "source_deadline_s": 25
    }))
    .unwrap();
    assert_eq!(serde_json::Value::Object(settings), json!({ "animationCoolOffTimeout": 0.5, "waitForIdleTimeout": 3.0 }));
    assert_eq!(cfg.excluded, vec!["accessible", "traits"]);
    assert_eq!(cfg.deadline, Some(Duration::from_secs(25)));
    let (s, c) = wda_apps::parse_source_config(&json!({})).unwrap();
    assert!(s.is_empty() && c.is_baseline());
    for bad in [
        json!({ "excluded_attributes": ["visible"] }),
        json!({ "excluded_attributes": ["X"] }),
        json!({ "excluded_attributes": ["hittable"] }),
        json!({ "animation_cool_off_s": 2.5 }),
        json!({ "wait_for_idle_s": 11 }),
        json!({ "wait_for_idle_s": -1 }),
        json!({ "source_deadline_s": 0.5 }),
        json!({ "source_deadline_s": 41 }),
        json!({ "snapshotMaxDepth": 10 }),
        json!({ "customSnapshotTimeout": 5 }),
        json!([1]),
    ] {
        assert!(wda_apps::parse_source_config(&bad).is_err(), "accepted {bad}");
    }
    for p in wda_apps::PARSER_ATTRIBUTES {
        assert!(wda_apps::parse_source_config(&json!({ "excluded_attributes": [p] })).is_err());
    }
}

#[test]
fn readback_must_confirm_every_requested_setting() {
    let req = json!({ "animationCoolOffTimeout": 0.5, "waitForIdleTimeout": 3.0 });
    let req = req.as_object().unwrap();
    let good = json!({ "animationCoolOffTimeout": 0.5, "waitForIdleTimeout": 3, "snapshotMaxDepth": 50 });
    assert!(wda_apps::unconfirmed_settings(req, good.as_object().unwrap()).is_empty());
    // WDA skips unknown keys silently: the readback keeps the old value or lacks the key.
    let stale = json!({ "animationCoolOffTimeout": 2.0 });
    assert_eq!(wda_apps::unconfirmed_settings(req, stale.as_object().unwrap()), vec!["animationCoolOffTimeout", "waitForIdleTimeout"]);
}

#[tokio::test]
async fn settings_post_has_the_exact_body_and_returns_the_readback() {
    let readback = json!({ "animationCoolOffTimeout": 0.5, "waitForIdleTimeout": 10, "snapshotMaxDepth": 50 });
    let (port, mut rx) = peer(vec![(Duration::ZERO, ok(readback.clone()))]).await;
    let req = json!({ "animationCoolOffTimeout": 0.5 });
    let got = wda_apps::apply_settings(&provider(), port, Duration::from_secs(5), SID, req.as_object().unwrap()).await.unwrap();
    let (line, body) = rx.recv().await.unwrap();
    assert_eq!(line, format!("POST /session/{SID}/appium/settings HTTP/1.1"));
    assert_eq!(serde_json::from_str::<serde_json::Value>(&body).unwrap(), json!({ "settings": { "animationCoolOffTimeout": 0.5 } }));
    assert_eq!(serde_json::Value::Object(got), readback);
}

#[tokio::test]
async fn direct_source_uses_the_exact_query_and_returns_the_xml() {
    let (port, mut rx) = peer(vec![(Duration::ZERO, ok(json!(XML)))]).await;
    let ex = vec!["accessible".to_owned()];
    let xml = wda_apps::source(&provider(), port, Duration::from_secs(5), SID, &ex).await.unwrap();
    assert_eq!(xml, XML);
    let (line, body) = rx.recv().await.unwrap();
    assert_eq!(line, format!("GET /session/{SID}/source?excluded_attributes=accessible HTTP/1.1"));
    assert!(body.is_empty());
}

#[tokio::test]
async fn slow_source_hits_its_own_deadline_and_the_late_answer_is_never_the_next_reply() {
    let late = ok(json!("<late/>"));
    let (port, _rx) = peer(vec![(Duration::from_millis(900), late), (Duration::ZERO, ok(json!(XML)))]).await;
    let p = provider();
    let t0 = std::time::Instant::now();
    let e = wda_apps::source(&p, port, Duration::from_millis(250), SID, &[]).await.unwrap_err();
    assert!(matches!(e, SourceError::Deadline(_)), "{e:?}");
    assert!(t0.elapsed() < Duration::from_millis(800));
    // Wait until the first connection's late answer was written, then read again: a fresh connection, fresh answer.
    tokio::time::sleep(Duration::from_millis(900)).await;
    let xml = wda_apps::source(&p, port, Duration::from_secs(5), SID, &[]).await.unwrap();
    assert_eq!(xml, XML);
}

#[tokio::test]
async fn truncated_or_non_string_source_is_refused() {
    let truncated = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 400\r\n\r\n{\"value\":\"<AppiumAUT>".to_owned();
    let (port, _rx) = peer(vec![(Duration::ZERO, truncated), (Duration::ZERO, ok(json!({ "not": "xml" })))]).await;
    let p = provider();
    let e = wda_apps::source(&p, port, Duration::from_secs(5), SID, &[]).await.unwrap_err();
    assert!(matches!(e, SourceError::Bad(_)), "{e:?}");
    let e = wda_apps::source(&p, port, Duration::from_secs(5), SID, &[]).await.unwrap_err();
    assert!(matches!(e, SourceError::Bad(_)), "{e:?}");
}

#[tokio::test]
async fn wda_error_answer_is_refused_not_used() {
    let body = json!({ "value": { "error": "unknown error", "message": "Cannot get 'xml' source of the current application" } }).to_string();
    let err = format!("HTTP/1.1 500 Internal Server Error\r\nContent-Length: {}\r\n\r\n{body}", body.len());
    let (port, _rx) = peer(vec![(Duration::ZERO, err)]).await;
    let e = wda_apps::source(&provider(), port, Duration::from_secs(5), SID, &[]).await.unwrap_err();
    assert!(matches!(e, SourceError::Bad(_)), "{e:?}");
}

// ---- Read-only JSON/XML comparison (SOURCE_COMPARE_REPORT.md) ----

fn raw(status: &str, body: &str) -> String {
    format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len())
}

#[test]
fn compare_paths_keep_the_task_xml_request_and_add_only_format_json() {
    let ex = vec!["accessible".to_owned(), "index".to_owned()];
    assert_eq!(wda_apps::compare_source_path(SID, "xml", &ex), wda_apps::source_path(SID, &ex));
    assert_eq!(wda_apps::compare_source_path(SID, "xml", &[]), format!("/session/{SID}/source"));
    assert_eq!(
        wda_apps::compare_source_path(SID, "json", &ex),
        format!("/session/{SID}/source?format=json&excluded_attributes=accessible,index")
    );
    assert_eq!(wda_apps::compare_source_path(SID, "json", &[]), format!("/session/{SID}/source?format=json"));
    assert_eq!(wda_apps::COMPARE_FORMATS, &["json", "xml"]);
}

#[test]
fn classification_keeps_status_size_and_tokens_but_no_text() {
    let secret = "Mamá: nos vemos 🙂";
    let tree = json!({ "value": { "type": "XCUIElementTypeApplication", "label": secret, "children": [] } }).to_string();
    let p = wda_apps::classify_source_response("json", raw("200 OK", &tree).as_bytes());
    assert_eq!((p.outcome, p.http_status, p.value_kind, p.wda_error), ("ok", Some(200), "object", None));
    assert_eq!(p.response_bytes, tree.len());
    assert!(!p.to_json().to_string().contains("Mam"), "no body text may leave the probe");

    let xml = json!({ "value": XML }).to_string();
    assert_eq!(wda_apps::classify_source_response("xml", raw("200 OK", &xml).as_bytes()).outcome, "ok");
    // Wrong kind for the format.
    assert_eq!(wda_apps::classify_source_response("json", raw("200 OK", &xml).as_bytes()).outcome, "bad_answer");

    let e500 = json!({ "value": { "error": "unknown error", "message": "Cannot get 'xml' source of the current application", "traceback": "" } }).to_string();
    let p = wda_apps::classify_source_response("xml", raw("500 Internal Server Error", &e500).as_bytes());
    assert_eq!((p.outcome, p.http_status, p.wda_error), ("http_error", Some(500), Some("cannot_get_source")));
    assert!(!p.to_json().to_string().contains("Cannot"));

    let gone = json!({ "value": { "error": "invalid session id", "message": "Session does not exist" } }).to_string();
    assert_eq!(wda_apps::classify_source_response("json", raw("404 Not Found", &gone).as_bytes()).wda_error, Some("invalid_session"));
    let other = json!({ "value": { "message": secret } }).to_string();
    let p = wda_apps::classify_source_response("json", raw("500 Internal Server Error", &other).as_bytes());
    assert_eq!(p.wda_error, Some("other"));
    assert!(!p.to_json().to_string().contains("Mam"));

    let cut = "HTTP/1.1 200 OK\r\nContent-Length: 400\r\n\r\n{\"value\":{";
    let p = wda_apps::classify_source_response("json", cut.as_bytes());
    assert_eq!((p.outcome, p.response_bytes), ("truncated", 10));
    assert_eq!(wda_apps::classify_source_response("json", b"garbage").outcome, "bad_answer");
}

#[tokio::test]
async fn probe_sends_one_exact_request_and_classifies_a_500() {
    let e500 = json!({ "value": { "message": "Cannot get 'xml' source of the current application" } }).to_string();
    let (port, mut rx) = peer(vec![(Duration::ZERO, raw("500 Internal Server Error", &e500))]).await;
    let ex = vec!["accessible".to_owned()];
    let p = wda_apps::probe_source(&provider(), port, Duration::from_secs(5), SID, "xml", &ex).await.unwrap();
    assert_eq!((p.outcome, p.http_status, p.wda_error), ("http_error", Some(500), Some("cannot_get_source")));
    let (line, _) = rx.recv().await.unwrap();
    assert_eq!(line, format!("GET /session/{SID}/source?excluded_attributes=accessible HTTP/1.1"));
    assert!(rx.try_recv().is_err(), "never retried");
}

#[tokio::test]
async fn slow_probe_hits_the_same_source_deadline() {
    let (port, _rx) = peer(vec![(Duration::from_millis(900), ok(json!({})))]).await;
    let t0 = std::time::Instant::now();
    let e = wda_apps::probe_source(&provider(), port, Duration::from_millis(250), SID, "json", &[]).await.unwrap_err();
    assert!(matches!(e, SourceError::Deadline(_)), "{e:?}");
    assert!(t0.elapsed() < Duration::from_millis(800));
}

// ---- Compact observer (COMPACT_RUNNER_REPORT.md): Hermes runner route, no fallback to /source ----

fn compact_value() -> serde_json::Value {
    json!({
        "schema": "hermes-observation/1",
        "observation_id": "SYNTH-1",
        "runner": { "endpoint": "hermes/observation", "endpoint_version": 1, "wda_version": "16.15.3", "runner_bundle_id": "synthetic.runner" },
        "app": { "bundle_id": "com.example.synthetic", "pid": 42, "root_pid": 42 },
        "window": { "width": 390, "height": 844 },
        "orientation": "PORTRAIT",
        "truncated": false,
        "node_count": 1,
        "nodes": [{ "id": 0, "parent": -1, "depth": 0, "type": "XCUIElementTypeApplication", "label": "Synthetic",
                    "enabled": true, "visible": true, "rect": [0, 0, 390, 844] }]
    })
}

#[test]
fn observer_config_is_validated_and_compact_is_never_the_baseline_route() {
    let (_, cfg) = wda_apps::parse_source_config(&json!({})).unwrap();
    assert_eq!((cfg.observer, cfg.route()), (wda_apps::Observer::Xml, "idevice_default"));
    let (_, cfg) = wda_apps::parse_source_config(&json!({ "observer": "xml", "source_deadline_s": 30 })).unwrap();
    assert_eq!((cfg.observer, cfg.route()), (wda_apps::Observer::Xml, "direct"));
    let (settings, cfg) = wda_apps::parse_source_config(&json!({ "observer": "compact" })).unwrap();
    assert!(settings.is_empty());
    assert_eq!((cfg.observer, cfg.route()), (wda_apps::Observer::Compact, "compact"));
    assert!(!cfg.is_baseline());
    for bad in [json!({ "observer": "json" }), json!({ "observer": true }), json!({ "observer": "COMPACT" })] {
        assert!(wda_apps::parse_source_config(&bad).is_err(), "{bad}");
    }
}

#[test]
fn compact_path_is_the_namespaced_session_route() {
    assert_eq!(wda_apps::compact_observation_path(SID), format!("/session/{SID}/hermes/observation"));
}

#[test]
fn compact_schema_version_and_nodes_are_checked() {
    assert_eq!(wda_apps::check_compact(compact_value()).unwrap(), compact_value());
    let mut v = compact_value();
    v["schema"] = json!("hermes-observation/2");
    assert!(matches!(wda_apps::check_compact(v), Err(SourceError::Bad(_))));
    let mut v = compact_value();
    v["runner"]["endpoint_version"] = json!(2);
    assert!(matches!(wda_apps::check_compact(v), Err(SourceError::Bad(_))));
    let mut v = compact_value();
    v.as_object_mut().unwrap().remove("nodes");
    assert!(matches!(wda_apps::check_compact(v), Err(SourceError::Bad(_))));
    assert!(matches!(wda_apps::check_compact(json!("<AppiumAUT/>")), Err(SourceError::Bad(_))));
}

#[tokio::test]
async fn compact_observation_sends_one_exact_request_and_returns_the_object() {
    let (port, mut rx) = peer(vec![(Duration::ZERO, ok(compact_value()))]).await;
    let v = wda_apps::compact_observation(&provider(), port, Duration::from_secs(5), SID).await.unwrap();
    assert_eq!(v, compact_value());
    let (line, body) = rx.recv().await.unwrap();
    assert_eq!(line, format!("GET /session/{SID}/hermes/observation HTTP/1.1"));
    assert!(body.is_empty());
}

#[tokio::test]
async fn unpatched_runner_is_unavailable_never_a_fallback() {
    let body = json!({ "value": { "error": "unknown command", "message": "Unhandled endpoint" } }).to_string();
    let (port, mut rx) = peer(vec![(Duration::ZERO, raw("404 Not Found", &body))]).await;
    let e = wda_apps::compact_observation(&provider(), port, Duration::from_secs(5), SID).await.unwrap_err();
    assert!(matches!(&e, SourceError::Bad(m) if m.starts_with(wda_apps::COMPACT_UNAVAILABLE)), "{e:?}");
    let (line, _) = rx.recv().await.unwrap();
    assert_eq!(line, format!("GET /session/{SID}/hermes/observation HTTP/1.1"));
    assert!(rx.try_recv().is_err(), "exactly one request, never a /source retry");
}

#[tokio::test]
async fn compact_404_invalid_session_is_not_reported_as_missing_route() {
    let body = json!({ "value": { "error": "invalid session id", "message": "Session does not exist" } }).to_string();
    let (port, mut rx) = peer(vec![(Duration::ZERO, raw("404 Not Found", &body))]).await;
    let e = wda_apps::bound_observation(&provider(), port, Duration::from_secs(5), SID, None).await.unwrap_err();
    assert!(matches!(&e, SourceError::Bad(m) if m.starts_with(wda_apps::COMPACT_INVALID_SESSION)), "{e:?}");
    assert!(matches!(&e, SourceError::Bad(m) if !m.starts_with(wda_apps::COMPACT_UNAVAILABLE)), "{e:?}");
    assert_eq!(rx.recv().await.unwrap().0, format!("GET /session/{SID}/hermes/observation?bind=1 HTTP/1.1"));
    assert!(rx.try_recv().is_err(), "exactly one request, no retry or replay");
}

#[tokio::test]
async fn compact_404_kind_never_copies_the_runner_message() {
    let body = json!({ "value": { "error": "unknown command", "message": "Unhandled endpoint: /session/x/hermes/observation?bind=1&expected_bundle_id=private.app" } }).to_string();
    let (port, _rx) = peer(vec![(Duration::ZERO, raw("404 Not Found", &body))]).await;
    let e = wda_apps::bound_observation(&provider(), port, Duration::from_secs(5), SID, None).await.unwrap_err();
    assert!(matches!(&e, SourceError::Bad(m) if m.starts_with(wda_apps::COMPACT_UNAVAILABLE) && !m.contains("private.app") && !m.contains("Unhandled")), "{e:?}");
    let (port, _rx) = peer(vec![(Duration::ZERO, raw("404 Not Found", "not json"))]).await;
    let e = wda_apps::compact_observation(&provider(), port, Duration::from_secs(5), SID).await.unwrap_err();
    assert!(matches!(&e, SourceError::Bad(m) if m.starts_with(wda_apps::COMPACT_404_UNRECOGNIZED)), "{e:?}");
}

#[test]
fn compact_404_classification_reads_only_value_error() {
    use wda_apps::{classify_compact_404 as c, Compact404 as K};
    assert_eq!(c(Some(&json!({ "value": { "error": "unknown command" } }))), K::RouteMissing);
    assert_eq!(c(Some(&json!({ "value": { "error": "invalid session id" } }))), K::InvalidSession);
    assert_eq!(c(Some(&json!({ "value": { "message": "invalid session id" } }))), K::Other);
    assert_eq!(c(None), K::Other);
}

#[tokio::test]
async fn compact_runner_error_and_deadline_are_refused() {
    let body = json!({ "value": { "error": "unknown error", "message": "hermes_observation: snapshot_nil" } }).to_string();
    let (port, _rx) = peer(vec![
        (Duration::ZERO, raw("500 Internal Server Error", &body)),
        (Duration::from_millis(900), ok(compact_value())),
    ])
    .await;
    let p = provider();
    let e = wda_apps::compact_observation(&p, port, Duration::from_secs(5), SID).await.unwrap_err();
    assert!(matches!(&e, SourceError::Bad(m) if !m.starts_with(wda_apps::COMPACT_UNAVAILABLE)), "{e:?}");
    let e = wda_apps::compact_observation(&p, port, Duration::from_millis(250), SID).await.unwrap_err();
    assert!(matches!(e, SourceError::Deadline(_)), "{e:?}");
}

// ---- Bound compact observation (LATENCY_IMPROVEMENTS_REPORT.md): one request, identity checked in the runner and here ----

const APP: &str = "com.example.synthetic";

fn bound_value() -> serde_json::Value {
    let mut v = compact_value();
    v["schema"] = json!("hermes-observation/2");
    v["runner"]["endpoint_version"] = json!(2);
    let side = json!({ "bundle_id": APP, "pid": 42, "orientation": "PORTRAIT", "expected_state": 4 });
    v["identity"] = json!({ "expected_bundle_id": APP, "before": side, "after": side, "stable": true, "refused": null });
    v
}

fn identity_stage(v: serde_json::Value, expected: Option<&str>) -> &'static str {
    match wda_apps::check_bound(v, expected) {
        Err(wda_apps::BoundError::Identity(stage, _)) => stage,
        other => panic!("expected an identity refusal, got {other:?}"),
    }
}

#[test]
fn bound_path_adds_bind_and_a_plain_bundle_only() {
    let base = format!("/session/{SID}/hermes/observation?bind=1");
    assert_eq!(wda_apps::bound_observation_path(SID, None).unwrap(), base);
    assert_eq!(wda_apps::bound_observation_path(SID, Some(APP)).unwrap(), format!("{base}&expected_bundle_id={APP}"));
    for bad in ["", "com.example&x=1", "com example", "com/ex"] {
        assert!(wda_apps::bound_observation_path(SID, Some(bad)).is_err(), "{bad}");
    }
}

#[tokio::test]
async fn bound_observation_is_exactly_one_request_and_no_screenshot() {
    let (port, mut rx) = peer(vec![(Duration::ZERO, ok(bound_value()))]).await;
    let v = wda_apps::bound_observation(&provider(), port, Duration::from_secs(5), SID, Some(APP)).await.unwrap();
    let b = wda_apps::check_bound(v, Some(APP)).unwrap();
    assert_eq!((b.bundle_id.as_str(), b.pid, b.orientation.as_str(), b.state_before, b.state_after), (APP, 42, "PORTRAIT", 4, 4));
    assert_eq!(b.window, json!({ "width": 390, "height": 844 }));
    let (line, body) = rx.recv().await.unwrap();
    assert_eq!(line, format!("GET /session/{SID}/hermes/observation?bind=1&expected_bundle_id={APP} HTTP/1.1"));
    assert!(body.is_empty());
    assert!(rx.try_recv().is_err(), "one request: no activeAppInfo/state/window/orientation/screenshot reads");
}

#[tokio::test]
async fn bound_observation_on_an_unpatched_or_v1_runner_is_refused_without_fallback() {
    let body = json!({ "value": { "error": "unknown command", "message": "Unhandled endpoint" } }).to_string();
    let (port, mut rx) = peer(vec![(Duration::ZERO, raw("404 Not Found", &body)), (Duration::ZERO, ok(compact_value()))]).await;
    let p = provider();
    let e = wda_apps::bound_observation(&p, port, Duration::from_secs(5), SID, None).await.unwrap_err();
    assert!(matches!(&e, SourceError::Bad(m) if m.starts_with(wda_apps::COMPACT_UNAVAILABLE)), "{e:?}");
    let v1 = wda_apps::bound_observation(&p, port, Duration::from_secs(5), SID, None).await.unwrap();
    assert!(matches!(wda_apps::check_bound(v1, None), Err(wda_apps::BoundError::Bad(_))), "a v1 runner ignores bind=1");
    assert_eq!(rx.recv().await.unwrap().0, format!("GET /session/{SID}/hermes/observation?bind=1 HTTP/1.1"));
    assert_eq!(rx.recv().await.unwrap().0, format!("GET /session/{SID}/hermes/observation?bind=1 HTTP/1.1"));
}

#[test]
fn bound_identity_is_rechecked_not_trusted() {
    // runner verdicts keep their stage
    for r in ["foreground_mismatch", "target_not_foreground_before", "target_not_foreground_after",
              "foreground_changed_during_observation", "orientation_changed_during_observation"] {
        let mut v = bound_value();
        v["identity"]["refused"] = json!(r);
        v["identity"]["stable"] = json!(false);
        v["nodes"] = json!([]);
        assert_eq!(identity_stage(v, Some(APP)), r);
    }
    // marked stable, but before/after differ: refused here anyway
    let mut v = bound_value();
    v["identity"]["after"]["pid"] = json!(43);
    assert_eq!(identity_stage(v, Some(APP)), "foreground_changed_during_observation");
    let mut v = bound_value();
    v["identity"]["after"]["orientation"] = json!("LANDSCAPE");
    assert_eq!(identity_stage(v, Some(APP)), "orientation_changed_during_observation");
    let mut v = bound_value();
    v["identity"]["after"]["expected_state"] = json!(3);
    assert_eq!(identity_stage(v, Some(APP)), "target_not_foreground_after");
    let mut v = bound_value();
    v["app"]["pid"] = json!(7);
    assert_eq!(identity_stage(v, Some(APP)), "foreground_changed_during_observation");
    // the wrong app in front
    let mut v = bound_value();
    for k in ["before", "after"] { v["identity"][k]["bundle_id"] = json!("com.example.other"); }
    v["identity"]["expected_bundle_id"] = json!(null);
    assert!(wda_apps::check_bound(v.clone(), None).is_err(), "snapshot app differs from identity");
    // unbound reads report state 4 as the XML foreground path did
    let mut v = bound_value();
    v["identity"]["expected_bundle_id"] = json!(null);
    let b = wda_apps::check_bound(v, None).unwrap();
    assert_eq!((b.state_before, b.state_after), (4, 4));
}

/// The runner's early refusal (`FBDebugCommands.m` before any snapshot): `after: null`, no app/window/orientation.
fn early_refusal(reason: &str, before_state: i64) -> serde_json::Value {
    json!({
        "schema": "hermes-observation/2",
        "runner": { "endpoint": "hermes/observation", "endpoint_version": 2 },
        "identity": { "expected_bundle_id": APP, "after": null, "stable": false, "refused": reason,
                      "before": { "bundle_id": APP, "pid": 42, "orientation": "PORTRAIT", "expected_state": before_state } },
        "node_count": 0,
        "nodes": [],
    })
}

#[test]
fn bound_identity_refusals_keep_their_token_with_safe_expected_actual() {
    let detail = |v: serde_json::Value| match wda_apps::check_bound(v, Some(APP)) {
        Err(wda_apps::BoundError::Identity(stage, m)) => {
            assert!(!m.contains("example") && !m.contains("42"), "no bundle id or pid in {m}");
            format!("{stage}|{m}")
        }
        other => panic!("expected an identity refusal, got {other:?}"),
    };
    // early refusal: mapped to its stage, never "did not mark the identity stable" or a missing identity.after
    assert_eq!(detail(early_refusal("target_not_foreground_before", 3)),
        "target_not_foreground_before|identity_refused reason=target_not_foreground_before expected=running_foreground actual=running_background");
    let mut v = early_refusal("foreground_mismatch", 1);
    v["identity"]["before"]["bundle_id"] = json!("com.example.other");
    assert_eq!(detail(v), "foreground_mismatch|identity_refused reason=foreground_mismatch expected=target_app actual=other_app");
    // full answers refused after the snapshot
    let mut v = bound_value();
    v["identity"]["after"]["orientation"] = json!("LANDSCAPE");
    assert_eq!(detail(v.clone()), "orientation_changed_during_observation|identity_refused reason=orientation_changed_during_observation expected=portrait actual=landscape");
    v["identity"]["refused"] = json!("orientation_changed_during_observation");
    v["identity"]["stable"] = json!(false);
    v["nodes"] = json!([]);
    assert!(detail(v).ends_with("expected=portrait actual=landscape"));
    let mut v = bound_value();
    v["identity"]["after"]["pid"] = json!(43);
    assert!(detail(v).ends_with("expected=same_app_pid actual=pid_changed"));
    // an unknown runner token stays malformed
    let mut v = early_refusal("something_new", 4);
    v["identity"]["refused"] = json!("something_new");
    assert!(matches!(wda_apps::check_bound(v, Some(APP)), Err(wda_apps::BoundError::Bad(_))));
}

#[test]
fn bound_stable_is_true_or_the_boxed_int_one_of_older_runners() {
    // FBDebugCommands.m used `@(nil == refused)`: a C int, serialized as `1` (the ffi-7 wda_compact_bad_answer).
    let mut v = bound_value();
    v["identity"]["stable"] = json!(1);
    let b = wda_apps::check_bound(v, Some(APP)).unwrap();
    assert_eq!((b.pid, b.state_before, b.state_after), (42, 4, 4));
    for s in [json!(0), json!(2), json!("true"), json!(null)] {
        let mut v = bound_value();
        v["identity"]["stable"] = s.clone();
        assert!(matches!(wda_apps::check_bound(v, Some(APP)), Err(wda_apps::BoundError::Bad(_))), "{s}");
    }
}

#[test]
fn bound_geometry_and_envelope_must_be_fresh_and_complete() {
    let bad = |edit: &dyn Fn(&mut serde_json::Value)| {
        let mut v = bound_value();
        edit(&mut v);
        assert!(matches!(wda_apps::check_bound(v, Some(APP)), Err(wda_apps::BoundError::Bad(_))));
    };
    bad(&|v| v["orientation"] = json!("LANDSCAPE"));
    bad(&|v| v["window"] = json!(null));
    bad(&|v| v["window"]["width"] = json!(0));
    bad(&|v| v["nodes"] = json!([]));
    bad(&|v| v["identity"]["stable"] = json!(false));
    bad(&|v| v["identity"]["expected_bundle_id"] = json!("com.example.other"));
    bad(&|v| { v.as_object_mut().unwrap().remove("identity"); });
    bad(&|v| v["schema"] = json!("hermes-observation/1"));
    bad(&|v| v["runner"]["endpoint_version"] = json!(1));
}

/// A loopback port nothing listens on (bound, then released).
async fn refused_port() -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    drop(l);
    port
}

/// SESSION_RECOVERY_REPORT.md: the endpoint probe connects and writes nothing; a closed port reads as `refused`.
#[tokio::test]
async fn connect_probe_is_connect_only() {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let peer = tokio::spawn(async move {
        let (mut sock, _) = l.accept().await.unwrap();
        let mut buf = Vec::new();
        tokio::time::timeout(Duration::from_secs(5), sock.read_to_end(&mut buf)).await.unwrap().unwrap();
        buf.len()
    });
    assert_eq!(wda_apps::connect_probe(&provider(), port, Duration::from_secs(2)).await, "accepted");
    assert_eq!(peer.await.unwrap(), 0, "no request byte written");
    assert_eq!(wda_apps::connect_probe(&provider(), refused_port().await, Duration::from_secs(2)).await, "refused");
}

/// A refused runner port on activation, activeAppInfo, the compact read and a tap reads as a session loss; the tap
/// is `NotSent` (connect failed before any write), never uncertain.
#[tokio::test]
async fn refused_reads_activation_and_tap_are_session_losses() {
    let (p, port, t) = (provider(), refused_port().await, Duration::from_secs(2));
    let e = wda_apps::activate_app(&p, port, t, SID, "com.example.target").await.unwrap_err();
    assert_eq!(session::loss_reason("wda_activate_app", &wda_apps::connect_text(&e)), Some("connection_refused"), "{e}");
    let e = wda_apps::active_app(&p, port, t, SID).await.unwrap_err();
    assert_eq!(session::loss_reason("wda_active_app_info", &wda_apps::connect_text(&e)), Some("connection_refused"), "{e}");
    let e = wda_apps::compact_observation(&p, port, t, SID).await.unwrap_err();
    assert!(matches!(e, SourceError::Connect(_)), "{e}");
    assert_eq!(session::loss_reason("wda_compact_connect", &e.to_string()), Some("connection_refused"), "{e}");
    let e = wda_apps::tap(&p, port, t, SID, 10.0, 10.0).await.unwrap_err();
    assert!(matches!(e, wda_apps::TapError::NotSent(_)), "{e}");
    assert_eq!(session::loss_reason("wda_tap_not_sent", &e.to_string()), Some("connection_refused"), "{e}");
}

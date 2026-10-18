//! Pre-action target revalidation (`POST /session/{id}/hermes/target`): request allow-list and answer checks.
//! Pure functions only (no device, no runner). NOT run in the authoring session (no native builds allowed there).

use serde_json::{Value, json};
use unified_ffi::wda_apps::{BoundError, check_target, is_screen_digest, target_path, target_request_body};

const B: &str = "com.apple.Preferences";
const D: &str = "s1:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn req() -> Value {
    json!({"expected_bundle_id": B, "expected_pid": 42, "expected_orientation": "PORTRAIT", "name": "General",
           "label": null, "max_matches": 2})
}

fn side(pid: i64, ori: &str, state: i64) -> Value {
    json!({"bundle_id": B, "pid": pid, "orientation": ori, "expected_state": state})
}

fn answer() -> Value {
    json!({
        "schema": "hermes-target/1", "runner": {"endpoint": "hermes/target", "endpoint_version": 3},
        "identity": {"expected_bundle_id": B, "before": side(42, "PORTRAIT", 4), "after": side(42, "PORTRAIT", 4),
                     "stable": true, "refused": null},
        "match_count": 1, "truncated": false, "matches": [{"type": "XCUIElementTypeCell"}], "keyboards": [],
        "screen_digest": D,
    })
}

fn stage(r: Result<Value, BoundError>) -> String {
    match r {
        Err(BoundError::Identity(s, d)) => format!("identity:{s}:{d}"),
        Err(BoundError::Bad(m)) => format!("bad:{m}"),
        Ok(_) => "ok".into(),
    }
}

#[test]
fn request_is_allow_listed_and_typed() {
    assert_eq!(target_path("abc"), "/session/abc/hermes/target");
    assert!(target_request_body(&req()).is_ok());
    let mut r = req();
    r["extra"] = json!(1);
    assert!(target_request_body(&r).unwrap_err().contains("unknown target request key"));
    for (k, v) in [("expected_bundle_id", json!("a b")), ("expected_pid", json!(0)), ("expected_pid", json!("42")),
                   ("expected_orientation", json!("UNKNOWN")), ("name", json!(3)), ("max_matches", json!(0)),
                   ("max_matches", json!(33))] {
        let mut r = req();
        r[k] = v;
        assert!(target_request_body(&r).is_err(), "{k} must be refused");
    }
    let mut r = req();
    r["name"] = Value::Null;
    assert!(target_request_body(&r).unwrap_err().contains("name and/or label"));
}

#[test]
fn accepted_answer_keeps_value() {
    assert_eq!(stage(check_target(answer(), B, 42)), "ok");
}

#[test]
fn runner_refusals_map_to_fixed_tokens_without_ids() {
    for (reason, want) in [("process_changed", "target_process_changed"), ("orientation_changed", "target_orientation_changed"),
                           ("foreground_mismatch", "foreground_mismatch"),
                           ("target_not_foreground_before", "target_not_foreground_before")] {
        let mut a = answer();
        a["identity"]["refused"] = json!(reason);
        a["identity"]["stable"] = json!(false);
        let s = stage(check_target(a, B, 42));
        assert_eq!(s, format!("identity:{want}:identity_refused reason={reason}"));
        assert!(!s.contains(B) && !s.contains("42"), "no bundle ids or pids in the detail: {s}");
    }
    let mut a = answer();
    a["identity"]["refused"] = json!("something_new");
    assert!(stage(check_target(a, B, 42)).starts_with("bad:unknown identity refusal"));
}

#[test]
fn identity_is_rechecked_here() {
    let cases: [(&str, Value, &str); 4] = [
        ("after", side(43, "PORTRAIT", 4), "identity:foreground_changed_during_observation"),
        ("before", side(41, "PORTRAIT", 4), "identity:foreground_changed_during_observation"),
        ("after", side(42, "LANDSCAPE", 4), "identity:orientation_changed_during_observation"),
        ("after", side(42, "PORTRAIT", 3), "identity:target_not_foreground_after"),
    ];
    for (k, v, want) in cases {
        let mut a = answer();
        a["identity"][k] = v;
        assert!(stage(check_target(a, B, 42)).starts_with(want), "{k}");
    }
    assert!(stage(check_target(answer(), "com.other", 42)).starts_with("identity:foreground_changed_during_observation"));
    assert!(stage(check_target(answer(), B, 7)).starts_with("identity:foreground_changed_during_observation"));
}

#[test]
fn malformed_answers_are_bad() {
    let edits: [(&str, Value); 6] = [
        ("schema", json!("hermes-observation/2")),
        ("runner", json!({"endpoint_version": 2})),
        ("matches", json!(null)),
        ("keyboards", json!({})),
        ("screen_digest", json!(null)),
        ("screen_digest", json!("s1:XYZ")),
    ];
    for (k, v) in edits {
        let mut a = answer();
        a[k] = v;
        assert!(stage(check_target(a, B, 42)).starts_with("bad:"), "{k}");
    }
    let mut a = answer();
    a["identity"]["stable"] = json!(1);
    assert!(stage(check_target(a, B, 42)).starts_with("bad:runner did not mark"), "only a JSON true is stable here");
    let mut a = answer();
    a.as_object_mut().unwrap().remove("identity");
    assert!(stage(check_target(a, B, 42)).starts_with("bad:no identity"));
}

#[test]
fn truncated_answers_pass_the_envelope_and_core_refuses_them() {
    // match_count/truncated are judged by Core (ambiguous), not here; the envelope stays valid.
    let mut a = answer();
    a["match_count"] = json!(5);
    a["truncated"] = json!(true);
    assert_eq!(stage(check_target(a, B, 42)), "ok");
}

#[test]
fn screen_digest_shape() {
    assert!(is_screen_digest(D));
    assert!(!is_screen_digest(&D.to_uppercase()));
    assert!(!is_screen_digest("c1:abc"));
    assert!(!is_screen_digest(&D[..66]));
}

//! SYNTHETIC tests: no device, no real pairing record, nothing beyond
//! 127.0.0.1 (where nothing listens on 62078). They drive the real C ABI and
//! idevice transport up to the first point that would need an iPhone.

use std::ffi::{CStr, CString, c_char};
use std::ptr;
use std::sync::Mutex;

use unified_ffi::*;

static LOCKDOWN_PORT: Mutex<()> = Mutex::new(());

/// Structurally valid, entirely fake pairing plist (PEM frames around ASCII text).
fn synthetic_pairing_plist() -> Vec<u8> {
    let pem = |label: &str| {
        format!("-----BEGIN {label}-----\nU1lOVEhFVElDLU5PVC1BLVJFQUwtUEFJUklORy1SRUNPUkQ=\n-----END {label}-----\n")
    };
    let data = |s: String| plist::Value::Data(s.into_bytes());
    let mut d = plist::Dictionary::new();
    for k in ["DeviceCertificate", "HostCertificate", "RootCertificate"] {
        d.insert(k.into(), data(pem("CERTIFICATE")));
    }
    d.insert("HostPrivateKey".into(), data(pem("PRIVATE KEY")));
    d.insert("RootPrivateKey".into(), data(pem("PRIVATE KEY")));
    d.insert("SystemBUID".into(), "00000000-SYNTHETIC".into());
    d.insert("HostID".into(), "00000000-SYNTHETIC-HOST".into());
    d.insert("WiFiMACAddress".into(), "00:00:00:00:00:00".into());
    let mut out = Vec::new();
    plist::Value::Dictionary(d).to_writer_xml(&mut out).unwrap();
    out
}

fn take(p: *mut c_char) -> Option<serde_json::Value> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned();
    unsafe { uni_string_free(p) };
    Some(serde_json::from_str(&s).unwrap())
}

fn observe(target: Option<&str>, heartbeat: i32) -> (i32, serde_json::Value) {
    let pairing = synthetic_pairing_plist();
    let ip = CString::new("127.0.0.1").unwrap();
    let runner = CString::new("dev.spike.WebDriverAgentRunner.xctrunner").unwrap();
    let target = target.map(|t| CString::new(t).unwrap());
    let (mut j, mut e) = (ptr::null_mut(), ptr::null_mut());
    let code = unsafe {
        uni_observe(
            pairing.as_ptr(),
            pairing.len(),
            ip.as_ptr(),
            runner.as_ptr(),
            target.as_ref().map_or(ptr::null(), |t| t.as_ptr()),
            heartbeat,
            10,
            &mut j,
            &mut e,
        )
    };
    assert!(take(j).is_none(), "no success JSON is possible without a device");
    (code, take(e).expect("error JSON"))
}

#[test]
fn observe_requires_a_target_bundle() {
    let (code, e) = observe(None, 0);
    assert_eq!((code, e["stage"].as_str()), (ODR_ERR_ARGUMENT, Some("argument")));
    assert!(e["detail"].as_str().unwrap().contains("target_bundle_id"));
}

#[test]
fn observe_without_heartbeat_fails_first_at_installation_proxy() {
    let _g = LOCKDOWN_PORT.lock().unwrap_or_else(|e| e.into_inner());
    let (code, e) = observe(Some("com.apple.Preferences"), 0);
    assert_eq!((code, e["stage"].as_str()), (ODR_ERR_INSTALLATION_PROXY, Some("installation_proxy_connect")));
    assert!(e["detail"].as_str().unwrap().contains("kind=ConnectionRefused"), "{e}");
    assert!(e.get("heartbeat").is_none());
}

#[test]
fn observe_with_heartbeat_connects_heartbeat_first() {
    let _g = LOCKDOWN_PORT.lock().unwrap_or_else(|e| e.into_inner());
    let (code, e) = observe(Some("com.apple.Preferences"), 1);
    assert_eq!((code, e["stage"].as_str()), (ODR_ERR_HEARTBEAT, Some("heartbeat_connect")));
    assert!(e["detail"].as_str().unwrap().contains("kind=ConnectionRefused"), "{e}");
}

#[test]
fn bad_pairing_record_is_rejected_without_echoing_it() {
    let ip = CString::new("127.0.0.1").unwrap();
    let junk = b"SECRET-LOOKING-BYTES-not-a-plist";
    let (mut j, mut e) = (ptr::null_mut(), ptr::null_mut());
    let code = unsafe { uni_probe(junk.as_ptr(), junk.len(), ip.as_ptr(), 2, &mut j, &mut e) };
    let e = take(e).unwrap();
    assert!(take(j).is_none());
    assert_eq!((code, e["stage"].as_str()), (ODR_ERR_PAIRING_FILE, Some("pairing_file")));
    assert!(!e.to_string().contains("SECRET-LOOKING"));
}

#[test]
fn version_names_the_pins() {
    let v = unsafe { CStr::from_ptr(uni_version()) }.to_str().unwrap();
    assert!(v.contains("3854a5df4a5a") && v.contains("heartbeat"));
}

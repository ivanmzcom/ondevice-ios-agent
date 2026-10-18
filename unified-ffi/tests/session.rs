//! SYNTHETIC session tests: no device, nothing beyond 127.0.0.1 (where nothing
//! listens on 62078). Argument handling and the first failing stage only.

use std::ffi::{CStr, CString, c_char};
use std::ptr;

use unified_ffi::session::*;
use unified_ffi::*;

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

#[test]
fn open_rejects_missing_arguments_and_leaves_no_session() {
    let pairing = synthetic_pairing_plist();
    let ip = CString::new("127.0.0.1").unwrap();
    let (mut s, mut j, mut e) = (ptr::NonNull::<UniSession>::dangling().as_ptr(), ptr::null_mut(), ptr::null_mut());
    let code = unsafe {
        uni_session_open(pairing.as_ptr(), pairing.len(), ip.as_ptr(), ptr::null(), 1, 10, &mut s, &mut j, &mut e)
    };
    assert_eq!(code, ODR_ERR_ARGUMENT);
    assert!(s.is_null(), "out_session must be cleared on failure");
    assert!(take(j).is_none());
    assert_eq!(take(e).unwrap()["stage"], "argument");
    let code = unsafe {
        uni_session_open(pairing.as_ptr(), pairing.len(), ip.as_ptr(), ip.as_ptr(), 0, 10, ptr::null_mut(), &mut j, &mut e)
    };
    assert_eq!(code, ODR_ERR_ARGUMENT);
    assert_eq!(take(e).unwrap()["detail"], "out_session is required");
}

#[test]
fn open_fails_at_installation_proxy_without_a_device() {
    let pairing = synthetic_pairing_plist();
    let ip = CString::new("127.0.0.1").unwrap();
    let runner = CString::new("dev.synthetic.runner.xctrunner").unwrap();
    let (mut s, mut j, mut e) = (ptr::null_mut(), ptr::null_mut(), ptr::null_mut());
    let code = unsafe {
        uni_session_open(pairing.as_ptr(), pairing.len(), ip.as_ptr(), runner.as_ptr(), 0, 10, &mut s, &mut j, &mut e)
    };
    assert_ne!(code, ODR_OK);
    assert!(s.is_null());
    let err = take(e).unwrap();
    assert!(
        ["installation_proxy_connect", "timeout"].contains(&err["stage"].as_str().unwrap()),
        "unexpected stage {err}"
    );
}

#[test]
fn calls_on_a_null_session_are_argument_errors_and_close_is_a_noop() {
    let target = CString::new("com.apple.Preferences").unwrap();
    let (mut j, mut e) = (ptr::null_mut(), ptr::null_mut());
    assert_eq!(unsafe { uni_session_observe(ptr::null_mut(), target.as_ptr(), 5, &mut j, &mut e) }, ODR_ERR_ARGUMENT);
    assert_eq!(take(e).unwrap()["detail"], "session is required");
    assert_eq!(unsafe { uni_session_screenshot(ptr::null_mut(), 5, &mut j, &mut e) }, ODR_ERR_ARGUMENT);
    assert!(take(e).is_some());
    unsafe { uni_session_close(ptr::null_mut()) };
}

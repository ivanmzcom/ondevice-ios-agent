//! Heartbeat-lifetime experiment (see ../../COLD_BOOT_REPORT.md).
//!
//! Upstream `services/heartbeat.rs` documents that iOS closes service
//! connections when no heartbeat client is connected and responding. This
//! module holds one `com.apple.mobile.heartbeat` connection open, answering
//! every Marco with a Polo exactly like upstream `tools/src/heartbeat_client.rs`
//! (first wait 15 s, then `interval + 5`), for the whole lifetime of an
//! operation, and tears it down on every exit path (Ok, Err, deadline, drop).
//! Whether this is what cold-boot launches need is NOT established; it is
//! the variable under test.

use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use idevice::{HeartbeatError, IdeviceError, services::heartbeat::HeartbeatClient};
use tokio::task::JoinHandle;

use crate::{ODR_ERR_HEARTBEAT, ODR_ERR_TIMEOUT, StageError, describe};

/// Upstream's first wait before any interval is known.
pub(crate) const FIRST_MARCO_WAIT_SECS: u64 = 15;
/// Upstream's slack added to the device-announced interval.
const MARCO_SLACK_SECS: u64 = 5;

#[derive(Debug, Default)]
struct Stats {
    marcos: u32,
    polos: u32,
    /// Waits that ended without a Marco. Not fatal: the connection stays open.
    silent_waits: u32,
    last_interval: Option<u64>,
    /// Why the pump stopped on its own (bounded labels, never peer text).
    exit: Option<String>,
}

/// A running heartbeat pump. Dropping it aborts the task, which drops the
/// `HeartbeatClient` and closes its socket.
pub(crate) struct Heartbeat {
    stats: Arc<Mutex<Stats>>,
    task: JoinHandle<()>,
}

impl Heartbeat {
    pub(crate) fn spawn(client: HeartbeatClient, first_wait_secs: u64) -> Self {
        let stats = Arc::new(Mutex::new(Stats::default()));
        let task = tokio::spawn(pump(client, stats.clone(), first_wait_secs.max(1)));
        Self { stats, task }
    }

    pub(crate) fn snapshot(&self) -> serde_json::Value {
        let s = self.stats.lock().unwrap_or_else(|e| e.into_inner());
        serde_json::json!({
            "running": !self.task.is_finished(),
            "marcos": s.marcos,
            "polos": s.polos,
            "silent_waits": s.silent_waits,
            "last_interval": s.last_interval,
            "exit": s.exit,
        })
    }
}

impl Drop for Heartbeat {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn pump(mut client: HeartbeatClient, stats: Arc<Mutex<Stats>>, mut wait: u64) {
    let set = |f: &dyn Fn(&mut Stats)| f(&mut stats.lock().unwrap_or_else(|e| e.into_inner()));
    let exit = loop {
        // Note: upstream `get_marco` races `read_plist` against a sleep; a
        // timeout that fires mid-frame would desync the stream. The +5 s slack
        // makes that unlikely; a desync would surface as `exit` below.
        match client.get_marco(wait).await {
            Ok(interval) => {
                set(&|s| {
                    s.marcos += 1;
                    s.last_interval = Some(interval);
                });
                wait = interval.saturating_add(MARCO_SLACK_SECS);
            }
            Err(IdeviceError::Heartbeat(HeartbeatError::Timeout)) => {
                set(&|s| s.silent_waits += 1);
                continue;
            }
            Err(e) => break label(&e),
        }
        if let Err(e) = client.send_polo().await {
            break label(&e);
        }
        set(&|s| s.polos += 1);
    };
    set(&|s| s.exit = Some(exit.clone()));
}

/// Bounded exit labels: `UnexpectedResponse` can embed a device-sent command
/// string, so only socket errors keep detail (and only their `io::ErrorKind`).
fn label(e: &IdeviceError) -> String {
    match e {
        IdeviceError::Heartbeat(HeartbeatError::SleepyTime) => "sleepy_time".into(),
        IdeviceError::Socket(_) => describe(e),
        IdeviceError::UnexpectedResponse(_) => "unexpected_response".into(),
        _ => "other_error".into(),
    }
}

/// Connects the heartbeat first; only once that succeeded runs `op`, with the
/// pump alive. The heartbeat snapshot (taken before teardown) is attached to
/// the result or the error. `deadline` bounds connect + op so a hang still
/// reports heartbeat state instead of a bare outer timeout.
pub(crate) async fn with_heartbeat<C, F, Fut>(
    connect: C,
    first_wait_secs: u64,
    deadline: Duration,
    op: F,
) -> Result<serde_json::Value, StageError>
where
    C: Future<Output = Result<HeartbeatClient, IdeviceError>>,
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<serde_json::Value, StageError>>,
{
    let until = tokio::time::Instant::now() + deadline;
    let client = match tokio::time::timeout_at(until, connect).await {
        Ok(Ok(c)) => c,
        Ok(Err(e)) => return Err(StageError::new(ODR_ERR_HEARTBEAT, "heartbeat_connect", describe(&e))),
        Err(_) => return Err(StageError::new(ODR_ERR_TIMEOUT, "heartbeat_connect", "deadline")),
    };
    let hb = Heartbeat::spawn(client, first_wait_secs);
    let r = tokio::time::timeout_at(until, op())
        .await
        .unwrap_or_else(|_| Err(StageError::new(ODR_ERR_TIMEOUT, "timeout", "overall deadline")));
    let snap = hb.snapshot();
    drop(hb);
    match r {
        Ok(mut v) => {
            if let Some(o) = v.as_object_mut() {
                o.insert("heartbeat".into(), snap);
            }
            Ok(v)
        }
        Err(mut e) => {
            e.heartbeat = Some(snap);
            Err(e)
        }
    }
}

// ---------------------------------------------------------------------------
// Synthetic lifecycle tests: real upstream HeartbeatClient over an in-memory
// duplex stream; the "device" side is a scripted peer speaking the same
// 4-byte-BE-length + plist framing. No device outcome is simulated here.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use crate::ODR_ERR_INSTALLATION_PROXY;
    use idevice::Idevice;
    use std::io;
    use std::sync::atomic::{AtomicBool, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream, duplex};

    fn pair() -> (HeartbeatClient, DuplexStream) {
        let (ours, peer) = duplex(64 * 1024);
        (HeartbeatClient::new(Idevice::new(Box::new(ours), "synthetic")), peer)
    }

    async fn send(peer: &mut DuplexStream, v: plist::Value) {
        let mut body = Vec::new();
        v.to_writer_xml(&mut body).unwrap();
        peer.write_all(&(body.len() as u32).to_be_bytes()).await.unwrap();
        peer.write_all(&body).await.unwrap();
    }

    async fn marco(peer: &mut DuplexStream, interval: u64) {
        let mut d = plist::Dictionary::new();
        d.insert("Command".into(), "Marco".into());
        d.insert("Interval".into(), plist::Value::Integer(interval.into()));
        send(peer, d.into()).await;
    }

    async fn command(peer: &mut DuplexStream, cmd: &str) {
        let mut d = plist::Dictionary::new();
        d.insert("Command".into(), cmd.into());
        send(peer, d.into()).await;
    }

    async fn read_polo(peer: &mut DuplexStream) {
        let mut len = [0u8; 4];
        peer.read_exact(&mut len).await.unwrap();
        let mut body = vec![0; u32::from_be_bytes(len) as usize];
        peer.read_exact(&mut body).await.unwrap();
        let d: plist::Dictionary = plist::from_bytes(&body).unwrap();
        assert_eq!(d.get("Command").and_then(|c| c.as_string()), Some("Polo"));
    }

    /// The client side was dropped: the peer reads EOF (not a hang).
    async fn assert_closed(peer: &mut DuplexStream) {
        let mut b = [0u8; 1];
        let n = tokio::time::timeout(Duration::from_secs(2), peer.read(&mut b))
            .await
            .expect("heartbeat socket still open after teardown")
            .unwrap();
        assert_eq!(n, 0);
    }

    fn ok_op() -> serde_json::Value {
        serde_json::json!({ "stage": "source" })
    }

    // current_thread: the pump writes Polo and bumps `polos` in one poll, so
    // once the peer has read a Polo the counter already reflects it.

    #[tokio::test(flavor = "current_thread")]
    async fn answers_every_marco_while_op_runs_then_closes() {
        let (client, mut peer) = pair();
        let (tx, rx) = tokio::sync::oneshot::channel();
        let r = with_heartbeat(async { Ok(client) }, 15, Duration::from_secs(5), || async move {
            for _ in 0..3 {
                marco(&mut peer, 1).await;
                read_polo(&mut peer).await;
            }
            tx.send(peer).unwrap();
            Ok(ok_op())
        })
        .await
        .unwrap();
        let hb = &r["heartbeat"];
        assert_eq!((hb["marcos"].as_u64(), hb["polos"].as_u64()), (Some(3), Some(3)));
        assert_eq!(hb["running"], true, "pump must still be alive when op ends");
        assert_eq!(hb["last_interval"], 1);
        assert!(hb["exit"].is_null());
        assert_closed(&mut rx.await.unwrap()).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn connect_failure_never_runs_op() {
        let ran = AtomicBool::new(false);
        let e = with_heartbeat(
            async { Err(IdeviceError::Socket(io::ErrorKind::UnexpectedEof.into())) },
            15,
            Duration::from_secs(5),
            || async {
                ran.store(true, Ordering::SeqCst);
                Ok(ok_op())
            },
        )
        .await
        .unwrap_err();
        assert!(!ran.load(Ordering::SeqCst), "installation_proxy must not start without heartbeat");
        assert_eq!((e.code, e.stage), (ODR_ERR_HEARTBEAT, "heartbeat_connect"));
        assert_eq!(e.detail, "device socket io failed (kind=UnexpectedEof)");
        assert!(e.heartbeat.is_none());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn op_error_reports_heartbeat_state_and_closes() {
        let (client, mut peer) = pair();
        let (tx, rx) = tokio::sync::oneshot::channel();
        let e = with_heartbeat(async { Ok(client) }, 15, Duration::from_secs(5), || async move {
            marco(&mut peer, 10).await;
            read_polo(&mut peer).await;
            tx.send(peer).unwrap();
            Err(StageError::new(
                ODR_ERR_INSTALLATION_PROXY,
                "resolve_runner",
                describe(&IdeviceError::Socket(io::ErrorKind::UnexpectedEof.into())),
            ))
        })
        .await
        .unwrap_err();
        assert_eq!((e.code, e.stage), (ODR_ERR_INSTALLATION_PROXY, "resolve_runner"));
        let hb = e.heartbeat.as_ref().unwrap();
        assert_eq!((hb["marcos"].as_u64(), hb["polos"].as_u64()), (Some(1), Some(1)));
        assert_eq!(hb["running"], true);
        assert_closed(&mut rx.await.unwrap()).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn deadline_reports_heartbeat_state_and_closes() {
        let (client, mut peer) = pair();
        let (tx, rx) = tokio::sync::oneshot::channel();
        let e = with_heartbeat(async { Ok(client) }, 15, Duration::from_millis(300), || async move {
            marco(&mut peer, 10).await;
            read_polo(&mut peer).await;
            tx.send(peer).unwrap();
            std::future::pending().await
        })
        .await
        .unwrap_err();
        assert_eq!((e.code, e.stage), (ODR_ERR_TIMEOUT, "timeout"));
        assert_eq!(e.heartbeat.as_ref().unwrap()["polos"], 1);
        assert_closed(&mut rx.await.unwrap()).await;
    }

    /// Dropping the whole future (outer deadline / runtime teardown) also
    /// closes the heartbeat socket.
    #[tokio::test(flavor = "current_thread")]
    async fn dropping_the_operation_closes_heartbeat() {
        let (client, mut peer) = pair();
        let fut = with_heartbeat(async { Ok(client) }, 15, Duration::from_secs(60), || {
            std::future::pending::<Result<serde_json::Value, StageError>>()
        });
        let _ = tokio::time::timeout(Duration::from_millis(50), fut).await;
        assert_closed(&mut peer).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn silence_is_not_fatal() {
        let (client, mut peer) = pair();
        let hb = Heartbeat::spawn(client, 1);
        tokio::time::sleep(Duration::from_millis(1300)).await;
        marco(&mut peer, 1).await;
        read_polo(&mut peer).await;
        let s = hb.snapshot();
        assert!(s["silent_waits"].as_u64().unwrap() >= 1, "{s}");
        assert_eq!((s["polos"].as_u64(), s["running"].as_bool()), (Some(1), Some(true)));
    }

    async fn exit_after(script: impl AsyncFnOnce(&mut DuplexStream)) -> serde_json::Value {
        let (client, mut peer) = pair();
        let hb = Heartbeat::spawn(client, 15);
        script(&mut peer).await;
        for _ in 0..100 {
            if hb.task.is_finished() {
                break;
            }
            tokio::task::yield_now().await;
        }
        hb.snapshot()
    }

    #[tokio::test(flavor = "current_thread")]
    async fn pump_exit_reasons_are_recorded_and_bounded() {
        let s = exit_after(async |p| command(p, "SleepyTime").await).await;
        assert_eq!((s["running"].as_bool(), s["exit"].as_str()), (Some(false), Some("sleepy_time")));

        let s = exit_after(async |p| command(p, "PEER-SECRET-TEXT").await).await;
        assert_eq!(s["exit"], "unexpected_response");
        assert!(!s.to_string().contains("PEER-SECRET-TEXT"));

        // tokio's read_exact reports EOF as a wrapped "early eof" error, the
        // same shape a device-side close produces on the real TCP stream.
        let s = exit_after(async |p| p.shutdown().await.unwrap()).await;
        assert_eq!(s["exit"], "device socket io failed (kind=UnexpectedEof wrapped)");
    }
}

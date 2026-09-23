//! Scanner-only diagnostics. Never log raw device log payloads or pairing keys.
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::time::Instant;

pub async fn stage<T>(
    name: &str,
    limit: Duration,
    stopped: &AtomicBool,
    future: impl Future<Output = Result<T, String>>,
) -> Result<T, String> {
    let started = Instant::now();
    tracing::info!("[ScanDiag] stage={name} event=begin timeout_s={}", limit.as_secs());
    let operation = tokio::time::timeout(limit, future);
    tokio::pin!(operation);
    let result = loop {
        if stopped.load(Ordering::SeqCst) {
            break Err(format!("Scanner cancelled during {name}"));
        }
        tokio::select! {
            result = &mut operation => break match result {
                Ok(value) => value,
                Err(_) => Err(format!("Scanner {name} timed out after {}s", limit.as_secs())),
            },
            _ = tokio::time::sleep(Duration::from_millis(100)) => {},
        }
    };
    match &result {
        Ok(_) => tracing::info!("[ScanDiag] stage={name} event=ok elapsed_ms={}", started.elapsed().as_millis()),
        Err(error) => tracing::warn!("[ScanDiag] stage={name} event=failed elapsed_ms={} error={error}", started.elapsed().as_millis()),
    }
    result
}

pub async fn read_lines(
    stream: &mut (impl AsyncRead + Unpin + ?Sized),
    stopped: &AtomicBool,
    idle_limit: Duration,
    mut deliver: impl FnMut(&str),
) -> Result<(), String> {
    let started = Instant::now();
    let mut last_bytes = started;
    let mut last_report = started;
    let mut bytes = 0u64;
    let mut lines = 0u64;
    let mut dropped = 0u64;
    let mut polls = 0u64;
    let mut buffer = [0u8; 4096];
    let mut pending = Vec::new();
    tracing::info!("[ScanDiag] stage=read event=begin idle_timeout_s={}", idle_limit.as_secs());
    let result = loop {
        if stopped.load(Ordering::SeqCst) { break Ok(()); }
        match tokio::time::timeout(Duration::from_millis(500), stream.read(&mut buffer)).await {
            Ok(Ok(0)) => break Err(format!("Scanner log stream closed (EOF): bytes={bytes} lines={lines}")),
            Ok(Err(error)) => break Err(format!("Scanner log stream read failed: {error}; bytes={bytes} lines={lines}")),
            Err(_) => { polls += 1; }
            Ok(Ok(n)) => {
                if bytes == 0 {
                    tracing::info!("[ScanDiag] stage=read event=first_bytes count={n} elapsed_ms={}", started.elapsed().as_millis());
                }
                bytes += n as u64;
                last_bytes = Instant::now();
                for &byte in &buffer[..n] {
                    if stopped.load(Ordering::SeqCst) { break; }
                    if byte == b'\n' || byte == 0 {
                        if !pending.is_empty() {
                            lines += 1;
                            if lines == 1 {
                                tracing::info!("[ScanDiag] stage=read event=first_line elapsed_ms={}", started.elapsed().as_millis());
                            }
                            deliver(&String::from_utf8_lossy(&pending));
                            pending.clear();
                        }
                    } else if byte != b'\r' {
                        pending.push(byte);
                        if pending.len() > 65536 {
                            dropped += 1;
                            pending.clear();
                        }
                    }
                }
            }
        }
        if last_report.elapsed() >= Duration::from_secs(5) {
            tracing::info!("[ScanDiag] stage=read event=stats bytes={bytes} lines={lines} pending={} dropped={dropped} read_timeouts={polls} idle_ms={}", pending.len(), last_bytes.elapsed().as_millis());
            last_report = Instant::now();
        }
        if last_bytes.elapsed() >= idle_limit {
            break Err(format!("Scanner log stream received no bytes for {}s: bytes={bytes} lines={lines}", idle_limit.as_secs()));
        }
    };
    tracing::info!("[ScanDiag] stage=read event=end bytes={bytes} lines={lines} pending={} dropped={dropped} read_timeouts={polls} elapsed_ms={} stopped={}", pending.len(), started.elapsed().as_millis(), stopped.load(Ordering::SeqCst));
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::pin::Pin;
    use std::task::{Context, Poll};
    use tokio::io::ReadBuf;

    #[tokio::test(start_paused = true)]
    async fn stage_reports_timeout_and_cancellation() {
        let stop = AtomicBool::new(false);
        let error = stage("checkin", Duration::from_secs(15), &stop,
            std::future::pending::<Result<(), String>>()).await.unwrap_err();
        assert!(error.contains("checkin timed out"));
        stop.store(true, Ordering::SeqCst);
        let error = stage("socket", Duration::from_secs(15), &stop,
            std::future::pending::<Result<(), String>>()).await.unwrap_err();
        assert!(error.contains("cancelled during socket"));
    }

    #[tokio::test(start_paused = true)]
    async fn silent_stream_reports_no_bytes() {
        let (mut stream, _keep_open) = tokio::io::duplex(64);
        let error = read_lines(&mut stream, &AtomicBool::new(false), Duration::from_secs(30), |_| {}).await.unwrap_err();
        assert!(error.contains("no bytes for 30s"));
        assert!(error.contains("bytes=0 lines=0"));
    }

    #[tokio::test]
    async fn fragmented_lines_reach_callback_and_eof_is_an_error() {
        let long_line = "a".repeat(5000);
        let mut stream = std::io::Cursor::new(format!("{long_line}\r\n\0second\0tail").into_bytes());
        let mut output = Vec::new();
        let error = read_lines(&mut stream, &AtomicBool::new(false), Duration::from_secs(30),
            |line| output.push(line.to_owned())).await.unwrap_err();
        assert_eq!(output, vec![long_line, "second".to_owned()]);
        assert!(error.contains("EOF"));
        assert!(error.contains("lines=2"));
    }

    #[tokio::test]
    async fn cancellation_stops_delivery() {
        let stop = AtomicBool::new(false);
        let mut stream = std::io::Cursor::new(b"first\nsecond\n");
        let mut output = Vec::new();
        read_lines(&mut stream, &stop, Duration::from_secs(30), |line| {
            output.push(line.to_owned());
            stop.store(true, Ordering::SeqCst);
        }).await.unwrap();
        assert_eq!(output, vec!["first"]);
    }

    struct BrokenReader;
    impl AsyncRead for BrokenReader {
        fn poll_read(self: Pin<&mut Self>, _: &mut Context<'_>, _: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Err(std::io::Error::new(std::io::ErrorKind::ConnectionReset, "test reset")))
        }
    }

    #[tokio::test]
    async fn read_failure_keeps_the_real_error() {
        let error = read_lines(&mut BrokenReader, &AtomicBool::new(false), Duration::from_secs(30), |_| {}).await.unwrap_err();
        assert!(error.contains("test reset"));
    }
}

use std::{
    future::Future,
    io,
    pin::Pin,
    task::{Context, Poll, ready},
    time::Duration,
};

use base64::{Engine, engine::general_purpose::STANDARD};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    time::{Sleep, sleep},
};

const HEADER_LIMIT: usize = 8192;
const FIRST_WRITE_LIMIT: usize = 65536;

/// simple-obfs v0.0.5 HTTP transport. Place this below the SS encrypted stream.
/// Only the first write/read has an HTTP envelope; subsequent bytes are raw.
pub struct HttpObfsStream<S> {
    inner: S,
    host: String,
    port: u16,
    started: bool,
    pending: Vec<u8>,
    written: usize,
    response: Vec<u8>,
    tail: usize,
    upgraded: bool,
    deadline: Option<Pin<Box<Sleep>>>,
    failed: bool,
}

impl<S> HttpObfsStream<S> {
    pub fn new(inner: S, host: &str, port: u16) -> io::Result<Self> {
        validate_host(host)?;
        if port == 0 {
            return Err(invalid("invalid obfs server port"));
        }
        Ok(Self {
            inner,
            host: host.into(),
            port,
            started: false,
            pending: Vec::new(),
            written: 0,
            response: Vec::new(),
            tail: 0,
            upgraded: false,
            deadline: None,
            failed: false,
        })
    }
}

pub fn validate_host(host: &str) -> io::Result<()> {
    if host.is_empty() || host.len() > 255 || host.bytes().any(|b| matches!(b, 0 | b'\r' | b'\n')) {
        return Err(invalid(
            "obfs host must be 1..255 bytes without NUL, CR or LF",
        ));
    }
    Ok(())
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

impl<S: AsyncWrite + Unpin> HttpObfsStream<S> {
    fn drain(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if self.failed {
            return Poll::Ready(Err(invalid("obfs transport is closed after an error")));
        }
        while self.written < self.pending.len() {
            let result =
                ready!(Pin::new(&mut self.inner).poll_write(cx, &self.pending[self.written..]));
            match result {
                Ok(0) => {
                    self.failed = true;
                    return Poll::Ready(Err(io::ErrorKind::WriteZero.into()));
                }
                Ok(n) => self.written += n,
                Err(error) => {
                    self.failed = true;
                    return Poll::Ready(Err(error));
                }
            }
        }
        if !self.pending.is_empty() {
            self.pending.clear();
            self.written = 0;
            if !self.upgraded {
                self.deadline = Some(Box::pin(sleep(Duration::from_secs(10))));
            }
        }
        Poll::Ready(Ok(()))
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for HttpObfsStream<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        ready!(this.drain(cx))?;
        if data.is_empty() {
            return Poll::Ready(Ok(0));
        }
        if this.started {
            return Pin::new(&mut this.inner).poll_write(cx, data);
        }
        let count = data.len().min(FIRST_WRITE_LIMIT);
        let mut random = [0; 18];
        getrandom::fill(&mut random).map_err(io::Error::other)?;
        let host = if this.port == 80 {
            this.host.clone()
        } else {
            format!("{}:{}", this.host, this.port)
        };
        this.pending = format!(
            "GET / HTTP/1.1\r\nHost: {host}\r\nUser-Agent: curl/7.{}.{}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {}\r\nContent-Length: {count}\r\n\r\n",
            random[0] % 51, random[1] % 2, STANDARD.encode(&random[2..])
        ).into_bytes();
        this.pending.extend_from_slice(&data[..count]);
        // Acknowledged bytes are owned until flush, including across cancellation.
        this.started = true;
        Poll::Ready(Ok(count))
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        ready!(this.drain(cx))?;
        Pin::new(&mut this.inner).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        ready!(this.drain(cx))?;
        Pin::new(&mut this.inner).poll_shutdown(cx)
    }
}

impl<S: AsyncRead + AsyncWrite + Unpin> AsyncRead for HttpObfsStream<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        output: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if output.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        ready!(this.drain(cx))?;
        loop {
            if this.upgraded {
                if this.tail < this.response.len() {
                    let n = output.remaining().min(this.response.len() - this.tail);
                    output.put_slice(&this.response[this.tail..this.tail + n]);
                    this.tail += n;
                    if this.tail == this.response.len() {
                        this.response.clear();
                        this.tail = 0;
                    }
                    return Poll::Ready(Ok(()));
                }
                return Pin::new(&mut this.inner).poll_read(cx, output);
            }
            if let Some(timer) = &mut this.deadline
                && timer.as_mut().poll(cx).is_ready()
            {
                this.failed = true;
                return Poll::Ready(Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "obfs response timed out after 10 seconds",
                )));
            }
            let mut storage = [0; HEADER_LIMIT];
            let mut input = ReadBuf::new(&mut storage[..HEADER_LIMIT - this.response.len()]);
            match ready!(Pin::new(&mut this.inner).poll_read(cx, &mut input)) {
                Ok(()) if !input.filled().is_empty() => {
                    this.response.extend_from_slice(input.filled())
                }
                Ok(()) => {
                    this.failed = true;
                    return Poll::Ready(Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "truncated obfs response",
                    )));
                }
                Err(error) => {
                    this.failed = true;
                    return Poll::Ready(Err(error));
                }
            }
            if let Some(end) = this
                .response
                .windows(4)
                .position(|part| part == b"\r\n\r\n")
            {
                let line_end = this
                    .response
                    .windows(2)
                    .position(|part| part == b"\r\n")
                    .expect("header terminator");
                let status = &this.response[..line_end];
                // Match the Zig boundary: HTTP/1.1 101 and an optional reason phrase.
                if !status.starts_with(b"HTTP/1.1 101")
                    || (status.len() > 12 && !matches!(status[12], b' ' | b'\t'))
                {
                    this.failed = true;
                    return Poll::Ready(Err(invalid("invalid obfs HTTP upgrade status")));
                }
                this.upgraded = true;
                this.deadline = None;
                this.tail = end + 4;
            } else if this.response.len() == HEADER_LIMIT {
                this.failed = true;
                return Poll::Ready(Err(invalid("obfs response header exceeds 8192 bytes")));
            }
        }
    }
}

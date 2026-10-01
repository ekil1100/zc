//! Single-stream AnyTLS sessions. Owns TLS directly: no pool, worker or detached task.
use std::{
    collections::{HashMap, VecDeque},
    future::Future,
    io,
    pin::Pin,
    sync::{Arc, Mutex, RwLock},
    task::{Context, Poll, Wake, Waker, ready},
    time::Duration,
};

use md5::{Digest as _, Md5};
use sha2::{Digest as _, Sha256};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf};

use crate::{
    outbound::{BoxStream, destination, truncated_read},
    target::Target,
};

const DEFAULT: &str = "stop=8\n0=30-30\n1=100-400\n2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000\n3=9-9,500-1000\n4=500-1000\n5=500-1000\n6=500-1000\n7=500-1000";
const MAX_TEXT: usize = 4096;
const MAX_FRAME: usize = u16::MAX as usize;
const MAX_STOP: usize = 32;
const MAX_PADDING: usize = 65536;
const MAX_HEARTS: usize = 32;
// One deadline covers accepted writes, FIN, TLS write shutdown and peer drain.
const CLOSE_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_CLOSE_DRAIN: usize = 1024 * 1024;

pub(crate) type SharedPadding = Arc<RwLock<Arc<Padding>>>;
pub(crate) fn default_padding() -> SharedPadding {
    Arc::new(RwLock::new(Arc::new(
        Padding::parse(DEFAULT.as_bytes()).expect("valid default padding"),
    )))
}

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid AnyTLS session")
}
fn closed() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "AnyTLS stream is closed")
}

#[derive(Clone)]
enum Step {
    Size(u16, u16),
    Check,
}
pub(crate) struct Padding {
    md5: String,
    stop: usize,
    groups: HashMap<usize, Vec<Step>>,
}

fn fields(raw: &[u8]) -> io::Result<HashMap<&str, &str>> {
    if raw.is_empty() || raw.len() > MAX_TEXT {
        return Err(invalid());
    }
    let text = std::str::from_utf8(raw).map_err(|_| invalid())?;
    let mut fields = HashMap::new();
    for line in text.split_terminator('\n') {
        let (key, value) = line.split_once('=').ok_or_else(invalid)?;
        if key.is_empty()
            || value.is_empty()
            || line.chars().any(char::is_control)
            || fields.len() == 33
            || fields.insert(key, value).is_some()
        {
            return Err(invalid());
        }
    }
    Ok(fields)
}
fn number(text: &str) -> io::Result<usize> {
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return Err(invalid());
    }
    text.parse().map_err(|_| invalid())
}
impl Padding {
    fn parse(raw: &[u8]) -> io::Result<Self> {
        let mut fields = fields(raw)?;
        let stop = number(fields.remove("stop").ok_or_else(invalid)?)?;
        if !(1..=MAX_STOP).contains(&stop) {
            return Err(invalid());
        }
        let mut groups = HashMap::new();
        let mut overhead = 0usize;
        for (key, value) in fields {
            let group = number(key)?;
            if group >= stop || key != group.to_string() {
                return Err(invalid());
            }
            let mut steps = Vec::new();
            for step in value.split(',') {
                if steps.len() == 16 {
                    return Err(invalid());
                }
                if step == "c" && group != 0 {
                    steps.push(Step::Check);
                    continue;
                }
                let (min, max) = step.split_once('-').ok_or_else(invalid)?;
                let (min, max) = (number(min)?, number(max)?);
                // Keep authentication within one TLS record and the reference packet buffer.
                let limit = if group == 0 { 4096 - 34 } else { 16384 };
                if min == 0 || min > max || max > limit {
                    return Err(invalid());
                }
                overhead += max + 7;
                if overhead > MAX_PADDING {
                    return Err(invalid());
                }
                steps.push(Step::Size(min as u16, max as u16));
            }
            if group == 0 && steps.len() != 1 {
                return Err(invalid());
            }
            groups.insert(group, steps);
        }
        Ok(Self {
            md5: Md5::digest(raw)
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect(),
            stop,
            groups,
        })
    }
    fn auth_size(&self) -> io::Result<usize> {
        match self.groups.get(&0).and_then(|s| s.first()) {
            Some(Step::Size(min, max)) => random_size(*min, *max),
            _ => Ok(0),
        }
    }
    fn packets(&self, group: usize, data: Vec<u8>) -> io::Result<VecDeque<Vec<u8>>> {
        let mut packets = VecDeque::new();
        let mut rest = data.as_slice();
        if group < self.stop {
            for step in self.groups.get(&group).into_iter().flatten() {
                let size = match step {
                    Step::Check if rest.is_empty() => break,
                    Step::Check => continue,
                    Step::Size(min, max) => random_size(*min, *max)?,
                };
                if rest.len() > size {
                    packets.push_back(rest[..size].to_vec());
                    rest = &rest[size..];
                } else if !rest.is_empty() {
                    let mut packet = rest.to_vec();
                    if size > rest.len() + 7 {
                        append_frame(&mut packet, 0, 0, &vec![0; size - rest.len() - 7]);
                    }
                    packets.push_back(packet);
                    rest = &[];
                } else {
                    // The fixed Go reference uses size as BODY length in this branch.
                    let mut packet = Vec::with_capacity(size + 7);
                    append_frame(&mut packet, 0, 0, &vec![0; size]);
                    packets.push_back(packet);
                }
            }
        }
        if !rest.is_empty() {
            packets.push_back(rest.to_vec());
        }
        Ok(packets)
    }
}
fn random_size(min: u16, max: u16) -> io::Result<usize> {
    if min == max {
        return Ok(min as usize);
    }
    let span = u32::from(max - min);
    let bound = u32::MAX - u32::MAX % span;
    loop {
        let mut bytes = [0; 4];
        getrandom::fill(&mut bytes)
            .map_err(|_| io::Error::other("AnyTLS random source unavailable"))?;
        let n = u32::from_ne_bytes(bytes);
        if n < bound {
            return Ok(min as usize + (n % span) as usize);
        }
    }
}
fn append_frame(out: &mut Vec<u8>, cmd: u8, id: u32, body: &[u8]) {
    debug_assert!(body.len() <= MAX_FRAME);
    out.push(cmd);
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&(body.len() as u16).to_be_bytes());
    out.extend_from_slice(body);
}

// Both halves can drive TLS writes (a read may answer a heartbeat). Register a
// shared transport waker so neither half overwrites the other's pending wakeup.
#[derive(Default)]
struct Wakes(Mutex<[Option<Waker>; 2]>);
impl Wake for Wakes {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }
    fn wake_by_ref(self: &Arc<Self>) {
        let wakes = self.0.lock().unwrap().clone();
        for w in wakes.into_iter().flatten() {
            w.wake();
        }
    }
}

pub(crate) struct AnyTls {
    inner: Option<BoxStream>,
    padding: Arc<Padding>,
    shared: SharedPadding,
    group: usize,
    outgoing: VecDeque<Vec<u8>>,
    written: usize,
    hearts: VecDeque<u32>,
    reply_pending: bool,
    header: [u8; 7],
    header_read: usize,
    body: Vec<u8>,
    body_read: usize,
    delivered: usize,
    data_ready: bool,
    v2: bool,
    acknowledged: bool,
    fin_queued: bool,
    write_closed: bool,
    peer_closed: bool,
    close_deadline: Option<Pin<Box<tokio::time::Sleep>>>,
    close_drained: usize,
    failure: Option<io::ErrorKind>,
    wakes: Arc<Wakes>,
    whole_closed: tokio::sync::watch::Sender<bool>,
}
impl AnyTls {
    pub(crate) async fn open(
        mut inner: BoxStream,
        password: &str,
        target: &Target,
        shared: SharedPadding,
    ) -> io::Result<Self> {
        let padding = shared.read().unwrap().clone();
        let size = padding.auth_size()?;
        let mut auth = Sha256::digest(password.as_bytes()).to_vec();
        auth.extend_from_slice(&(size as u16).to_be_bytes());
        auth.resize(34 + size, 0);
        // Do not split authentication across TLS application writes. The reference
        // server inspects a single TLS read. A short accepted write is fatal.
        if inner.write(&auth).await? != auth.len() {
            return Err(io::Error::other("incomplete AnyTLS authentication write"));
        }
        inner.flush().await?;
        let mut first = Vec::new();
        append_frame(
            &mut first,
            4,
            0,
            format!(
                "v=2\nclient=zc/{}\npadding-md5={}",
                env!("CARGO_PKG_VERSION"),
                padding.md5
            )
            .as_bytes(),
        );
        append_frame(&mut first, 1, 1, &[]);
        let mut address = Vec::new();
        destination(target).write_to_buf(&mut address);
        append_frame(&mut first, 2, 1, &address);
        let outgoing = padding.packets(1, first)?;
        let mut stream = Self {
            inner: Some(inner),
            padding,
            shared,
            group: 2,
            outgoing,
            written: 0,
            hearts: VecDeque::new(),
            reply_pending: false,
            header: [0; 7],
            header_read: 0,
            body: Vec::new(),
            body_read: 0,
            delivered: 0,
            data_ready: false,
            v2: false,
            acknowledged: false,
            fin_queued: false,
            write_closed: false,
            peer_closed: false,
            close_deadline: None,
            close_drained: 0,
            failure: None,
            wakes: Arc::default(),
            whole_closed: tokio::sync::watch::channel(false).0,
        };
        stream.flush().await?;
        Ok(stream)
    }
    fn register(&self, cx: &Context<'_>, write: bool) -> Waker {
        self.wakes.0.lock().unwrap()[usize::from(write)] = Some(cx.waker().clone());
        Waker::from(self.wakes.clone())
    }
    fn fail(&mut self, error: io::Error) -> io::Error {
        self.failure = Some(error.kind());
        self.finish();
        truncated_read(error)
    }
    fn finish(&mut self) {
        self.inner.take();
        self.close_deadline.take();
        self.outgoing.clear();
        self.hearts.clear();
        if self.failure.is_none() {
            self.whole_closed.send_replace(true);
        }
        self.wakes.wake_by_ref();
    }
    fn check_error(&self) -> io::Result<()> {
        if let Some(kind) = self.failure {
            return Err(truncated_read(io::Error::new(
                kind,
                "AnyTLS session failed",
            )));
        }
        Ok(())
    }
    fn queue(&mut self, cmd: u8, id: u32, body: &[u8]) -> io::Result<()> {
        debug_assert!(self.outgoing.is_empty());
        let mut frame = Vec::with_capacity(7 + body.len());
        append_frame(&mut frame, cmd, id, body);
        self.outgoing = self.padding.packets(self.group, frame)?;
        self.group = (self.group + 1).min(MAX_STOP);
        Ok(())
    }
    fn drain(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        // One active group (at most 17 bounded packets), then at most MAX_HEARTS
        // replies. Never insert a control frame into a partially written group.
        loop {
            while let Some(packet) = self.outgoing.front() {
                let result = Pin::new(self.inner.as_mut().ok_or_else(closed)?)
                    .poll_write(cx, &packet[self.written..]);
                match ready!(result) {
                    Ok(0) => {
                        return Poll::Ready(Err(self.fail(io::Error::new(
                            io::ErrorKind::WriteZero,
                            "AnyTLS write stopped",
                        ))));
                    }
                    Ok(n) => self.written += n,
                    Err(e) => return Poll::Ready(Err(self.fail(e))),
                }
                if self.written == packet.len() {
                    self.outgoing.pop_front();
                    self.written = 0;
                }
            }
            if let Some(id) = self.hearts.pop_front() {
                self.queue(9, id, &[])?;
                continue;
            }
            return match ready!(Pin::new(self.inner.as_mut().ok_or_else(closed)?).poll_flush(cx)) {
                Ok(()) => Poll::Ready(Ok(())),
                Err(e) => Poll::Ready(Err(self.fail(e))),
            };
        }
    }
    fn shutdown_write(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        ready!(self.drain(cx))?;
        if !self.fin_queued {
            self.fin_queued = true;
            if let Err(e) = self.queue(3, 1, &[]) {
                return Poll::Ready(Err(self.fail(e)));
            }
        }
        ready!(self.drain(cx))?;
        // Empty application queues alone do not prove completion: TLS may still
        // have a Pending flush, including close_notify, before TCP write shutdown.
        match ready!(Pin::new(self.inner.as_mut().unwrap()).poll_shutdown(cx)) {
            Ok(()) => self.write_closed = true,
            Err(e) => return Poll::Ready(Err(self.fail(e))),
        }
        Poll::Ready(Ok(()))
    }
    fn validate_header(&self) -> io::Result<()> {
        let cmd = self.header[0];
        let id = u32::from_be_bytes(self.header[1..5].try_into().unwrap());
        let len = u16::from_be_bytes([self.header[5], self.header[6]]) as usize;
        let valid = match cmd {
            0 => id == 0,
            2 => id == 1,
            3 => id == 1 && len == 0,
            5 | 6 => id == 0 && len <= MAX_TEXT,
            7 => self.v2 && !self.acknowledged && id == 1 && len <= MAX_TEXT,
            8 | 9 => self.v2 && len == 0,
            10 => !self.v2 && id == 0 && len <= MAX_TEXT,
            _ => false,
        };
        if valid { Ok(()) } else { Err(invalid()) }
    }
    fn control(&mut self) -> io::Result<()> {
        match self.header[0] {
            0 | 9 => (),
            2 => self.data_ready = !self.body.is_empty(),
            3 => self.finish(),
            5 => {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "AnyTLS server rejected session",
                ));
            }
            6 => {
                let candidate = Arc::new(Padding::parse(&self.body)?);
                *self.shared.write().unwrap() = candidate;
            }
            7 => {
                self.acknowledged = true;
                if !self.body.is_empty() {
                    return Err(io::Error::new(
                        io::ErrorKind::ConnectionRefused,
                        "AnyTLS remote stream failed",
                    ));
                }
            }
            8 => {
                if self.hearts.len() == MAX_HEARTS {
                    return Err(invalid());
                }
                self.hearts
                    .push_back(u32::from_be_bytes(self.header[1..5].try_into().unwrap()));
                self.reply_pending = true;
            }
            10 => {
                let fields = fields(&self.body)?;
                let v = number(fields.get("v").ok_or_else(invalid)?)?;
                if !(2..=u16::MAX as usize).contains(&v) {
                    return Err(invalid());
                }
                self.v2 = true;
            }
            _ => return Err(invalid()),
        }
        Ok(())
    }
    fn receive(&mut self, cx: &mut Context<'_>, output: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        self.check_error()?;
        for _ in 0..32 {
            if self.data_ready {
                let n = output.remaining().min(self.body.len() - self.delivered);
                output.put_slice(&self.body[self.delivered..self.delivered + n]);
                self.delivered += n;
                if self.delivered == self.body.len() {
                    self.data_ready = false;
                }
                return Poll::Ready(Ok(()));
            }
            if self.inner.is_none() {
                return Poll::Ready(Ok(()));
            }
            // Local shutdown owns transport reads until cleanup completes. Expose
            // only an already assembled PSH tail here. EOF or whole_close earlier
            // would let runtime::transfer cancel the pending shutdown owner.
            if self.close_deadline.is_some() {
                return Poll::Pending;
            }
            // A Pending control write must not gate reads: both TCP directions
            // can be full. Keep replies bounded and reject excess requests instead
            // of blocking PSH/FIN or overwriting an in-flight data frame.
            if self.reply_pending
                && let Poll::Ready(result) = self.drain(cx)
            {
                result?;
                self.reply_pending = false;
            }
            while self.header_read < 7 {
                let mut b = ReadBuf::new(&mut self.header[self.header_read..]);
                match ready!(Pin::new(self.inner.as_mut().unwrap()).poll_read(cx, &mut b)) {
                    Ok(()) if b.filled().is_empty() => {
                        return Poll::Ready(Err(
                            self.fail(io::Error::from(io::ErrorKind::UnexpectedEof))
                        ));
                    }
                    Ok(()) => self.header_read += b.filled().len(),
                    Err(e) => return Poll::Ready(Err(self.fail(e))),
                }
                if self.header_read == 7 {
                    if let Err(e) = self.validate_header() {
                        return Poll::Ready(Err(self.fail(e)));
                    }
                    self.body.resize(
                        u16::from_be_bytes([self.header[5], self.header[6]]) as usize,
                        0,
                    );
                    self.body_read = 0;
                    self.delivered = 0;
                }
            }
            while self.body_read < self.body.len() {
                let mut b = ReadBuf::new(&mut self.body[self.body_read..]);
                match ready!(Pin::new(self.inner.as_mut().unwrap()).poll_read(cx, &mut b)) {
                    Ok(()) if b.filled().is_empty() => {
                        return Poll::Ready(Err(
                            self.fail(io::Error::from(io::ErrorKind::UnexpectedEof))
                        ));
                    }
                    Ok(()) => self.body_read += b.filled().len(),
                    Err(e) => return Poll::Ready(Err(self.fail(e))),
                }
            }
            if let Err(e) = self.control() {
                return Poll::Ready(Err(self.fail(e)));
            }
            self.header_read = 0;
        }
        cx.waker().wake_by_ref();
        Poll::Pending
    }
}
impl crate::outbound::IoStream for AnyTls {
    fn whole_close(&self) -> Option<tokio::sync::watch::Receiver<bool>> {
        Some(self.whole_closed.subscribe())
    }
}
impl AsyncRead for AnyTls {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        output: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if output.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        let w = self.register(cx, false);
        self.receive(&mut Context::from_waker(&w), output)
    }
}
impl AsyncWrite for AnyTls {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        self.check_error()?;
        if self.close_deadline.is_some() || self.inner.is_none() {
            return Poll::Ready(Err(closed()));
        }
        if data.is_empty() {
            return Poll::Ready(Ok(0));
        }
        let w = self.register(cx, true);
        ready!(self.drain(&mut Context::from_waker(&w)))?;
        let n = data.len().min(MAX_FRAME);
        if let Err(e) = self.queue(2, 1, &data[..n]) {
            return Poll::Ready(Err(self.fail(e)));
        }
        // Accepted exactly once; subsequent polls drain before accepting more.
        Poll::Ready(Ok(n))
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.check_error()?;
        if self.inner.is_none() {
            return Poll::Ready(Ok(()));
        }
        if self.write_closed {
            return Poll::Ready(Ok(()));
        }
        let w = self.register(cx, true);
        self.drain(&mut Context::from_waker(&w))
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.check_error()?;
        if self.inner.is_none() {
            return Poll::Ready(Ok(()));
        }
        let w = self.register(cx, true);
        let mut cx = Context::from_waker(&w);
        let deadline = self
            .close_deadline
            .get_or_insert_with(|| Box::pin(tokio::time::sleep(CLOSE_TIMEOUT)));
        if deadline.as_mut().poll(&mut cx).is_ready() {
            return Poll::Ready(Err(self.fail(io::Error::from(io::ErrorKind::TimedOut))));
        }
        if !self.write_closed
            && let Poll::Ready(result) = self.shutdown_write(&mut cx)
        {
            result?;
        }
        // Drive reads even while accepted writes/FIN/TLS shutdown are Pending:
        // both TCP directions may be full, with the peer sending before reading.
        // Dropping unread TLS can reset TCP and discard our accepted PSH/FIN.
        // This is bounded transport cleanup, not a half-close response or FIN ack.
        let mut discard = [0; 16384];
        for _ in 0..16 {
            if self.peer_closed {
                break;
            }
            let remaining = (MAX_CLOSE_DRAIN - self.close_drained + 1).min(discard.len());
            let mut b = ReadBuf::new(&mut discard[..remaining]);
            match ready!(Pin::new(self.inner.as_mut().unwrap()).poll_read(&mut cx, &mut b)) {
                Ok(()) if !b.filled().is_empty() => {
                    self.close_drained += b.filled().len();
                    if self.close_drained > MAX_CLOSE_DRAIN {
                        return Poll::Ready(Err(self.fail(invalid())));
                    }
                }
                // Local close also accepts ordinary TCP EOF, but it never proves
                // our write side completed. Keep queued PSH/FIN and TLS flushes.
                Ok(()) => self.peer_closed = true,
                Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => self.peer_closed = true,
                Err(e) => return Poll::Ready(Err(self.fail(e))),
            }
        }
        if self.peer_closed && self.write_closed {
            self.finish();
            return Poll::Ready(Ok(()));
        }
        if !self.peer_closed {
            cx.waker().wake_by_ref();
        }
        Poll::Pending
    }
}

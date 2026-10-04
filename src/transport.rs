//! Getting one elisp form evaluated by a running Emacs and its printed
//! value back.
//!
//! The primary transport speaks the Emacs server socket protocol directly
//! (what `emacsclient` speaks, `server.el`'s `server-process-filter`): one
//! request line `-eval <&-quoted form>\n`, then the server answers with
//! `-emacs-pid N`, one or more `-print`/`-print-nonl` chunks (it splits
//! replies at 1024 bytes) or `-error MSG`, and closes the connection. No
//! process is spawned per call. `emacsclient --eval` is the fallback for
//! servers this can't reach directly (TCP servers, a missing socket path).
//!
//! The form itself never carries caller data as an elisp string literal:
//! [`rpc_form`] wraps the request as base64, so there is no elisp quoting
//! anywhere.

use base64::Engine as _;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;

/// Why a form could not be evaluated. `Unreachable` maps to the
/// `driver.unreachable` error (exit 5); the rest to transport errors.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportError {
    /// No Emacs answered on the resolved socket (or emacsclient couldn't connect).
    Unreachable(String),
    /// Emacs answered with `-error` (the form signaled).
    EmacsError(String),
    /// The reply was not the protocol we expect.
    Protocol(String),
    /// Emacs did not finish answering within the io timeout.
    Timeout(String),
}

impl std::fmt::Display for TransportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TransportError::Unreachable(m) => write!(f, "emacs unreachable: {m}"),
            TransportError::EmacsError(m) => write!(f, "emacs signaled: {m}"),
            TransportError::Protocol(m) => write!(f, "protocol error: {m}"),
            TransportError::Timeout(m) => write!(f, "timed out: {m}"),
        }
    }
}

impl std::error::Error for TransportError {}

/// Which transport(s) a client may use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportMode {
    /// Socket first; emacsclient when the socket can't be reached.
    Auto,
    Socket,
    Emacsclient,
}

impl TransportMode {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "auto" => Some(Self::Auto),
            "socket" => Some(Self::Socket),
            "emacsclient" => Some(Self::Emacsclient),
            _ => None,
        }
    }
}

/// `server-quote-arg`: `&`→`&&`, `-`→`&-`, newline→`&n`, space→`&_`.
pub fn quote_arg(arg: &str) -> String {
    let mut out = String::with_capacity(arg.len() + 8);
    for c in arg.chars() {
        match c {
            '&' => out.push_str("&&"),
            '-' => out.push_str("&-"),
            '\n' => out.push_str("&n"),
            ' ' => out.push_str("&_"),
            c => out.push(c),
        }
    }
    out
}

/// `server-unquote-arg`, the inverse of [`quote_arg`].
pub fn unquote_arg(arg: &str) -> String {
    let mut out = String::with_capacity(arg.len());
    let mut chars = arg.chars();
    while let Some(c) = chars.next() {
        if c != '&' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('&') => out.push('&'),
            Some('-') => out.push('-'),
            Some('n') => out.push('\n'),
            Some(_) => out.push(' '),
            None => out.push('&'),
        }
    }
    out
}

/// Parse a complete server reply into the printed text.
pub fn parse_reply(reply: &str) -> Result<String, TransportError> {
    let mut printed = String::new();
    let mut saw_print = false;
    for line in reply.split('\n').filter(|l| !l.is_empty()) {
        let (cmd, arg) = line.split_once(' ').unwrap_or((line, ""));
        match cmd {
            "-emacs-pid" => {}
            "-print" | "-print-nonl" => {
                saw_print = true;
                printed.push_str(&unquote_arg(arg));
            }
            "-error" => {
                return Err(TransportError::EmacsError(
                    unquote_arg(arg).trim().to_string(),
                ))
            }
            other => {
                return Err(TransportError::Protocol(format!(
                    "unexpected server command `{other}`"
                )))
            }
        }
    }
    if saw_print {
        Ok(printed)
    } else {
        Err(TransportError::Protocol(
            "server closed without printing a value".into(),
        ))
    }
}

/// The printed value of a base64 string (`"QUJD"` plus pp's newline) → bytes.
pub fn decode_printed_base64(printed: &str) -> Result<Vec<u8>, TransportError> {
    let t = printed.trim();
    let inner = t
        .strip_prefix('"')
        .and_then(|s| s.strip_suffix('"'))
        .ok_or_else(|| TransportError::Protocol(format!("reply is not a string: {}", short(t))))?;
    B64.decode(inner).map_err(|e| {
        TransportError::Protocol(format!("reply is not base64 ({e}): {}", short(inner)))
    })
}

fn short(s: &str) -> String {
    s.chars().take(160).collect()
}

/// What [`rpc_form`] prints when the target Emacs hasn't loaded etm.
pub const UNLOADED: &str = "etm-rpc-unloaded";

/// What [`rpc_locate_form`] prints when `(locate-library "etm")` finds
/// nothing on the server's `load-path`.
pub const NOT_INSTALLED: &str = "etm-not-installed";

/// The form a request is sent as: `(etm-rpc "<base64 json>")` when the
/// function is defined, else the symbol [`UNLOADED`] -- so the caller can
/// resend with the autoload ([`rpc_load_form`]) on a budget a first load
/// needs, and a loaded Emacs costs no extra round trip.
pub fn rpc_form(request_json: &str) -> String {
    let req = B64.encode(request_json.as_bytes());
    format!("(if (fboundp 'etm-rpc) (etm-rpc \"{req}\") '{UNLOADED})")
}

/// [`rpc_form`] preceded by a load of RPC_EL (path also base64) unless
/// the function is defined by then. RPC_EL is an elisp file that defines
/// `etm-rpc` (etm.el, or a configuration that loads it; its directory
/// goes on `load-path` first), or a directory holding etm.el, which goes
/// on `load-path` before `(require 'etm)`.
pub fn rpc_load_form(request_json: &str, rpc_el: &Path) -> String {
    let req = B64.encode(request_json.as_bytes());
    let p = B64.encode(rpc_el.as_os_str().as_encoded_bytes());
    let path = format!("(decode-coding-string (base64-decode-string \"{p}\") 'utf-8)");
    let load = if rpc_el.is_dir() {
        format!("(progn (add-to-list 'load-path {path}) (require 'etm))")
    } else {
        // Its directory too: etm.el requires its sibling etm-*.el files.
        format!(
            "(let ((f {path})) (add-to-list 'load-path (directory-file-name \
             (file-name-directory f))) (load f nil t))"
        )
    };
    format!("(progn (unless (fboundp 'etm-rpc) {load}) (etm-rpc \"{req}\"))")
}

/// [`rpc_form`] that first tries the server's own installation: when
/// `(locate-library "etm")` finds the package, require it; else print
/// [`NOT_INSTALLED`].
pub fn rpc_locate_form(request_json: &str) -> String {
    let req = B64.encode(request_json.as_bytes());
    format!(
        "(cond ((fboundp 'etm-rpc) (etm-rpc \"{req}\")) \
         ((locate-library \"etm\") (require 'etm) (etm-rpc \"{req}\")) \
         (t '{NOT_INSTALLED}))"
    )
}

/// Where the Emacs server socket for NAME lives, mirroring
/// `server-socket-dir`: an absolute or relative path is used as is, else
/// `$XDG_RUNTIME_DIR/emacs/NAME` when that exists, else
/// `${TMPDIR:-/tmp}/emacs$UID/NAME`.
pub fn resolve_socket(name: Option<&str>) -> PathBuf {
    let name = name
        .map(str::to_string)
        .or_else(|| std::env::var("ETM_SOCKET").ok().filter(|s| !s.is_empty()))
        .or_else(|| {
            std::env::var("EMACS_SOCKET_NAME")
                .ok()
                .filter(|s| !s.is_empty())
        })
        .unwrap_or_else(|| "server".to_string());
    if name.contains('/') {
        return PathBuf::from(name);
    }
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    let xdg = std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|d| !d.is_empty())
        .map(|d| PathBuf::from(d).join("emacs").join(&name));
    let tmp = std::env::var_os("TMPDIR")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(format!("emacs{uid}"))
        .join(&name);
    match xdg {
        Some(p) if p.exists() || !tmp.exists() => p,
        _ => tmp,
    }
}

/// Evaluate FORM over the server socket at PATH, allowing the whole
/// round trip TIMEOUT. A slow verb (rendering a page) answers after
/// seconds of silence: an expired read timeout surfaces as EAGAIN
/// (macOS: os error 35) or ETIMEDOUT, and EINTR can cut a read short, so
/// those only end the call once the deadline has passed
/// ([`TransportError::Timeout`]).
pub fn eval_socket(path: &Path, form: &str, timeout: Duration) -> Result<String, TransportError> {
    let deadline = Instant::now() + timeout;
    let mut stream = UnixStream::connect(path)
        .map_err(|e| TransportError::Unreachable(format!("{}: {e}", path.display())))?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(|e| TransportError::Protocol(e.to_string()))?;
    let line = format!("-eval {}\n", quote_arg(form));
    stream
        .write_all(line.as_bytes())
        .map_err(|e| TransportError::Unreachable(format!("write: {e}")))?;
    let buf = read_until_closed(&mut stream, deadline, timeout)?;
    parse_reply(&String::from_utf8_lossy(&buf))
}

/// setsockopt on a socket whose peer already hung up: EINVAL on macOS
/// (os error 22), never on Linux. The data (or EOF) is still readable.
fn peer_closed(e: &std::io::Error) -> bool {
    e.raw_os_error() == Some(22)
}

/// Everything STREAM sends until the server closes it, or a timeout once
/// DEADLINE passes (TIMEOUT is the budget, for the message).
fn read_until_closed(
    stream: &mut UnixStream,
    deadline: Instant,
    timeout: Duration,
) -> Result<Vec<u8>, TransportError> {
    use std::io::ErrorKind::{Interrupted, TimedOut, WouldBlock};
    let expired = || {
        TransportError::Timeout(format!(
            "no complete reply within {:.1}s",
            timeout.as_secs_f64()
        ))
    };
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(expired());
        }
        // A zero read timeout means "block forever": never pass one.
        // macOS rejects SO_RCVTIMEO with EINVAL once the peer has closed
        // (Emacs replies and hangs up fast); the read below then sees EOF.
        if let Err(e) = stream.set_read_timeout(Some(left.max(Duration::from_millis(1)))) {
            if !peer_closed(&e) {
                return Err(TransportError::Protocol(e.to_string()));
            }
        }
        match stream.read(&mut chunk) {
            Ok(0) => return Ok(buf),
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(e) if matches!(e.kind(), WouldBlock | TimedOut | Interrupted) => {}
            Err(e) => return Err(TransportError::Protocol(format!("read: {e}"))),
        }
    }
}

/// Evaluate FORM through `emacsclient --eval` (socket NAME when given).
pub fn eval_emacsclient(
    emacsclient: &Path,
    socket: Option<&str>,
    form: &str,
) -> Result<String, TransportError> {
    let mut cmd = Command::new(emacsclient);
    if let Some(s) = socket {
        cmd.arg("-s").arg(s);
    }
    let out = cmd
        .arg("--eval")
        .arg(form)
        .output()
        .map_err(|e| TransportError::Unreachable(format!("{}: {e}", emacsclient.display())))?;
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
    if out.status.success() {
        return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
    }
    if stderr.contains("connect") || stderr.contains("socket") || stderr.contains("server") {
        Err(TransportError::Unreachable(stderr))
    } else {
        Err(TransportError::EmacsError(stderr))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quote_round_trips_every_special() {
        let s = "a-b &c\nd--&&e";
        assert_eq!(quote_arg(s), "a&-b&_&&c&nd&-&-&&&&e");
        assert_eq!(unquote_arg(&quote_arg(s)), s);
    }

    #[test]
    fn reply_joins_print_chunks() {
        let r = "-emacs-pid 42\n-print \"QU&-\n-print-nonl JD\"&n\n";
        assert_eq!(parse_reply(r).unwrap(), "\"QU-JD\"\n");
    }

    #[test]
    fn reply_error_and_garbage() {
        assert_eq!(
            parse_reply("-emacs-pid 1\n-error Symbol&_void\n"),
            Err(TransportError::EmacsError("Symbol void".into()))
        );
        assert!(matches!(
            parse_reply("-emacs-pid 1\n"),
            Err(TransportError::Protocol(_))
        ));
        assert!(matches!(
            parse_reply("-weird x\n"),
            Err(TransportError::Protocol(_))
        ));
    }

    #[test]
    fn printed_base64_decodes() {
        assert_eq!(decode_printed_base64("\"e30=\"\n").unwrap(), b"{}");
        assert!(decode_printed_base64("nil").is_err());
    }

    #[test]
    fn form_carries_no_caller_text() {
        let f = rpc_form("{\"verb\":\"send\",\"text\":\"\\\" (kill-emacs)\"}");
        assert!(f.contains("(etm-rpc \"") && !f.contains("kill-emacs"));
        assert!(f.starts_with("(if (fboundp 'etm-rpc) ") && f.ends_with("'etm-rpc-unloaded)"));
        let f = rpc_load_form("{}", Path::new("/x y/etm.el"));
        assert!(f.contains("(fboundp 'etm-rpc)") && !f.contains("/x y"));
        assert!(f.contains("(load f nil t)") && f.contains("(file-name-directory f)"));
        let dir = tempfile::tempdir().unwrap();
        let f = rpc_load_form("{}", dir.path());
        assert!(f.contains("(add-to-list 'load-path") && f.contains("(require 'etm)"));
        let f = rpc_locate_form("{}");
        assert!(f.contains("(locate-library \"etm\")") && f.ends_with("'etm-not-installed))"));
    }

    #[test]
    fn socket_paths() {
        assert_eq!(resolve_socket(Some("/tmp/a/b")), PathBuf::from("/tmp/a/b"));
        let p = resolve_socket(Some("named"));
        assert!(p.ends_with("named"));
    }

    /// A one-shot server at a fresh socket path that reads the request
    /// line, waits DELAY, then answers REPLY in two halves PAUSE apart.
    fn slow_server(
        delay: Duration,
        pause: Duration,
        reply: &'static str,
    ) -> (tempfile::TempDir, PathBuf) {
        use std::io::BufRead;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        std::thread::spawn(move || {
            let (mut conn, _) = listener.accept().unwrap();
            let mut line = String::new();
            std::io::BufReader::new(&conn).read_line(&mut line).unwrap();
            std::thread::sleep(delay);
            let (a, b) = reply.split_at(reply.len() / 2);
            let _ = conn.write_all(a.as_bytes());
            std::thread::sleep(pause);
            let _ = conn.write_all(b.as_bytes());
        });
        (dir, path)
    }

    #[test]
    fn a_slow_answer_inside_the_budget_succeeds() {
        // Silence longer than any single short read, total under budget.
        let (_dir, path) = slow_server(
            Duration::from_millis(600),
            Duration::from_millis(300),
            "-emacs-pid 7\n-print \"ok\"\n",
        );
        let got = eval_socket(&path, "(slow)", Duration::from_secs(5));
        assert_eq!(got.unwrap(), "\"ok\"");
    }

    #[test]
    fn the_budget_bounds_the_whole_round_trip() {
        // Each half arrives inside the budget; together they exceed it.
        let (_dir, path) = slow_server(
            Duration::from_millis(400),
            Duration::from_millis(900),
            "-emacs-pid 7\n-print \"late\"\n",
        );
        let t = Instant::now();
        let got = eval_socket(&path, "(slow)", Duration::from_secs(1));
        assert!(matches!(got, Err(TransportError::Timeout(_))), "{got:?}");
        assert!(
            t.elapsed() < Duration::from_millis(1250),
            "{:?}",
            t.elapsed()
        );
    }
}

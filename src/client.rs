//! The etm client library: one verb call = one envelope. This is what the
//! `etm` CLI drives, and what another tool embeds to drive Emacs.

use crate::elisp;
use crate::envelope::{self, exit};
use crate::transport::{self, TransportError, TransportMode};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// The least budget of the call that loads etm into an Emacs that hasn't
/// loaded it yet: a session still busy starting up can take seconds.
pub const LOAD_TIMEOUT: Duration = Duration::from_secs(30);

/// How to reach Emacs.
#[derive(Debug, Clone)]
pub struct Config {
    /// Socket name or path (`-s` semantics); `None` = env/default.
    pub socket: Option<String>,
    pub mode: TransportMode,
    pub emacsclient: PathBuf,
    /// Elisp to load when the target Emacs hasn't loaded etm yet: a file
    /// defining `etm-rpc` (etm.el, or a configuration that loads it), or
    /// the directory holding etm.el. `--rpc-el`, else `$ETM_RPC_EL`.
    pub rpc_el: Option<PathBuf>,
    /// Without `rpc_el`: try the server's own installation
    /// (`(locate-library "etm")`), then the elisp bundled in this binary.
    /// Off with `--no-autoload`.
    pub discover: bool,
    /// Socket read/write timeout for one call.
    pub io_timeout: Duration,
    /// Schema names accepted besides [`envelope::SCHEMA`] (a tool that
    /// embeds etm under its own name for the same envelope).
    pub accept_schemas: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            socket: None,
            mode: TransportMode::Auto,
            emacsclient: PathBuf::from("emacsclient"),
            rpc_el: default_rpc_el(),
            discover: true,
            io_timeout: Duration::from_secs(30),
            accept_schemas: Vec::new(),
        }
    }
}

/// `$ETM_RPC_EL`, when it names a file or directory that exists.
pub fn default_rpc_el() -> Option<PathBuf> {
    std::env::var_os("ETM_RPC_EL")
        .filter(|p| !p.is_empty())
        .map(PathBuf::from)
        .filter(|p| p.exists())
        .map(|p| p.canonicalize().unwrap_or(p))
}

/// A connection-less client: every call opens one socket round trip.
#[derive(Debug, Clone)]
pub struct Client {
    pub config: Config,
}

impl Client {
    pub fn new(config: Config) -> Self {
        Self { config }
    }

    /// Evaluate one raw elisp form within TIMEOUT, returning its printed
    /// value.
    fn eval(&self, form: &str, timeout: Duration) -> Result<String, TransportError> {
        let c = &self.config;
        let via_client = || transport::eval_emacsclient(&c.emacsclient, c.socket.as_deref(), form);
        match c.mode {
            TransportMode::Emacsclient => via_client(),
            TransportMode::Socket => transport::eval_socket(
                &transport::resolve_socket(c.socket.as_deref()),
                form,
                timeout,
            ),
            TransportMode::Auto => {
                let path = transport::resolve_socket(c.socket.as_deref());
                match transport::eval_socket(&path, form, timeout) {
                    Err(TransportError::Unreachable(first)) => via_client().map_err(|e| match e {
                        TransportError::Unreachable(second) => {
                            TransportError::Unreachable(format!("{first}; emacsclient: {second}"))
                        }
                        other => other,
                    }),
                    other => other,
                }
            }
        }
    }

    /// Send VERB with ARGS; always returns an envelope (transport failures
    /// become `driver.unreachable` / `transport.*` envelopes).
    pub fn call(&self, verb: &str, args: Value) -> Value {
        let request = json!({"v": 1, "verb": verb, "args": args}).to_string();
        let reply = self
            .eval(&transport::rpc_form(&request), self.config.io_timeout)
            .and_then(|printed| self.autoload(&request, printed))
            .and_then(|printed| transport::decode_printed_base64(&printed));
        match reply {
            Ok(bytes) => match serde_json::from_slice::<Value>(&bytes) {
                Ok(v) => match envelope::validate_with(&v, &self.config.accept_schemas) {
                    Ok(()) => v,
                    Err(why) => envelope::failure(verb, "transport.protocol", &why, None, false),
                },
                Err(e) => {
                    envelope::failure(verb, "transport.protocol", &e.to_string(), None, false)
                }
            },
            Err(TransportError::Unreachable(m)) => envelope::failure(
                verb,
                "driver.unreachable",
                &m,
                Some(
                    "start an Emacs server (M-x server-start or emacs --daemon), or pass --socket",
                ),
                true,
            ),
            Err(TransportError::EmacsError(m)) => envelope::failure(
                verb,
                "transport.emacs_error",
                &m,
                Some("is etm loadable? pass --rpc-el, set ETM_RPC_EL, or install it in Emacs"),
                false,
            ),
            Err(TransportError::Protocol(m)) => {
                envelope::failure(verb, "transport.protocol", &m, None, false)
            }
            Err(TransportError::Timeout(m)) => envelope::failure(
                verb,
                "transport.timeout",
                &m,
                Some("Emacs is busy or wedged; retry, or raise --io-timeout"),
                true,
            ),
        }
    }

    /// PRINTED, or -- when it says etm isn't loaded -- the reply to REQUEST
    /// resent with a load in front: `rpc_el` when configured, else the
    /// server's own installation, else the bundled elisp. That first load
    /// can take seconds (a session still loading its deferred packages),
    /// so it gets [`LOAD_TIMEOUT`] even under a short read budget.
    fn autoload(&self, request: &str, printed: String) -> Result<String, TransportError> {
        if printed.trim() != transport::UNLOADED {
            return Ok(printed);
        }
        let budget = self.config.io_timeout.max(LOAD_TIMEOUT);
        if let Some(el) = self.config.rpc_el.as_deref() {
            return self.eval(&transport::rpc_load_form(request, el), budget);
        }
        if !self.config.discover {
            return Err(TransportError::EmacsError(
                "etm is not loaded in this Emacs and autoload is off".into(),
            ));
        }
        let printed = self.eval(&transport::rpc_locate_form(request), budget)?;
        if printed.trim() != transport::NOT_INSTALLED {
            return Ok(printed);
        }
        let dir = elisp::materialize().map_err(|e| {
            TransportError::EmacsError(format!(
                "etm is not installed in this Emacs, and the bundled elisp could not be written: {e}"
            ))
        })?;
        self.eval(&transport::rpc_load_form(request, &dir), budget)
    }

    /// `wait` without blocking Emacs: poll with timeout 0 every POLL until
    /// ARGS' condition holds or TIMEOUT passes. Polls are marked `poll` so
    /// only the deciding check is logged as an event. A `match:` wait with
    /// no `since` first pins the pane's current end, so every poll searches
    /// the same range.
    pub fn wait(&self, mut args: Value, timeout: Duration, poll: Duration) -> Value {
        let start = Instant::now();
        let addr = args["addr"].clone();
        let is_match = args["until"]
            .as_str()
            .is_some_and(|u| u.starts_with("match:"));
        if is_match && args["since"].is_null() {
            let pin = self.call("capture", json!({"addr": addr, "max_chars": 0}));
            if envelope::exit_code(&pin) != exit::OK {
                return pin;
            }
            args["since"] = pin["data"]["cursor"].clone();
        }
        loop {
            let final_poll = start.elapsed() + poll >= timeout;
            args["timeout"] = json!(0);
            args["poll"] = json!(true);
            args["final"] = json!(final_poll);
            let mut env = self.call("wait", args.clone());
            let code = envelope::exit_code(&env);
            if code != exit::WAIT_TIMEOUT || final_poll {
                if let Some(d) = env["data"].as_object_mut() {
                    d.insert(
                        "elapsed_ms".into(),
                        json!(start.elapsed().as_millis() as u64),
                    );
                }
                if code == exit::WAIT_TIMEOUT {
                    env["errors"][0]["msg"] = json!(format!(
                        "`{}` not met for {} within {:.1}s",
                        args["until"].as_str().unwrap_or(""),
                        args["addr"].as_str().unwrap_or(""),
                        timeout.as_secs_f64()
                    ));
                }
                return env;
            }
            std::thread::sleep(poll);
        }
    }

    /// Time N `snapshot` round trips (the round-trip bench). Returns
    /// milliseconds, sorted ascending; the first error envelope aborts.
    pub fn bench(&self, n: usize) -> Result<Vec<f64>, Value> {
        let mut out = Vec::with_capacity(n);
        for _ in 0..n {
            let t = Instant::now();
            let env = self.call("snapshot", json!({}));
            if envelope::exit_code(&env) != exit::OK {
                return Err(env);
            }
            out.push(t.elapsed().as_secs_f64() * 1000.0);
        }
        out.sort_by(f64::total_cmp);
        Ok(out)
    }
}

/// The value at quantile Q (0..=1) of ascending SORTED samples.
pub fn quantile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return f64::NAN;
    }
    let idx = ((sorted.len() - 1) as f64 * q).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quantiles() {
        let s = [1.0, 2.0, 3.0, 4.0, 5.0];
        assert_eq!(quantile(&s, 0.5), 3.0);
        assert_eq!(quantile(&s, 1.0), 5.0);
        assert!(quantile(&[], 0.5).is_nan());
    }

    #[test]
    fn unreachable_socket_is_exit_5() {
        let client = Client::new(Config {
            socket: Some("/nonexistent/etm-test-socket".into()),
            mode: TransportMode::Socket,
            ..Config::default()
        });
        let env = client.call("snapshot", json!({}));
        assert_eq!(env["errors"][0]["code"], "driver.unreachable");
        assert_eq!(envelope::exit_code(&env), 5);
    }
}

//! The throwaway Emacs the etm end-to-end tests drive: `emacs -Q
//! --daemon=<unique socket>` with HOME and the socket in a private 0700
//! tempdir, killed on drop. Never a real session.
#![allow(dead_code)]

use serde_json::Value;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// The bundled elisp, written once per test binary into a private
/// directory; its etm.el is what the daemons autoload.
pub fn rpc_el() -> PathBuf {
    static DIR: OnceLock<tempfile::TempDir> = OnceLock::new();
    let dir = DIR.get_or_init(|| {
        let d = tempfile::Builder::new()
            .prefix("etm-lisp")
            .tempdir()
            .expect("tempdir");
        etm::elisp::install(d.path()).expect("install the bundled elisp");
        d
    });
    dir.path().join("etm.el")
}

pub fn have_emacs() -> bool {
    let found = Command::new("emacs")
        .arg("--version")
        .output()
        .is_ok_and(|o| o.status.success());
    if !found {
        eprintln!("skipping: no `emacs` on PATH");
    }
    found
}

pub struct Daemon {
    pub dir: tempfile::TempDir,
    pid: Option<u32>,
}

impl Daemon {
    pub fn start() -> Self {
        let mut d = Self::start_bare();
        let (code, env) = d.etm(&["eval", "(emacs-pid)"]);
        assert_eq!(code, 0, "{env}");
        d.pid = env["data"]["value"].as_str().and_then(|s| s.parse().ok());
        d
    }

    /// A daemon that has not loaded etm yet.
    pub fn start_bare() -> Self {
        // Short /tmp path: unix socket paths are capped near 108 bytes.
        let dir = tempfile::Builder::new()
            .prefix("etm-it")
            .tempdir_in("/tmp")
            .expect("tempdir");
        // server.el refuses a socket dir others can read.
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700))
            .expect("chmod");
        let home = dir.path().join("home");
        std::fs::create_dir(&home).expect("home");
        let status = Command::new("emacs")
            .arg("-Q")
            .arg(format!("--daemon={}", dir.path().join("s").display()))
            .env("HOME", &home)
            .env_remove("XDG_RUNTIME_DIR")
            .output()
            .expect("spawn emacs --daemon");
        assert!(
            status.status.success(),
            "daemon failed: {}",
            String::from_utf8_lossy(&status.stderr)
        );
        let mut d = Daemon { dir, pid: None };
        d.pid = d.emacsclient("(emacs-pid)").and_then(|s| s.parse().ok());
        d
    }

    /// `emacsclient --eval FORM` against this daemon, given at most 3 s:
    /// its printed value, or None when Emacs did not answer in time.
    pub fn emacsclient(&self, form: &str) -> Option<String> {
        let out = Command::new("timeout")
            .args(["3", "emacsclient", "-s", &self.socket(), "--eval", form])
            .output()
            .expect("run emacsclient");
        out.status
            .success()
            .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    pub fn socket(&self) -> String {
        self.dir.path().join("s").display().to_string()
    }

    /// Run the etm binary against this daemon: (exit code, envelope).
    pub fn etm(&self, args: &[&str]) -> (i32, Value) {
        let rpc_el = rpc_el();
        let out = Command::new(env!("CARGO_BIN_EXE_etm"))
            .args([
                "--socket",
                &self.socket(),
                "--rpc-el",
                rpc_el.to_str().unwrap(),
            ])
            .args(args)
            .output()
            .expect("run etm");
        let stdout = String::from_utf8_lossy(&out.stdout);
        let env: Value = serde_json::from_str(stdout.trim())
            .unwrap_or_else(|e| panic!("etm {args:?} printed non-JSON ({e}): {stdout}"));
        assert_eq!(env["schema"], "etm.result/1", "{env}");
        (out.status.code().unwrap_or(-1), env)
    }

    /// Run the etm binary against this daemon: (exit code, raw stdout).
    pub fn raw(&self, args: &[&str]) -> (i32, String) {
        let rpc_el = rpc_el();
        let out = Command::new(env!("CARGO_BIN_EXE_etm"))
            .args([
                "--socket",
                &self.socket(),
                "--rpc-el",
                rpc_el.to_str().unwrap(),
            ])
            .args(args)
            .output()
            .expect("run etm");
        let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
        (out.status.code().unwrap_or(-1), stdout)
    }

    pub fn ok(&self, args: &[&str]) -> Value {
        let (code, env) = self.etm(args);
        assert_eq!(code, 0, "etm {args:?}: {env}");
        assert_eq!(env["ok"], true);
        env["data"].clone()
    }

    pub fn client(&self) -> etm::Client {
        etm::Client::new(etm::Config {
            socket: Some(self.socket()),
            mode: etm::TransportMode::Socket,
            rpc_el: Some(rpc_el()),
            ..etm::Config::default()
        })
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = Command::new("emacsclient")
            .args(["-s", &self.socket(), "--eval", "(kill-emacs)"])
            .output();
        if let Some(pid) = self.pid {
            let deadline = Instant::now() + Duration::from_secs(3);
            // SAFETY: signal 0 only probes whether PID still exists.
            while Instant::now() < deadline && unsafe { libc::kill(pid as libc::pid_t, 0) } == 0 {
                std::thread::sleep(Duration::from_millis(50));
            }
            // SAFETY: plain kill(2) on the daemon this test started.
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
        }
    }
}

pub fn s(v: &Value) -> &str {
    v.as_str().unwrap_or_default()
}

//! Where the CLI finds its elisp when the target Emacs hasn't loaded it:
//! `--rpc-el`, then `$ETM_RPC_EL`, then the server's own installation
//! (`(locate-library "etm")`), then the elisp bundled in the binary,
//! written to a versioned cache directory. And `etm install-elisp DIR`.
//! Each test drives a throwaway `emacs -Q --daemon`.

use serde_json::Value;
use std::path::Path;
use std::process::Command;

mod support;
use support::{have_emacs, rpc_el, s, Daemon};

/// Run the etm binary against D with ENV set and no `--rpc-el`.
fn etm_env(d: &Daemon, env: &[(&str, &Path)], args: &[&str]) -> (i32, Value) {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_etm"));
    cmd.args(["--socket", &d.socket()])
        .args(args)
        .env_remove("ETM_RPC_EL")
        .env("XDG_CACHE_HOME", d.dir.path().join("cache"));
    for (k, v) in env {
        cmd.env(k, v);
    }
    let out = cmd.output().expect("run etm");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let env: Value = serde_json::from_str(stdout.trim())
        .unwrap_or_else(|e| panic!("etm {args:?} printed non-JSON ({e}): {stdout}"));
    (out.status.code().unwrap_or(-1), env)
}

/// Where Emacs loaded `etm-rpc` from.
fn loaded_from(d: &Daemon) -> String {
    d.emacsclient("(symbol-file 'etm-rpc)").unwrap_or_default()
}

#[test]
fn bundled_elisp_is_the_last_resort() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start_bare();
    let (code, env) = etm_env(&d, &[], &["ws", "ls"]);
    assert_eq!(code, 0, "{env}");
    assert_eq!(env["schema"], "etm.result/1");
    let cache = d.dir.path().join("cache/etm");
    let dirs: Vec<_> = std::fs::read_dir(&cache)
        .expect("cache dir written")
        .filter_map(|e| e.ok())
        .collect();
    assert_eq!(dirs.len(), 1, "one versioned directory");
    let dir = dirs[0].path();
    assert!(dir.join("etm.el").is_file());
    assert!(
        loaded_from(&d).contains(&dir.display().to_string()),
        "{}",
        loaded_from(&d)
    );
    // Loaded now: no second load, the same answer.
    let (code, _) = etm_env(&d, &[], &["capabilities"]);
    assert_eq!(code, 0);
}

#[test]
fn the_servers_own_installation_comes_before_the_bundle() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start_bare();
    let lib = rpc_el().parent().unwrap().to_path_buf();
    d.emacsclient(&format!("(add-to-list 'load-path {:?})", lib))
        .expect("load-path set");
    let (code, env) = etm_env(&d, &[], &["snapshot", "--fields", "backend"]);
    assert_eq!(code, 0, "{env}");
    assert_eq!(env["data"]["backend"], "single");
    assert!(loaded_from(&d).contains(&lib.display().to_string()));
    assert!(
        !d.dir.path().join("cache/etm").exists(),
        "the bundle was not needed"
    );
}

#[test]
fn etm_rpc_el_and_the_flag_name_the_elisp() {
    if !have_emacs() {
        return;
    }
    let lib = rpc_el().parent().unwrap().to_path_buf();
    // $ETM_RPC_EL naming the directory.
    let d = Daemon::start_bare();
    let (code, env) = etm_env(&d, &[("ETM_RPC_EL", &lib)], &["ws", "ls"]);
    assert_eq!(code, 0, "{env}");
    assert!(loaded_from(&d).contains(&lib.display().to_string()));
    assert!(!d.dir.path().join("cache/etm").exists());
    // --rpc-el wins over $ETM_RPC_EL.
    let d = Daemon::start_bare();
    let bogus = d.dir.path().join("nothing-here");
    std::fs::create_dir(&bogus).unwrap();
    let el = lib.join("etm.el");
    let (code, env) = etm_env(
        &d,
        &[("ETM_RPC_EL", &bogus)],
        &["--rpc-el", el.to_str().unwrap(), "ws", "ls"],
    );
    assert_eq!(code, 0, "{env}");
    assert!(loaded_from(&d).contains(&lib.display().to_string()));
}

#[test]
fn no_autoload_never_loads_anything() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start_bare();
    let (code, env) = etm_env(&d, &[], &["--no-autoload", "ws", "ls"]);
    assert_eq!(code, 1, "{env}");
    assert_eq!(env["errors"][0]["code"], "transport.emacs_error");
    assert!(s(&env["errors"][0]["msg"]).contains("not loaded"));
    assert_eq!(d.emacsclient("(fboundp 'etm-rpc)").as_deref(), Some("nil"));
}

#[test]
fn install_elisp_writes_the_package_without_emacs() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("site-lisp/etm");
    let out = Command::new(env!("CARGO_BIN_EXE_etm"))
        .args(["--socket", "/nonexistent/socket", "install-elisp"])
        .arg(&target)
        .output()
        .expect("run etm");
    let env: Value = serde_json::from_slice(&out.stdout).expect("JSON");
    assert_eq!(out.status.code(), Some(0), "{env}");
    assert_eq!(env["verb"], "install-elisp");
    let files = env["data"]["files"].as_array().unwrap();
    assert_eq!(files.len(), etm::elisp::FILES.len());
    for (name, text) in etm::elisp::FILES {
        assert_eq!(
            std::fs::read_to_string(target.join(name)).unwrap(),
            *text,
            "{name}"
        );
    }
}

//! End-to-end: the shared global flag set (workspace_cli) on the `etm`
//! binary against a throwaway Emacs (tests/support.rs): the flag table in
//! `capabilities`, paging with `next_offset`, every output format, the
//! deprecated spellings, and `--dry-run` never reaching Emacs. Skips when
//! `emacs` isn't installed; the no-Emacs cases run regardless.

use serde_json::{json, Value};
use std::process::Command;

mod support;
use support::{have_emacs, Daemon};

/// etm with no Emacs anywhere: a socket path that cannot exist.
fn etm_offline(args: &[&str]) -> (i32, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_etm"))
        .args(["--socket", "/nonexistent/etm-flags-test/s", "--no-autoload"])
        .args(args)
        .output()
        .expect("run etm");
    let code = out.status.code().unwrap_or(-1);
    (code, String::from_utf8_lossy(&out.stdout).into_owned())
}

fn json_of(stdout: &str) -> Value {
    serde_json::from_str(stdout.trim()).unwrap_or_else(|e| panic!("not JSON ({e}): {stdout}"))
}

#[test]
fn help_points_at_the_info_manual() {
    for flag in ["--help", "help"] {
        let (code, out) = etm_offline(&[flag]);
        assert_eq!(code, 0, "{out}");
        assert!(out.contains("info etm"), "{out}");
    }
}

#[test]
fn dry_run_previews_without_any_emacs() {
    let (code, out) = etm_offline(&["pane", "kill", "w/a", "--dry-run", "--json"]);
    assert_eq!(code, 0, "{out}");
    let env = json_of(&out);
    assert_eq!(
        env["data"],
        json!({"dry_run": true, "request": {"verb": "pane.kill", "args": {"addr": "w/a"}}})
    );
    // Without --dry-run the same call needs Emacs: exit 5.
    let (code, _) = etm_offline(&["pane", "kill", "w/a", "--json"]);
    assert_eq!(code, 5);
}

#[test]
fn deprecated_format_spellings_warn_in_the_envelope() {
    for (old, starts) in [
        ("json", "{\"schema\""),
        ("pretty", "{\n"),
        ("compact", "schema: etm.result/1"),
    ] {
        let (code, out) = etm_offline(&["--format", old, "ws", "ls", "--dry-run"]);
        assert_eq!(code, 0, "{old}: {out}");
        assert!(out.starts_with(starts), "{old}: {out}");
        assert!(out.contains("flag.deprecated"), "{old}: {out}");
    }
    let (code, out) = etm_offline(&["--format", "yaml", "ws", "ls", "--json"]);
    assert_eq!(code, 2, "{out}");
    assert_eq!(json_of(&out)["errors"][0]["code"], "usage.argv");
}

#[test]
fn usage_errors_honor_the_requested_format() {
    let (code, out) = etm_offline(&["--robot-format=toon", "ws", "ls", "--limit", "0"]);
    assert_eq!(code, 2);
    assert!(
        out.starts_with("schema: etm.result/1\nok: false\n"),
        "{out}"
    );
}

#[test]
fn capabilities_list_the_shared_global_flags() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    let caps = d.ok(&["capabilities"]);
    assert_eq!(caps["global_flags"], workspace_cli::globals::capabilities());
    assert_eq!(
        caps["modifiers"]["ws.ls"],
        json!(["limit", "offset", "dry_run"])
    );
    assert_eq!(
        caps["verbs"][0]["verb"], "snapshot",
        "Emacs's own answer is kept"
    );
}

#[test]
fn lists_page_and_every_format_renders() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    // `emacs -Q` has one global workspace (no persp-mode): page its panes.
    for key in ["p1", "p2", "p3"] {
        d.ok(&[
            "pane", "new", "global", key, "--kind", "editor", "--path", "/tmp",
        ]);
    }
    let all = d.ok(&["pane", "ls", "global"]);
    let total = all.as_array().unwrap().len();
    assert!(total >= 3, "{all}");
    let (code, env) = d.etm(&["pane", "ls", "global", "--limit", "2", "--json"]);
    assert_eq!(code, 0, "{env}");
    assert_eq!(env["data"]["items"].as_array().unwrap().len(), 2);
    assert_eq!(env["data"]["next_offset"], 2);
    assert_eq!(env["next"][0], "etm pane ls global --offset 2 --limit 2");
    let tail = d.ok(&[
        "pane",
        "ls",
        "global",
        "--robot-offset",
        "2",
        "--robot-limit",
        "100",
    ]);
    assert_eq!(tail["items"].as_array().unwrap().len(), total - 2);
    assert_eq!(tail["next_offset"], Value::Null);
    let ws = d.ok(&["ws", "ls", "--limit", "1"]);
    assert_eq!(
        (ws["items"].as_array().unwrap().len(), &ws["next_offset"]),
        (1, &Value::Null)
    );
    let ev = d.ok(&["events", "--limit", "1"]);
    assert_eq!(ev["events"].as_array().unwrap().len(), 1);
    assert_eq!(ev["next_offset"], 1);

    let (code, toon) = d.raw(&[
        "pane",
        "ls",
        "global",
        "--robot-format=toon",
        "--fields",
        "key,kind",
    ]);
    assert_eq!(code, 0, "{toon}");
    assert!(
        toon.contains(&format!("data[{total}]{{key,kind}}:\n")),
        "{toon}"
    );
    assert!(toon.contains("  p1,editor\n"), "{toon}");
    let (_, md) = d.raw(&[
        "pane",
        "ls",
        "global",
        "--robot-markdown",
        "--fields",
        "key",
    ]);
    assert!(md.starts_with("## etm pane.ls: ok\n"), "{md}");
    assert!(md.contains("\n| key |\n| --- |\n| p1 |\n"), "{md}");
    let (_, brief) = d.raw(&["pane", "ls", "global", "--brief", "--json"]);
    assert_eq!(json_of(&brief)["data"], json!({"count": total}));
    let (code, ignored) = d.etm(&["doctor", "--limit", "3", "--no-color", "--verbose"]);
    assert_eq!(code, 0, "{ignored}");
    assert!(
        ignored["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|w| w["code"] == "flag.ignored"),
        "{ignored}"
    );
}

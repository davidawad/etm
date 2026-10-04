//! End-to-end: the `etm` binary against a throwaway `emacs -Q
//! --daemon=<unique socket>` that has NOT loaded etm -- the CLI's
//! autoload brings it in on the first call, exactly as against a real
//! session. Each test owns its daemon (HOME and the socket live in a
//! private 0700 tempdir) and kills it on drop. Skips when `emacs` isn't
//! installed.

use serde_json::json;

mod support;
use support::{have_emacs, s, Daemon};

#[test]
fn capabilities_lists_the_closed_verb_table() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    let caps = d.ok(&["capabilities"]);
    let verbs: Vec<&str> = caps["verbs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| s(&v["verb"]))
        .collect();
    assert_eq!(
        verbs,
        [
            "snapshot",
            "capabilities",
            "ws.ls",
            "ws.get",
            "ws.new",
            "ws.switch",
            "ws.rename",
            "ws.kill",
            "pane.ls",
            "pane.new",
            "pane.kill",
            "pane.focus",
            "send",
            "capture",
            "wait",
            "doctor",
            "events",
            "eval"
        ]
    );
    assert_eq!(caps["workspaces"], "single");
    let ws = d.ok(&["ws", "ls"]);
    assert_eq!(
        ws,
        json!([{"name": "global", "id": "global", "current": true, "managed": false,
                           "subject": null, "tag": null, "spec": null, "owner": null,
                           "root": null, "panes": 0}])
    );
}

#[test]
fn shell_pane_send_wait_capture_with_cursors() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    let dir = d.dir.path().display().to_string();
    let pane = d.ok(&[
        "pane", "new", "global", "sh", "--kind", "shell", "--path", &dir,
    ]);
    assert_eq!(pane["addr"], "global/sh");
    assert_eq!(pane["mode"], "eshell-mode");
    assert_eq!(pane["created"], true);

    let sent = d.ok(&["send", "global/sh", "echo alpha-beta héllo ✓", "--enter"]);
    let c0 = s(&sent["cursor"]).to_string();
    let hit = d.ok(&[
        "wait",
        "global/sh",
        "--until",
        "match:alpha-beta h",
        "--since",
        &c0,
        "--timeout",
        "10",
    ]);
    assert_eq!(hit["match"], "alpha-beta h");

    let first = d.ok(&["capture", "global/sh", "--since", &c0]);
    assert!(
        s(&first["text"]).contains("alpha-beta héllo ✓\n"),
        "{first}"
    );
    let c1 = s(&first["cursor"]).to_string();
    let idle = d.ok(&[
        "wait",
        "global/sh",
        "--until",
        "idle",
        "--idle-ms",
        "200",
        "--timeout",
        "10",
    ]);
    assert!(idle["idle_ms"].as_u64().unwrap() >= 200, "{idle}");
    let again = d.ok(&["capture", "global/sh", "--since", &c1]);
    assert_eq!(again["text"], "", "a second read returns only what is new");

    d.ok(&["send", "global/sh", "echo gamma", "--enter"]);
    d.ok(&[
        "wait",
        "global/sh",
        "--until",
        "match:^gamma$",
        "--since",
        &c1,
        "--timeout",
        "10",
    ]);
    let delta = d.ok(&["capture", "global/sh", "--since", &c1]);
    assert!(
        s(&delta["text"]).contains("gamma") && !s(&delta["text"]).contains("alpha"),
        "{delta}"
    );

    let (_, stale) = d.etm(&["capture", "global/sh", "--since", "c1:0000:5"]);
    assert_eq!(stale["warnings"][0]["code"], "capture.cursor_reset");
}

#[test]
fn cmd_pane_exit_status_and_large_capture() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    d.ok(&[
        "pane",
        "new",
        "global",
        "job",
        "--kind",
        "cmd",
        "--cmd",
        "seq 1 3000; exit 3",
    ]);
    let done = d.ok(&["wait", "global/job", "--until", "exit", "--timeout", "10"]);
    assert_eq!(done["exit_status"], 3);
    let cap = d.ok(&["capture", "global/job"]);
    let text = s(&cap["text"]);
    assert!(
        text.len() > 10_000 && text.contains("\n2999\n3000\n"),
        "chunked -print-nonl reply reassembles"
    );
    let tail = d.ok(&["capture", "global/job", "--lines", "3"]);
    assert!(s(&tail["text"]).lines().count() <= 3);
}

#[test]
fn typed_errors_map_to_exit_codes() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    let (code, env) = d.etm(&["capture", "global/missing"]);
    assert_eq!((code, s(&env["errors"][0]["code"])), (3, "not_found.pane"));
    let (code, env) = d.etm(&["capture", "nowhere/x"]);
    assert_eq!(
        (code, s(&env["errors"][0]["code"])),
        (3, "not_found.workspace")
    );
    let (code, env) = d.etm(&["pane", "new", "global", "bad*key", "--kind", "shell"]);
    assert_eq!((code, s(&env["errors"][0]["code"])), (2, "usage.bad_arg"));
    let (code, env) = d.etm(&["pane", "new", "global", "p", "--kind", "agent"]);
    assert_eq!(
        (code, s(&env["errors"][0]["code"])),
        (1, "capability.unsupported_kind")
    );
    // A page this Emacs has not loaded is unavailable, never a void-function.
    let (code, env) = d.etm(&[
        "pane",
        "new",
        "global",
        "p",
        "--kind",
        "page",
        "--page",
        "no-such-board",
    ]);
    assert_eq!(
        (code, s(&env["errors"][0]["code"])),
        (1, "capability.unavailable")
    );
    let (code, env) = d.etm(&["frobnicate"]);
    assert_eq!((code, s(&env["errors"][0]["code"])), (2, "usage.argv"));
    let (code, env) = d.etm(&["ws", "new", "client:x"]);
    assert_eq!(
        (code, s(&env["errors"][0]["code"])),
        (1, "capability.unavailable")
    );
    d.ok(&["pane", "new", "global", "sh", "--kind", "shell"]);
    let (code, env) = d.etm(&[
        "wait",
        "global/sh",
        "--until",
        "match:never-here",
        "--timeout",
        "0.3",
    ]);
    assert_eq!((code, s(&env["errors"][0]["code"])), (7, "wait.timeout"));
    assert_eq!(env["errors"][0]["retryable"], true);
    let (code, env) = d.etm(&[
        "--socket",
        "/tmp/etm-no-such-dir/s",
        "--transport",
        "socket",
        "ws",
        "ls",
    ]);
    assert_eq!(
        (code, s(&env["errors"][0]["code"])),
        (5, "driver.unreachable")
    );
}

#[test]
fn pane_new_is_idempotent_and_kill_reaps() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    let rev0 = d.etm(&["pane", "ls"]).1["rev"].clone();
    assert_eq!(
        d.ok(&["pane", "new", "global", "sh", "--kind", "shell"])["created"],
        true
    );
    assert_eq!(
        d.ok(&["pane", "new", "global", "sh", "--kind", "shell"])["created"],
        false
    );
    let (code, env) = d.etm(&[
        "pane", "new", "global", "sh", "--kind", "cmd", "--cmd", "true",
    ]);
    assert_eq!(
        (code, s(&env["errors"][0]["code"])),
        (1, "conflict.kind_mismatch")
    );
    let (_, ls) = d.etm(&["pane", "ls"]);
    assert_ne!(ls["rev"], rev0, "rev tracks the observed state");
    assert_eq!(ls["data"].as_array().unwrap().len(), 1);
    d.ok(&["pane", "kill", "global/sh"]);
    assert_eq!(d.ok(&["pane", "ls"]), json!([]));
    assert_eq!(d.etm(&["pane", "ls"]).1["rev"], rev0);
}

#[test]
fn region_docks_in_a_side_window_and_snapshot_sees_it() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    let (code, env) = d.etm(&[
        "pane", "new", "global", "log", "--kind", "cmd", "--cmd", "echo hi", "--region", "right",
    ]);
    assert_eq!(code, 0, "{env}");
    assert_eq!(env["warnings"], json!([]), "docked without degradation");
    assert_eq!(env["data"]["visible"], true);
    let snap = d.ok(&["snapshot"]);
    let windows = snap["windows"].as_array().unwrap();
    assert!(
        windows
            .iter()
            .any(|w| w["pane"] == "log" && w["side"] == "right" && w["slot"] == 0),
        "{snap}"
    );
    assert_eq!(snap["panes"][0]["addr"], "global/log");
    let cut = d.ok(&["snapshot", "--fields", "current"]);
    assert_eq!(cut, json!({"current": "global"}));
}

#[test]
fn events_doctor_and_eval_escape_hatch() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    let (_, env) = d.etm(&["ws", "ls"]);
    let mark = s(&env["events"][0]).to_string();
    assert!(mark.starts_with("ev_"), "every call cites its event: {env}");
    d.ok(&["capabilities"]);
    let ev = d.ok(&["events", "--since", &mark]);
    let msgs: Vec<&str> = ev["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| s(&e["message"]))
        .collect();
    assert!(
        msgs.iter().any(|m| m.starts_with("capabilities ok")),
        "{msgs:?}"
    );
    assert!(
        !msgs.iter().any(|m| m.starts_with("ws.ls")),
        "since is exclusive: {msgs:?}"
    );

    let doc = d.ok(&["doctor"]);
    assert_eq!(doc["healthy"], true, "{doc}");

    let (code, env) = d.etm(&["eval", "(+ 1 2)"]);
    assert_eq!(code, 0);
    assert_eq!(env["data"]["value"], "3");
    assert_eq!(env["warnings"][0]["code"], "eval.escape_hatch");
    assert_eq!(env["next"], json!([]), "eval is never offered in next");
}

#[test]
fn emacsclient_fallback_transport() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    let (code, env) = d.etm(&[
        "--transport",
        "emacsclient",
        "capabilities",
        "--fields",
        "surface",
    ]);
    assert_eq!(code, 0, "{env}");
    assert_eq!(env["data"], json!({"surface": "emacs"}));
}

/// The R1 bench gate: one snapshot round trip under 30 ms locally
/// Gated on the median; p95 and max are
/// printed for the record (`cargo test -p etm -- --nocapture`).
#[test]
fn snapshot_round_trip_bench_gate() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    let client = d.client();
    client.bench(5).expect("warm-up");
    let ms = client.bench(100).expect("bench");
    let (p50, p95, max) = (
        etm::client::quantile(&ms, 0.5),
        etm::client::quantile(&ms, 0.95),
        ms[ms.len() - 1],
    );
    eprintln!("etm snapshot round trip (n=100): p50 {p50:.2} ms, p95 {p95:.2} ms, max {max:.2} ms");
    let budget: f64 = std::env::var("ETM_BENCH_BUDGET_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(30.0);
    assert!(
        p50 < budget,
        "snapshot p50 {p50:.2} ms over the {budget} ms budget"
    );
}

/// A verb Emacs takes seconds over (a page render on a real session)
/// still answers: seconds of silence on the socket are waiting, not a
/// broken transport. Past `--io-timeout` the call ends with the typed
/// `transport.timeout`, and the daemon stays usable.
#[test]
fn slow_verbs_wait_up_to_the_io_timeout() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    let t = std::time::Instant::now();
    let (code, env) = d.etm(&[
        "--io-timeout",
        "6",
        "eval",
        "(progn (sleep-for 2) 'rendered)",
    ]);
    assert_eq!(
        (code, &env["data"]["value"]),
        (0, &json!("rendered")),
        "{env}"
    );
    assert!(t.elapsed().as_secs_f64() >= 2.0);

    let t = std::time::Instant::now();
    let (code, env) = d.etm(&["--io-timeout", "1", "eval", "(sleep-for 3)"]);
    let waited = t.elapsed().as_secs_f64();
    assert_eq!(
        (code, s(&env["errors"][0]["code"])),
        (1, "transport.timeout"),
        "{env}"
    );
    assert_eq!(env["errors"][0]["retryable"], true);
    assert!((1.0..2.5).contains(&waited), "gave up after {waited:.2}s");

    std::thread::sleep(std::time::Duration::from_secs(3));
    d.ok(&["capabilities"]);
}

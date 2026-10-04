//! Found driving a real, heavily configured daemon, replayed against
//! throwaway `emacs -Q --daemon`s:
//!
//! - the first call into an Emacs that hasn't loaded etm loads it, and
//!   that load may take longer than a caller's 2 s read budget; it gets the
//!   load budget instead of failing as `transport.timeout`;
//! - a page pane whose render sleeps (a synchronous fetch) used to run in
//!   server.el's filter and hold every other client off; one that prompted
//!   wedged the daemon for good. The server now answers `emacsclient`
//!   while the page renders, and a prompting page fails instead.

use serde_json::{json, Value};
use std::time::{Duration, Instant};

mod support;
use support::{have_emacs, rpc_el, s, Daemon};

fn pane(d: &Daemon, addr: &str) -> Value {
    let panes = d.ok(&["pane", "ls", "--all"]);
    panes
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["addr"] == addr)
        .cloned()
        .unwrap_or_else(|| panic!("no pane {addr}: {panes}"))
}

/// Poll ADDR until its `page_state` leaves "rendering" (at most 15 s).
fn settled(d: &Daemon, addr: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let p = pane(d, addr);
        if p["page_state"] != "rendering" || Instant::now() > deadline {
            return p;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn doctor_row(d: &Daemon, check: &str) -> Value {
    let doc = d.ok(&["doctor"]);
    doc["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["check"] == check)
        .cloned()
        .unwrap_or_else(|| panic!("no doctor row {check}: {doc}"))
}

#[test]
fn first_call_autoload_gets_the_load_budget() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start_bare();
    // An etm.el that takes 3 s to load, like a fresh, heavily configured session still busy
    // with its deferred packages.
    let slow = d.dir.path().join("slow-etm.el");
    std::fs::write(
        &slow,
        format!(
            "(sleep-for 3)\n(add-to-list 'load-path {:?})\n(load {:?} nil t)\n",
            rpc_el().parent().unwrap(),
            rpc_el()
        ),
    )
    .unwrap();
    let client = etm::Client::new(etm::Config {
        socket: Some(d.socket()),
        mode: etm::TransportMode::Socket,
        rpc_el: Some(slow),
        io_timeout: Duration::from_secs(1),
        ..etm::Config::default()
    });
    let t = Instant::now();
    let env = client.call("snapshot", json!({}));
    assert_eq!(env["ok"], true, "{env}");
    assert!(t.elapsed() >= Duration::from_secs(3));
    // Loaded now: the next call is one plain round trip.
    let t = Instant::now();
    assert_eq!(client.call("snapshot", json!({}))["ok"], true);
    assert!(t.elapsed() < Duration::from_secs(1), "{:?}", t.elapsed());
}

#[test]
fn no_autoload_against_an_unloaded_emacs_says_so() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start_bare();
    let client = etm::Client::new(etm::Config {
        socket: Some(d.socket()),
        mode: etm::TransportMode::Socket,
        rpc_el: None,
        discover: false,
        ..etm::Config::default()
    });
    let env = client.call("snapshot", json!({}));
    assert_eq!(env["errors"][0]["code"], "transport.emacs_error", "{env}");
    assert!(s(&env["errors"][0]["msg"]).contains("not loaded"), "{env}");
}

#[test]
fn server_answers_while_a_slow_page_renders() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    d.ok(&[
        "eval",
        "(defun etm-slow-page () (interactive) (sleep-for 4) \
         (switch-to-buffer (get-buffer-create \"*slow*\")))",
    ]);
    let t = Instant::now();
    let made = d.ok(&[
        "pane",
        "new",
        "global",
        "slow",
        "--kind",
        "page",
        "--page",
        "etm-slow-page",
    ]);
    assert!(t.elapsed() < Duration::from_secs(2), "{:?}", t.elapsed());
    assert_eq!(made["page_state"], "rendering", "{made}");

    // Mid-render: a plain emacsclient and etm both answer at once.
    std::thread::sleep(Duration::from_millis(500));
    let t = Instant::now();
    assert_eq!(d.emacsclient("(+ 1 2)").as_deref(), Some("3"));
    assert!(t.elapsed() < Duration::from_secs(1), "{:?}", t.elapsed());
    assert_eq!(doctor_row(&d, "etm.pages")["status"], "pass");
    assert_eq!(pane(&d, "global/slow")["page_state"], "rendering");

    let done = settled(&d, "global/slow");
    assert_eq!(
        (s(&done["page_state"]), s(&done["buffer"])),
        ("ready", "*slow*"),
        "{done}"
    );
    assert!(done["page_ms"].as_u64().unwrap() >= 4000, "{done}");
    // Slower than a 2 s read budget: the doctor names it.
    let row = doctor_row(&d, "etm.pages-responsive");
    assert_eq!(row["status"], "fail", "{row}");
    assert!(s(&row["hint"]).contains("etm-slow-page"), "{row}");
}

#[test]
fn a_page_that_prompts_fails_and_the_server_lives() {
    if !have_emacs() {
        return;
    }
    let d = Daemon::start();
    d.ok(&[
        "eval",
        "(defun etm-prompt-page (key) \
         (interactive (list (completing-read \"KPI project: \" '(\"a\") nil t))) \
         (switch-to-buffer (get-buffer-create key)))",
    ]);
    d.ok(&[
        "pane",
        "new",
        "global",
        "kpi",
        "--kind",
        "page",
        "--page",
        "etm-prompt-page",
    ]);
    let done = settled(&d, "global/kpi");
    assert_eq!(done["page_state"], "failed", "{done}");
    assert_eq!(done["page_error"], "page.needs_input", "{done}");
    assert_eq!(d.emacsclient("t").as_deref(), Some("t"));
    let row = doctor_row(&d, "etm.pages");
    assert_eq!(row["status"], "fail", "{row}");
    assert!(s(&row["hint"]).contains("page.needs_input"), "{row}");
}

use super::*;

fn p(args: &[&str]) -> Result<Invocation, Usage> {
    let argv: Vec<String> = args.iter().map(|s| (*s).to_string()).collect();
    parse(&argv, &mut || Ok("from-stdin".to_string()))
}

fn action(args: &[&str]) -> Action {
    p(args).expect("parses").action
}

#[test]
fn verbs_map_to_requests() {
    assert_eq!(action(&["ws", "ls"]), call("ws.ls", json!({})));
    assert_eq!(
        action(&[
            "ws",
            "new",
            "client:x",
            "--subject",
            "client:x",
            "--switch",
            "--spec",
            "b3:1",
            "--owner",
            "me",
            "--adopt",
            "hand"
        ]),
        call(
            "ws.new",
            json!({"ws": "client:x", "subject": "client:x", "switch": true, "spec": "b3:1", "owner": "me", "adopt": "hand"})
        )
    );
    assert_eq!(
        action(&["pane", "ls", "--all"]),
        call("pane.ls", json!({"ws": "*"}))
    );
    assert_eq!(
        action(&["send", "w/sh", "ls -la", "--enter"]),
        call(
            "send",
            json!({"addr": "w/sh", "text": "ls -la", "enter": true})
        )
    );
    assert_eq!(
        action(&["send", "w/sh", "-"]),
        call(
            "send",
            json!({"addr": "w/sh", "text": "from-stdin", "enter": false})
        )
    );
    assert_eq!(
        action(&["capture", "w/sh", "--since=c1:ab:3", "--lines", "5"]),
        call(
            "capture",
            json!({"addr": "w/sh", "since": "c1:ab:3", "lines": 5, "max_chars": null})
        )
    );
    assert_eq!(
        action(&["events", "--since", "ev_1"])["since"],
        json!("ev_1")
    );
}

impl std::ops::Index<&str> for Action {
    type Output = Value;
    fn index(&self, k: &str) -> &Value {
        match self {
            Action::Call { args, .. } | Action::Wait { args, .. } => &args[k],
            _ => &Value::Null,
        }
    }
}

#[test]
fn wait_carries_timing() {
    match action(&[
        "wait",
        "a/b",
        "--until",
        "match:ok",
        "--timeout",
        "2",
        "--poll-ms",
        "50",
    ]) {
        Action::Wait {
            args,
            timeout,
            poll,
        } => {
            assert_eq!(args["until"], "match:ok");
            assert_eq!(timeout, Duration::from_secs(2));
            assert_eq!(poll, Duration::from_millis(50));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn globals_and_fields() {
    let inv = p(&[
        "-s",
        "/tmp/s",
        "--transport",
        "socket",
        "--fields",
        "addr,key",
        "pane",
        "ls",
    ])
    .unwrap();
    assert_eq!(inv.socket.as_deref(), Some("/tmp/s"));
    assert_eq!(inv.transport, Some(TransportMode::Socket));
    assert_eq!(inv.globals.fields, vec!["addr", "key"]);
    let inv = p(&["snapshot", "--fields", "current,panes", "-s", "x"]).unwrap();
    assert_eq!(inv.globals.fields, vec!["current", "panes"]);
    assert_eq!(inv.socket.as_deref(), Some("x"));
    assert_eq!(
        inv.action,
        call("snapshot", json!({"fields": ["current", "panes"]}))
    );
    let inv = p(&["send", "a/b", "--", "-s"]).unwrap();
    assert_eq!(
        inv.action,
        call("send", json!({"addr": "a/b", "text": "-s", "enter": false}))
    );
}

#[test]
fn usage_errors() {
    assert!(p(&["nope"]).is_err());
    assert!(p(&["ws"]).is_err());
    assert!(p(&["pane", "new", "w", "k"]).is_err());
    assert!(p(&["wait", "a/b"]).is_err());
    assert!(p(&["send", "a/b", "x", "--bogus"]).is_err());
    assert!(p(&["capture", "a/b", "--enter"]).is_err());
    assert!(p(&["capture", "a/b", "--lines", "x"]).is_err());
    assert_eq!(action(&[]), Action::Help);
}

#[test]
fn shared_modifiers_feed_the_verbs() {
    assert_eq!(
        action(&["events", "--since", "12.5", "--limit", "5", "--offset", "2"]),
        call("events", json!({"since": 12.5, "limit": 7}))
    );
    assert_eq!(action(&["events"])["limit"], json!(EVENTS_LIMIT));
    match action(&[
        "wait",
        "a/b",
        "--until",
        "idle",
        "--timeout",
        "500ms",
        "--since",
        "c1",
    ]) {
        Action::Wait { args, timeout, .. } => {
            assert_eq!(timeout, Duration::from_millis(500));
            assert_eq!(args["since"], "c1");
        }
        other => panic!("{other:?}"),
    }
    match action(&["--timeout=2m", "wait", "a/b", "--until", "exit"]) {
        Action::Wait { timeout, .. } => assert_eq!(timeout, Duration::from_secs(120)),
        other => panic!("{other:?}"),
    }
    let inv = p(&[
        "--robot-limit",
        "3",
        "ws",
        "ls",
        "--robot-offset=1",
        "--dry-run",
    ])
    .unwrap();
    assert_eq!(inv.action, call("ws.ls", json!({})));
    assert_eq!(
        (inv.globals.limit, inv.globals.offset, inv.globals.dry_run),
        (Some(3), Some(1), true)
    );
}

#[test]
fn output_flags_and_deprecated_aliases() {
    use workspace_cli::OutputFormat;
    for (args, want) in [
        (&["--json", "ws", "ls"][..], OutputFormat::Json),
        (&["ws", "ls", "--robot-format=toon"][..], OutputFormat::Toon),
        (
            &["ws", "ls", "--robot-format", "markdown"][..],
            OutputFormat::Markdown,
        ),
        (
            &["--robot-markdown", "ws", "ls"][..],
            OutputFormat::Markdown,
        ),
        (
            &["--robot-format", "text", "ws", "ls"][..],
            OutputFormat::Text,
        ),
    ] {
        let inv = p(args).unwrap();
        assert_eq!(inv.globals.format, Some(want), "{args:?}");
        assert!(inv.globals.notices.is_empty(), "{args:?}");
    }
    for (old, want, use_) in [
        ("json", OutputFormat::Json, "--json"),
        ("pretty", OutputFormat::Text, "--robot-format=text"),
        ("compact", OutputFormat::Toon, "--robot-format=toon"),
        ("text", OutputFormat::Text, "--robot-format=text"),
    ] {
        let inv = p(&["--format", old, "pane", "ls"]).unwrap();
        assert_eq!(inv.globals.format, Some(want), "{old}");
        assert_eq!(inv.globals.notices[0].code, "flag.deprecated");
        assert_eq!(inv.globals.notices[0].hint.as_deref(), Some(use_));
    }
    assert!(p(&["--format", "yaml", "ws", "ls"]).is_err());
    assert!(p(&["--limit", "0", "ws", "ls"]).is_err());
    let inv = p(&["--brief", "--verbose", "--no-color", "doctor"]).unwrap();
    assert!(inv.globals.brief && inv.globals.verbose && inv.globals.no_color);
}

#[test]
fn every_verb_honors_dry_run_and_lists_its_modifiers() {
    assert_eq!(modifiers("ws.ls"), ["limit", "offset", "dry_run"]);
    assert_eq!(modifiers("wait"), ["since", "timeout", "dry_run"]);
    assert_eq!(modifiers("pane.kill"), ["dry_run"]);
}

#[test]
fn install_elisp_and_the_path_guard() {
    assert_eq!(
        action(&["install-elisp", "/tmp/etm-lisp"]),
        Action::InstallElisp {
            dir: PathBuf::from("/tmp/etm-lisp")
        }
    );
    assert!(p(&["install-elisp"]).is_err());
    let argv: Vec<String> = [
        "pane", "new", "w", "k", "--kind", "shell", "--path", "/no/go",
    ]
    .iter()
    .map(|s| (*s).to_string())
    .collect();
    let guard = |p: &str| p.starts_with("/no").then(|| format!("{p} is off limits"));
    let err = parse_with(&argv, &mut || Ok(String::new()), Some(&guard)).unwrap_err();
    assert_eq!(err.msg, "/no/go is off limits");
    assert!(parse(&argv, &mut || Ok(String::new())).is_ok());
}

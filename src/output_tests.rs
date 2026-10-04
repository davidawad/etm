use super::*;
use crate::cli::parse;

fn inv(args: &[&str]) -> Invocation {
    let argv: Vec<String> = args.iter().map(|s| (*s).to_string()).collect();
    parse(&argv, &mut || Ok(String::new())).unwrap()
}

fn ok_env(verb: &str, data: Value) -> Value {
    json!({"schema": envelope::SCHEMA, "ok": true, "verb": verb, "data": data,
           "rev": null, "warnings": [], "errors": [], "next": ["etm pane ls"], "events": []})
}

fn shaped(args: &[&str], verb: &str, data: Value) -> Value {
    let mut env = ok_env(verb, data);
    shape(&mut env, &inv(args));
    assert_eq!(envelope::validate(&env), Ok(()));
    env
}

fn workspaces(n: usize) -> Value {
    json!((0..n)
        .map(|i| json!({"id": format!("w{i}"), "panes": i}))
        .collect::<Vec<_>>())
}

#[test]
fn list_verbs_page_with_next_offset() {
    let env = shaped(&["ws", "ls", "--limit", "2"], "ws.ls", workspaces(5));
    assert_eq!(
        env["data"]["items"],
        json!([{"id": "w0", "panes": 0}, {"id": "w1", "panes": 1}])
    );
    assert_eq!(env["data"]["next_offset"], 2);
    assert_eq!(env["data"]["pagination"]["total"], 5);
    assert_eq!(env["next"][0], "etm ws ls --offset 2 --limit 2");
    let last = shaped(
        &["ws", "ls", "--limit", "2", "--offset", "4"],
        "ws.ls",
        workspaces(5),
    );
    assert_eq!(
        (
            last["data"]["items"].as_array().unwrap().len(),
            &last["data"]["next_offset"]
        ),
        (1, &Value::Null)
    );
    assert_eq!(last["next"], json!(["etm pane ls"]));
    let all = shaped(
        &["pane", "ls", "--all", "--offset", "1", "--limit", "1"],
        "pane.ls",
        workspaces(3),
    );
    assert_eq!(all["next"][0], "etm pane ls --all --offset 2 --limit 1");
    let one = shaped(
        &["pane", "ls", "w", "--limit", "1"],
        "pane.ls",
        workspaces(3),
    );
    assert_eq!(one["next"][0], "etm pane ls w --offset 1 --limit 1");
    // Without paging flags a list stays a list (the pre-flag shape).
    assert_eq!(
        shaped(&["ws", "ls"], "ws.ls", workspaces(2))["data"],
        workspaces(2)
    );
}

#[test]
fn events_page_from_the_newest_end() {
    let ring = |ids: &[&str], dropped: u64| {
        json!({"events": ids.iter().map(|i| json!({"id": i})).collect::<Vec<_>>(),
               "dropped": dropped, "next_since": ids.last()})
    };
    // --limit 2 --offset 1 asked Emacs for the newest 3 of 6.
    let env = shaped(
        &["events", "--limit", "2", "--offset", "1"],
        "events",
        ring(&["e4", "e5", "e6"], 3),
    );
    let d = &env["data"];
    assert_eq!(d["events"], json!([{"id": "e4"}, {"id": "e5"}]));
    assert_eq!(
        (d["next_offset"].clone(), d["dropped"].clone()),
        (json!(3), json!(3))
    );
    assert_eq!(d["next_since"], "e5");
    assert_eq!(
        d["pagination"],
        json!({"limit": 2, "offset": 1, "count": 2, "total": 6, "has_more": true})
    );
    assert_eq!(env["next"][0], "etm events --offset 3 --limit 2");
    let all = shaped(&["events", "--since", "e0"], "events", ring(&["e1"], 0));
    assert_eq!(all["data"]["next_offset"], Value::Null);
    assert_eq!(all["data"]["pagination"]["limit"], cli::EVENTS_LIMIT);
}

#[test]
fn notices_become_warnings() {
    let env = shaped(
        &["--format", "compact", "--limit", "3", "doctor"],
        "doctor",
        json!({}),
    );
    let codes: Vec<&str> = env["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["code"].as_str().unwrap())
        .collect();
    assert_eq!(codes, ["flag.deprecated", "flag.ignored"]);
    assert_eq!(env["warnings"][0]["hint"], "--robot-format=toon");
    assert_eq!(
        env["warnings"][1]["msg"],
        "--limit does not apply to `doctor`; ignored"
    );
}

#[test]
fn capabilities_carry_the_shared_flag_table() {
    let env = shaped(&["capabilities"], "capabilities", json!({"verbs": []}));
    assert_eq!(
        env["data"]["global_flags"],
        workspace_cli::globals::capabilities()
    );
    assert_eq!(
        env["data"]["modifiers"]["events"],
        json!(["limit", "offset", "since", "dry_run"])
    );
    assert_eq!(env["data"]["tool_flags"][0]["flag"], "--socket");
    assert_eq!(env["data"]["verbs"], json!([]));
}

#[test]
fn dry_run_shows_the_request_and_sends_nothing() {
    let i = inv(&["pane", "kill", "w/a", "--dry-run"]);
    let mut env = dry_run(&i.action);
    shape(&mut env, &i);
    assert_eq!(envelope::validate(&env), Ok(()));
    assert_eq!(env["verb"], "pane.kill");
    assert_eq!(
        env["data"],
        json!({"dry_run": true, "request": {"verb": "pane.kill", "args": {"addr": "w/a"}}})
    );
    assert_eq!(env["warnings"], json!([]));
    let w = inv(&[
        "wait",
        "w/a",
        "--until",
        "idle",
        "--timeout",
        "3",
        "--dry-run",
    ]);
    assert_eq!(dry_run(&w.action)["data"]["request"]["timeout_s"], 3.0);
}

#[test]
fn fields_and_brief_apply_after_paging() {
    let env = shaped(
        &["ws", "ls", "--limit", "1", "--fields", "id"],
        "ws.ls",
        workspaces(2),
    );
    assert_eq!(env["data"]["items"], json!([{"id": "w0"}]));
    assert_eq!(env["data"]["next_offset"], 1);
    let env = shaped(&["ws", "ls", "--brief"], "ws.ls", workspaces(4));
    assert_eq!(env["data"], json!({"count": 4}));
}

#[test]
fn toon_markdown_and_text_render_the_envelope() {
    let env = shaped(&["pane", "ls", "--limit", "2"], "pane.ls", workspaces(3));
    let toon = render(&env, OutputFormat::Toon);
    assert!(
        toon.contains("  items[2]{id,panes}:\n    w0,0\n    w1,1\n"),
        "{toon}"
    );
    assert!(toon.contains("  next_offset: 2"), "{toon}");
    let md = render(&env, OutputFormat::Markdown);
    assert!(md.starts_with("## etm pane.ls: ok\n"), "{md}");
    assert!(
        md.contains("| id | panes |\n| --- | --- |\n| w0 | 0 |\n"),
        "{md}"
    );
    assert!(md.contains("- `etm pane ls --offset 2 --limit 2`"), "{md}");
    assert!(render(&env, OutputFormat::Text).starts_with("{\n  \"schema\""));
    assert_eq!(render(&env, OutputFormat::Json), env.to_string());
}

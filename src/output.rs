//! Printing an envelope through the shared flag set
//! (`workspace_cli`): JSON (default off a tty), TOON, markdown, or etm's
//! text view, which is pretty JSON (default on a tty). Before printing,
//! [`shape`] applies what both tools apply the same way: the pre-pass
//! notices (`flag.deprecated`, `flag.ignored`) as warnings, `--limit` /
//! `--offset` paging with `next_offset`, the flag tables in
//! `capabilities`, then `--fields` and `--brief`.

use crate::cli::{self, Action, Invocation};
use crate::envelope;
use serde_json::{json, Value};
use workspace_cli::page::{self, Page};
use workspace_cli::{Globals, OutputFormat};

pub fn render(envelope: &Value, format: OutputFormat) -> String {
    workspace_cli::output::render(envelope, format, "etm", |e| {
        serde_json::to_string_pretty(e).unwrap_or_else(|_| e.to_string())
    })
}

/// What `etm capabilities` adds to Emacs's answer: the shared global flag
/// set (shared with other tools built on workspace-cli), etm's own transport flags,
/// and the modifiers each verb honors.
pub fn flag_capabilities() -> Value {
    let tool: Vec<Value> = cli::TOOL_FLAGS
        .iter()
        .map(|(f, help)| json!({"flag": f, "help": help}))
        .collect();
    let modifiers: serde_json::Map<String, Value> = cli::MODIFIERS
        .iter()
        .map(|(v, _)| (v.to_string(), json!(cli::modifiers(v))))
        .collect();
    json!({
        "global_flags": workspace_cli::globals::capabilities(),
        "tool_flags": tool,
        "modifiers": modifiers,
        "modifiers_default": ["dry_run"],
    })
}

/// `--dry-run`: the request etm would send, sent nowhere.
pub fn dry_run(action: &Action) -> Value {
    let (verb, request) = match action {
        Action::Call { verb, args } => (verb.clone(), json!({"verb": verb, "args": args})),
        Action::Wait {
            args,
            timeout,
            poll,
        } => (
            "wait".to_string(),
            json!({"verb": "wait", "args": args, "timeout_s": timeout.as_secs_f64(),
                   "poll_ms": poll.as_millis() as u64}),
        ),
        Action::Bench { n } => ("bench".to_string(), json!({"verb": "bench", "n": n})),
        Action::InstallElisp { dir } => (
            "install-elisp".to_string(),
            json!({"verb": "install-elisp", "dir": dir.display().to_string()}),
        ),
        Action::Help | Action::Version => ("help".to_string(), Value::Null),
    };
    json!({
        "schema": envelope::SCHEMA, "ok": true, "verb": verb,
        "data": {"dry_run": true, "request": request},
        "rev": null, "warnings": [], "errors": [], "next": [], "events": [],
    })
}

/// The `etm events` page: Emacs sent the newest LIMIT+OFFSET (oldest
/// first) and how many older it dropped; skip the newest OFFSET.
fn page_events(data: &mut Value, g: &Globals) -> Option<Page> {
    let offset = g.offset.unwrap_or(0);
    let limit = g.limit.unwrap_or(cli::EVENTS_LIMIT);
    let mut events = data.get_mut("events")?.as_array_mut().map(std::mem::take)?;
    let older = data["dropped"].as_u64().unwrap_or(0) as usize;
    let total = events.len() + older;
    events.truncate(events.len().saturating_sub(offset));
    let p = Page {
        limit: Some(limit),
        offset,
        count: events.len(),
        total,
    };
    data["next_since"] = events
        .last()
        .map_or_else(|| data["next_since"].clone(), |e| e["id"].clone());
    data["events"] = Value::Array(events);
    data["dropped"] = json!(total - offset.min(total) - p.count);
    page::annotate(data, &p);
    Some(p)
}

/// The command a `next` page hint starts from.
fn list_command(verb: &str, args: &Value, g: &Globals) -> String {
    match (verb, args["ws"].as_str()) {
        ("pane.ls", Some("*")) => "etm pane ls --all".to_string(),
        ("pane.ls", Some(ws)) => format!("etm pane ls {ws}"),
        ("events", _) => match &g.since {
            Some(s) => format!("etm events --since {s}"),
            None => "etm events".to_string(),
        },
        _ => format!("etm {}", verb.replace('.', " ")),
    }
}

fn push(env: &mut Value, key: &str, items: Vec<Value>, front: bool) {
    if let Some(list) = env[key].as_array_mut() {
        if front {
            list.splice(0..0, items);
        } else {
            list.extend(items);
        }
    }
}

/// Apply the shared flags to ENV, the answer to INV.
pub fn shape(env: &mut Value, inv: &Invocation) {
    let g = &inv.globals;
    let (verb, args) = match &inv.action {
        Action::Call { verb, args } => (verb.as_str(), args.clone()),
        Action::Wait { args, .. } => ("wait", args.clone()),
        Action::Bench { .. } => ("bench", Value::Null),
        Action::InstallElisp { .. } => ("install-elisp", Value::Null),
        Action::Help | Action::Version => ("help", Value::Null),
    };
    let notices = g
        .notices
        .iter()
        .cloned()
        .chain(g.ignored(verb, &cli::modifiers(verb)));
    push(
        env,
        "warnings",
        notices.map(|n| n.to_json()).collect(),
        false,
    );
    if env["ok"] == true && env["data"]["dry_run"] != true {
        let paged = match verb {
            "ws.ls" | "pane.ls" if g.limit.is_some() || g.offset.is_some() => {
                let (data, p) =
                    page::paginate_list(env["data"].take(), g.limit, g.offset.unwrap_or(0));
                env["data"] = data;
                p
            }
            "events" => page_events(&mut env["data"], g),
            "capabilities" => {
                if let (Some(data), Value::Object(flags)) =
                    (env["data"].as_object_mut(), flag_capabilities())
                {
                    data.extend(flags);
                }
                None
            }
            _ => None,
        };
        if let Some(cmd) = paged.and_then(|p| p.next_command(&list_command(verb, &args, g))) {
            push(env, "next", vec![json!(cmd)], true);
        }
    }
    workspace_cli::output::select_fields(&mut env["data"], &g.fields);
    if g.brief {
        workspace_cli::output::brief(&mut env["data"]);
    }
}

#[cfg(test)]
#[path = "output_tests.rs"]
mod tests;

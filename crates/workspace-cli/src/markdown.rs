//! `--robot-markdown`: an envelope as markdown. A list of objects becomes
//! a table (the union of their keys, first-seen order); scalars become
//! `- **key**: value` bullets; nested objects become sub-headings. Then
//! warnings and errors as tables and `next` as commands.

use serde_json::{Map, Value};

fn cell(v: &Value) -> String {
    let s = match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        Value::Array(items) if items.iter().all(|i| !i.is_object() && !i.is_array()) => {
            items.iter().map(cell).collect::<Vec<_>>().join(", ")
        }
        Value::Array(_) | Value::Object(_) => format!("`{v}`"),
        other => other.to_string(),
    };
    s.replace('|', "\\|").replace('\n', "<br>")
}

fn columns(items: &[Value]) -> Vec<String> {
    let mut cols: Vec<String> = Vec::new();
    for o in items.iter().filter_map(Value::as_object) {
        for k in o.keys() {
            if !cols.contains(k) {
                cols.push(k.clone());
            }
        }
    }
    cols
}

/// ITEMS as a table; non-object items get a single `value` column.
pub fn table(items: &[Value]) -> String {
    if items.is_empty() {
        return "_(none)_\n".to_string();
    }
    if !items.iter().all(Value::is_object) {
        let rows: String = items.iter().map(|i| format!("| {} |\n", cell(i))).collect();
        return format!("| value |\n| --- |\n{rows}");
    }
    let cols = columns(items);
    let head = format!("| {} |\n", cols.join(" | "));
    let rule = format!("|{}\n", " --- |".repeat(cols.len()));
    let rows: String = items
        .iter()
        .map(|i| {
            let cells: Vec<String> = cols.iter().map(|c| cell(&i[c.as_str()])).collect();
            format!("| {} |\n", cells.join(" | "))
        })
        .collect();
    format!("{head}{rule}{rows}")
}

fn object(out: &mut String, obj: &Map<String, Value>, level: usize) {
    let hashes = "#".repeat(level.min(6));
    let (flat, nested): (Vec<_>, Vec<_>) = obj.iter().partition(|(_, v)| {
        !v.is_object()
            && !v
                .as_array()
                .is_some_and(|a| a.iter().any(|i| i.is_object()))
    });
    for (k, v) in flat {
        out.push_str(&format!("- **{k}**: {}\n", cell(v)));
    }
    for (k, v) in nested {
        out.push_str(&format!("\n{hashes} {k}\n\n"));
        match v {
            Value::Object(o) => object(out, o, level + 1),
            Value::Array(items) => out.push_str(&table(items)),
            _ => {}
        }
    }
}

fn diagnostics(out: &mut String, title: &str, list: &Value) {
    if let Some(items) = list.as_array().filter(|a| !a.is_empty()) {
        out.push_str(&format!("\n### {title}\n\n{}", table(items)));
    }
}

/// ENVELOPE as markdown under `## TOOL VERB: ok|failed`.
pub fn render(envelope: &Value, tool: &str) -> String {
    let status = if envelope["ok"] == true {
        "ok"
    } else {
        "failed"
    };
    let mut out = format!(
        "## {tool} {}: {status}\n\n",
        envelope["verb"].as_str().unwrap_or("?")
    );
    if let Some(rev) = envelope["rev"].as_str() {
        out.push_str(&format!("rev: `{rev}`\n\n"));
    }
    match &envelope["data"] {
        Value::Object(o) => object(&mut out, o, 3),
        Value::Array(items) => out.push_str(&table(items)),
        Value::Null => {}
        v => out.push_str(&format!("{}\n", cell(v))),
    }
    diagnostics(&mut out, "warnings", &envelope["warnings"]);
    diagnostics(&mut out, "errors", &envelope["errors"]);
    if let Some(next) = envelope["next"].as_array().filter(|a| !a.is_empty()) {
        out.push_str("\n### next\n\n");
        for n in next.iter().filter_map(Value::as_str) {
            out.push_str(&format!("- `{n}`\n"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn lists_of_objects_become_tables() {
        let env = json!({"ok": true, "verb": "ls", "rev": "b3:ab",
            "data": {"workspaces": [{"address": "client:x", "panes": 3},
                                    {"address": "client:y", "panes": 1, "places": ["local", "host:a"]}],
                     "next_offset": null, "pagination": {"limit": 2, "has_more": false}},
            "warnings": [{"code": "flag.deprecated", "msg": "use --json"}], "errors": [],
            "next": ["pwm status client:x"]});
        let md = render(&env, "pwm");
        assert_eq!(
            md,
            "## pwm ls: ok\n\nrev: `b3:ab`\n\n- **next_offset**: \n\n\
             ### workspaces\n\n| address | panes | places |\n| --- | --- | --- |\n\
             | client:x | 3 |  |\n| client:y | 1 | local, host:a |\n\n\
             ### pagination\n\n- **limit**: 2\n- **has_more**: false\n\n\
             ### warnings\n\n| code | msg |\n| --- | --- |\n| flag.deprecated | use --json |\n\n\
             ### next\n\n- `pwm status client:x`\n"
        );
    }

    #[test]
    fn list_data_failures_and_escaping() {
        let env = json!({"ok": false, "verb": "pane.ls", "rev": null,
            "data": [{"addr": "w/a|b", "meta": {"k": 1}}, {"addr": "two\nlines"}],
            "warnings": [], "errors": [{"code": "x.y", "msg": "m"}], "next": []});
        let md = render(&env, "etm");
        assert!(
            md.starts_with("## etm pane.ls: failed\n\n| addr | meta |\n"),
            "{md}"
        );
        assert!(
            md.contains("| w/a\\|b | `{\"k\":1}` |\n| two<br>lines |  |\n"),
            "{md}"
        );
        assert!(
            md.contains("### errors\n\n| code | msg |\n| --- | --- |\n| x.y | m |\n"),
            "{md}"
        );
        assert_eq!(table(&[]), "_(none)_\n");
        assert_eq!(
            table(&[json!(1), json!("a")]),
            "| value |\n| --- |\n| 1 |\n| a |\n"
        );
    }
}

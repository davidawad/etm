//! Printing an envelope: the format choice and the `data` shapers
//! (`--fields`, `--brief`) both tools apply the same way.

use serde_json::{json, Value};

/// How an answer is printed. JSON is the contract; the rest are views.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputFormat {
    Json,
    Toon,
    Markdown,
    /// The tool's human view (pwm's text lines, etm's pretty JSON).
    Text,
}

impl OutputFormat {
    pub const NAMES: &'static [&'static str] = &["json", "toon", "markdown", "text"];

    pub fn parse(s: &str) -> Option<OutputFormat> {
        match s {
            "json" => Some(OutputFormat::Json),
            "toon" => Some(OutputFormat::Toon),
            "markdown" | "md" => Some(OutputFormat::Markdown),
            "text" => Some(OutputFormat::Text),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            OutputFormat::Json => "json",
            OutputFormat::Toon => "toon",
            OutputFormat::Markdown => "markdown",
            OutputFormat::Text => "text",
        }
    }
}

/// ENVELOPE (a `pwm.result/1` value) in FORMAT; TEXT is the tool's own
/// human view, TITLE its name (`pwm`, `etm`) for the markdown heading.
pub fn render(
    envelope: &Value,
    format: OutputFormat,
    title: &str,
    text: impl FnOnce(&Value) -> String,
) -> String {
    match format {
        OutputFormat::Json => envelope.to_string(),
        OutputFormat::Toon => crate::toon::encode(envelope).trim_end().to_string(),
        OutputFormat::Markdown => crate::markdown::render(envelope, title)
            .trim_end()
            .to_string(),
        OutputFormat::Text => text(envelope),
    }
}

/// `--fields a,b`: keep only these keys of DATA (an object, or each
/// object of a list). The paging keys survive any selection.
pub fn select_fields(data: &mut Value, fields: &[String]) {
    if fields.is_empty() {
        return;
    }
    let keep = |v: &mut Value| {
        if let Some(obj) = v.as_object_mut() {
            obj.retain(|k, _| {
                fields.iter().any(|f| f == k) || crate::page::KEYS.contains(&k.as_str())
            });
        }
    };
    match data {
        Value::Array(items) => items.iter_mut().for_each(keep),
        // A paged etm list: the items are the records.
        Value::Object(obj)
            if obj.contains_key("pagination") && obj.get("items").is_some_and(Value::is_array) =>
        {
            if let Some(Value::Array(items)) = obj.get_mut("items") {
                items.iter_mut().for_each(keep);
            }
        }
        Value::Object(_) => keep(data),
        _ => {}
    }
}

/// `--brief`: summary only. Every list in DATA (top level) becomes its
/// length; a list as DATA becomes `{"count": n}`.
pub fn brief(data: &mut Value) {
    match data {
        Value::Array(items) => *data = json!({"count": items.len()}),
        Value::Object(obj) => {
            for v in obj.values_mut() {
                if let Value::Array(items) = v {
                    *v = json!(items.len());
                }
            }
        }
        _ => {}
    }
}

/// `--verbose`: the stderr trace line, `TOOL: verb=V format=F flags=[..] ms=N`.
pub fn trace(tool: &str, verb: &str, g: &crate::Globals, format: OutputFormat, ms: u128) -> String {
    format!(
        "{tool}: verb={verb} format={} flags=[{}] ms={ms}",
        format.as_str(),
        g.given.join(",")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_round_trip_their_names() {
        for n in OutputFormat::NAMES {
            assert_eq!(OutputFormat::parse(n).unwrap().as_str(), *n);
        }
        assert_eq!(OutputFormat::parse("md"), Some(OutputFormat::Markdown));
        assert_eq!(OutputFormat::parse("compact"), None);
    }

    #[test]
    fn render_dispatches_on_format() {
        let env = json!({"ok": true, "verb": "ls", "data": {"n": 1}});
        assert_eq!(
            render(&env, OutputFormat::Json, "pwm", |_| unreachable!()),
            env.to_string()
        );
        assert_eq!(
            render(&env, OutputFormat::Text, "pwm", |_| "human".into()),
            "human"
        );
        assert!(render(&env, OutputFormat::Toon, "pwm", |_| unreachable!()).contains("ok: true"));
        assert!(
            render(&env, OutputFormat::Markdown, "pwm", |_| unreachable!())
                .starts_with("## pwm ls")
        );
    }

    #[test]
    fn fields_cut_objects_lists_and_pages_but_keep_paging_keys() {
        let mut d = json!({"a": 1, "b": 2, "next_offset": 5, "pagination": {}});
        select_fields(&mut d, &["a".into()]);
        assert_eq!(d, json!({"a": 1, "next_offset": 5, "pagination": {}}));
        let mut d = json!([{"a": 1, "b": 2}, {"a": 3, "c": 4}]);
        select_fields(&mut d, &["a".into()]);
        assert_eq!(d, json!([{"a": 1}, {"a": 3}]));
        let mut d = json!({"items": [{"a": 1, "b": 2}], "pagination": {}, "next_offset": null});
        select_fields(&mut d, &["b".into()]);
        assert_eq!(d["items"], json!([{"b": 2}]));
        let mut d = json!({"a": 1});
        select_fields(&mut d, &[]);
        assert_eq!(d, json!({"a": 1}));
    }

    #[test]
    fn brief_counts_lists() {
        let mut d = json!({"workspaces": [1, 2], "panes": [], "rev": "x"});
        brief(&mut d);
        assert_eq!(d, json!({"workspaces": 2, "panes": 0, "rev": "x"}));
        let mut d = json!([1, 2, 3]);
        brief(&mut d);
        assert_eq!(d, json!({"count": 3}));
    }
}

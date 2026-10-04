//! TOON (Token-Oriented Object Notation), the `--robot-format=toon`
//! encoder: JSON's data model with YAML-like indentation, and a list of
//! uniform flat objects stated once as `key[N]{a,b}:` plus one comma row
//! per item -- where most of JSON's tokens go in a `ls` answer.
//!
//! Rules (TOON spec v1, comma delimiter): `key: value`; a nested object
//! is `key:` with its fields two spaces deeper; a list of primitives is
//! `key[N]: a,b`; a uniform list of flat objects is tabular; any other
//! list is `key[N]:` with one `- item` line per item (an object item puts
//! its first field on the hyphen line). Strings are quoted only when bare
//! text would read back as something else.

use serde_json::{Map, Value};

const INDENT: &str = "  ";

fn is_primitive(v: &Value) -> bool {
    !matches!(v, Value::Array(_) | Value::Object(_))
}

/// `-?\d+(\.\d+)?([eE][+-]?\d+)?`: bare, it would read back as a number.
fn looks_numeric(s: &str) -> bool {
    fn digits(s: &str) -> Option<&str> {
        let end = s.find(|c: char| !c.is_ascii_digit()).unwrap_or(s.len());
        (end > 0).then(|| &s[end..])
    }
    let t = s.strip_prefix('-').unwrap_or(s);
    let Some(mut rest) = digits(t) else {
        return false;
    };
    if let Some(frac) = rest.strip_prefix('.') {
        match digits(frac) {
            Some(r) => rest = r,
            None => return false,
        }
    }
    if let Some(exp) = rest.strip_prefix(['e', 'E']) {
        let exp = exp.strip_prefix(['+', '-']).unwrap_or(exp);
        match digits(exp) {
            Some(r) => rest = r,
            None => return false,
        }
    }
    rest.is_empty()
}

fn needs_quotes(s: &str) -> bool {
    s.is_empty()
        || s.trim() != s
        || matches!(s, "true" | "false" | "null")
        || looks_numeric(s)
        || s.starts_with('-')
        || s.chars()
            .any(|c| ":\"\\[]{},#".contains(c) || c.is_control())
}

fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn string(s: &str) -> String {
    if needs_quotes(s) {
        quote(s)
    } else {
        s.to_string()
    }
}

fn key(k: &str) -> String {
    let bare = k
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && k.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.');
    if bare {
        k.to_string()
    } else {
        quote(k)
    }
}

fn primitive(v: &Value) -> String {
    match v {
        Value::String(s) => string(s),
        Value::Number(n) if n.as_f64() == Some(0.0) => "0".to_string(),
        other => other.to_string(),
    }
}

fn row(items: &[Value]) -> String {
    items.iter().map(primitive).collect::<Vec<_>>().join(",")
}

/// The shared field list when ITEMS are non-empty objects with one key
/// set and primitive values only.
fn tabular_fields(items: &[Value]) -> Option<Vec<String>> {
    let first = items.first()?.as_object()?;
    if first.is_empty() {
        return None;
    }
    let fields: Vec<String> = first.keys().cloned().collect();
    items
        .iter()
        .all(|i| {
            i.as_object().is_some_and(|o| {
                o.len() == fields.len() && fields.iter().all(|f| o.get(f).is_some_and(is_primitive))
            })
        })
        .then_some(fields)
}

struct Out {
    lines: Vec<String>,
}

impl Out {
    fn line(&mut self, depth: usize, text: String) {
        self.lines.push(format!("{}{text}", INDENT.repeat(depth)));
    }

    fn fields(&mut self, obj: &Map<String, Value>, depth: usize) {
        for (k, v) in obj {
            self.field(&key(k), v, depth);
        }
    }

    /// One `HEAD: ...` entry; HEAD is an encoded key (or empty for a bare
    /// list item header).
    fn field(&mut self, head: &str, v: &Value, depth: usize) {
        match v {
            Value::Object(o) => {
                self.line(depth, format!("{head}:"));
                self.fields(o, depth + 1);
            }
            Value::Array(items) => self.array(head, items, depth),
            p => self.line(depth, format!("{head}: {}", primitive(p))),
        }
    }

    fn array(&mut self, head: &str, items: &[Value], depth: usize) {
        let n = items.len();
        if items.iter().all(is_primitive) {
            let body = if n == 0 {
                String::new()
            } else {
                format!(" {}", row(items))
            };
            self.line(depth, format!("{head}[{n}]:{body}"));
        } else if let Some(fields) = tabular_fields(items) {
            let names: Vec<String> = fields.iter().map(|f| key(f)).collect();
            self.line(depth, format!("{head}[{n}]{{{}}}:", names.join(",")));
            for item in items {
                let cells: Vec<Value> = fields.iter().map(|f| item[f.as_str()].clone()).collect();
                self.line(depth + 1, row(&cells));
            }
        } else {
            self.line(depth, format!("{head}[{n}]:"));
            for item in items {
                self.item(item, depth + 1);
            }
        }
    }

    /// One `- ` list item at DEPTH.
    fn item(&mut self, v: &Value, depth: usize) {
        match v {
            Value::Object(o) if o.is_empty() => self.line(depth, "-".to_string()),
            Value::Object(o) => {
                // Fields one level under the hyphen; the first is hoisted
                // onto the hyphen line.
                let mut sub = Out { lines: Vec::new() };
                sub.fields(o, depth + 1);
                let pad = INDENT.repeat(depth + 1);
                let mut lines = sub.lines.into_iter();
                if let Some(first) = lines.next() {
                    let first = first.strip_prefix(&pad).unwrap_or(&first).to_string();
                    self.line(depth, format!("- {first}"));
                }
                self.lines.extend(lines);
            }
            Value::Array(items) => {
                let mut sub = Out { lines: Vec::new() };
                sub.array("", items, depth);
                let pad = INDENT.repeat(depth);
                let mut lines = sub.lines.into_iter();
                if let Some(first) = lines.next() {
                    let first = first.strip_prefix(&pad).unwrap_or(&first).to_string();
                    self.line(depth, format!("- {first}"));
                }
                self.lines.extend(lines);
            }
            p => self.line(depth, format!("- {}", primitive(p))),
        }
    }
}

/// VALUE as TOON text (newline-terminated unless empty).
pub fn encode(value: &Value) -> String {
    let mut out = Out { lines: Vec::new() };
    match value {
        Value::Object(o) => out.fields(o, 0),
        Value::Array(items) => out.array("", items, 0),
        p => out.line(0, primitive(p)),
    }
    let mut s = out.lines.join("\n");
    if !s.is_empty() {
        s.push('\n');
    }
    s
}

#[cfg(test)]
#[path = "toon_tests.rs"]
mod tests;

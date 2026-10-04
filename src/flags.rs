//! Verb-level flag splitting for the argv grammar in `cli.rs`.

use crate::cli::{usage, Usage};
use serde_json::{Map, Value};

/// Flags taking a value, per verb; anything else starting `--` is boolean.
/// The shared modifiers (`--since`, `--limit`, `--timeout`, ...) never get
/// here: `workspace_cli::parse` takes them first.
const VALUE_FLAGS: &[&str] = &[
    "--subject",
    "--spec",
    "--owner",
    "--adopt",
    "--page",
    "--kind",
    "--region",
    "--path",
    "--cmd",
    "--backend",
    "--lines",
    "--max-chars",
    "--until",
    "--idle-ms",
    "--poll-ms",
    "--n",
];
const BOOL_FLAGS: &[&str] = &["--switch", "--all", "--enter"];

pub(crate) struct Parsed {
    pub(crate) positional: Vec<String>,
    pub(crate) flags: Map<String, Value>,
}

pub(crate) fn split_flags(verb: &str, rest: &[String]) -> Result<Parsed, Usage> {
    let mut positional = Vec::new();
    let mut flags = Map::new();
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        if a == "--" {
            positional.extend(it.by_ref().cloned());
            break;
        }
        if a.starts_with("--") && a.len() > 2 {
            let (name, inline) = match a.split_once('=') {
                Some((n, v)) => (n.to_string(), Some(v.to_string())),
                None => (a.clone(), None),
            };
            if VALUE_FLAGS.contains(&name.as_str()) {
                let v = match inline {
                    Some(v) => v,
                    None => it
                        .next()
                        .cloned()
                        .ok_or_else(|| usage(verb, format!("{name} needs a value")))?,
                };
                flags.insert(name, Value::String(v));
            } else if BOOL_FLAGS.contains(&name.as_str()) && inline.is_none() {
                flags.insert(name, Value::Bool(true));
            } else {
                return Err(usage(verb, format!("unknown flag {a}")));
            }
        } else {
            positional.push(a.clone());
        }
    }
    Ok(Parsed { positional, flags })
}

impl Parsed {
    pub(crate) fn str(&self, flag: &str) -> Option<String> {
        self.flags
            .get(flag)
            .and_then(Value::as_str)
            .map(str::to_string)
    }
    pub(crate) fn has(&self, flag: &str) -> bool {
        self.flags.get(flag) == Some(&Value::Bool(true))
    }
    pub(crate) fn num(&self, verb: &str, flag: &str) -> Result<Option<f64>, Usage> {
        self.str(flag)
            .map(|s| {
                s.parse::<f64>()
                    .map_err(|_| usage(verb, format!("{flag} must be a number")))
            })
            .transpose()
    }
    pub(crate) fn only(&self, verb: &str, allowed: &[&str]) -> Result<(), Usage> {
        match self.flags.keys().find(|k| !allowed.contains(&k.as_str())) {
            Some(k) => Err(usage(verb, format!("{k} does not apply to `{verb}`"))),
            None => Ok(()),
        }
    }
    pub(crate) fn arity(
        &self,
        verb: &str,
        min: usize,
        max: usize,
        shape: &str,
    ) -> Result<(), Usage> {
        let n = self.positional.len();
        if n < min || n > max {
            return Err(usage(verb, format!("usage: etm {shape}")));
        }
        Ok(())
    }
    pub(crate) fn pos(&self, i: usize) -> Value {
        self.positional
            .get(i)
            .map_or(Value::Null, |s| Value::String(s.clone()))
    }
}

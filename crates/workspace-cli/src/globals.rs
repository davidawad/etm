//! The global flag table and the argv pre-pass.
//!
//! Two groups, as ntm has them. Output flags shape how any answer is
//! printed. Modifiers are unprefixed global flags a verb honors when it
//! has the notion (`--limit` on a list, `--timeout` on a wait); a verb
//! without it reports a `flag.ignored` notice instead of failing, so one
//! flag set is accepted on every verb of both tools.

use std::time::Duration;

use serde_json::{json, Value};

use crate::output::OutputFormat;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Group {
    Output,
    Modifier,
}

impl Group {
    pub fn as_str(self) -> &'static str {
        match self {
            Group::Output => "output",
            Group::Modifier => "modifier",
        }
    }
}

/// One global flag: its canonical spelling, its value (None: boolean),
/// and the alternative spellings that are not deprecated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Flag {
    /// Stable id (`dry_run`): the MCP property name and `given` entry.
    pub name: &'static str,
    pub flag: &'static str,
    pub value: Option<&'static str>,
    pub values: &'static [&'static str],
    pub group: Group,
    pub help: &'static str,
    pub aliases: &'static [&'static str],
}

const fn flag(
    name: &'static str,
    flag: &'static str,
    value: Option<&'static str>,
    values: &'static [&'static str],
    group: Group,
    help: &'static str,
    aliases: &'static [&'static str],
) -> Flag {
    Flag {
        name,
        flag,
        value,
        values,
        group,
        help,
        aliases,
    }
}

use Group::{Modifier, Output};

/// The one global flag set (W6 test: both CLIs' capabilities list it).
pub const FLAGS: [Flag; 12] = [
    flag("json", "--json", None, &[], Output, "JSON envelope (the default off a tty); = --robot-format=json", &[]),
    flag("robot_format", "--robot-format", Some("FORMAT"), OutputFormat::NAMES, Output,
         "json | toon (TOON: uniform lists as one header plus rows) | markdown (tables) | text (the human view, default on a tty)", &[]),
    flag("robot_markdown", "--robot-markdown", None, &[], Output, "Markdown tables; = --robot-format=markdown", &[]),
    flag("fields", "--fields", Some("a,b"), &[], Output, "Keep only these keys of data (of each item when data is a list)", &[]),
    flag("brief", "--brief", None, &[], Output, "Summary only: every list in data becomes its count", &[]),
    flag("verbose", "--verbose", None, &[], Output, "Trace the parsed flags and timing to stderr", &[]),
    flag("no_color", "--no-color", None, &[], Output, "No ANSI color (none is emitted; NO_COLOR is honored too)", &[]),
    flag("limit", "--limit", Some("N"), &[], Modifier, "List verbs: at most N items; data.next_offset says where the next page starts", &["--robot-limit"]),
    flag("offset", "--offset", Some("N"), &[], Modifier, "List verbs: skip the first N items (events: the newest N)", &["--robot-offset"]),
    flag("since", "--since", Some("T"), &[], Modifier, "Lower bound: a time (RFC3339, epoch seconds, age like 10m) for events, a cursor for capture/wait", &[]),
    flag("timeout", "--timeout", Some("DUR"), &[], Modifier, "Wait verbs: give up after DUR (seconds, or 500ms/30s/5m/1h) with exit 7", &[]),
    flag("dry_run", "--dry-run", None, &[], Modifier, "Preview without executing: the plan, or the request that would be sent", &[]),
];

/// An old spelling that still works: FLAG (with VALUE, when the old flag
/// took one) means REPLACEMENT.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Deprecated {
    pub flag: &'static str,
    pub value: Option<&'static str>,
    pub replacement: &'static str,
}

const fn old(
    flag: &'static str,
    value: Option<&'static str>,
    replacement: &'static str,
) -> Deprecated {
    Deprecated {
        flag,
        value,
        replacement,
    }
}

/// pwm took `--format json|text`, etm `--format json|pretty|compact`;
/// one table serves both tools, so each accepts all four.
pub const DEPRECATED: [Deprecated; 4] = [
    old("--format", Some("json"), "--json"),
    old("--format", Some("compact"), "--robot-format=toon"),
    old("--format", Some("text"), "--robot-format=text"),
    old("--format", Some("pretty"), "--robot-format=text"),
];

/// A warning the pre-pass hands the CLI for its envelope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Notice {
    pub code: &'static str,
    pub msg: String,
    pub hint: Option<String>,
}

impl Notice {
    pub fn to_json(&self) -> Value {
        let mut v = json!({"code": self.code, "msg": self.msg});
        if let Some(h) = &self.hint {
            v["hint"] = json!(h);
        }
        v
    }
}

/// A global flag that cannot be parsed (`usage.bad_flag`, exit 2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlagError {
    pub msg: String,
}

impl FlagError {
    pub const CODE: &'static str = "usage.bad_flag";
}

impl std::fmt::Display for FlagError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.msg)
    }
}

fn bad(msg: impl Into<String>) -> FlagError {
    FlagError { msg: msg.into() }
}

/// What the global flags asked for.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Globals {
    /// An explicit output choice (last one wins); None: by tty.
    pub format: Option<OutputFormat>,
    pub fields: Vec<String>,
    pub brief: bool,
    pub verbose: bool,
    pub no_color: bool,
    pub limit: Option<usize>,
    pub offset: Option<usize>,
    pub since: Option<String>,
    pub timeout: Option<Duration>,
    pub dry_run: bool,
    /// Ids of the flags given, canonical, in order.
    pub given: Vec<&'static str>,
    /// `flag.deprecated` notices for old spellings.
    pub notices: Vec<Notice>,
}

impl Globals {
    /// The format to print in: the explicit choice, else text on a tty
    /// and JSON off one.
    pub fn format(&self, tty: bool) -> OutputFormat {
        self.format.unwrap_or(if tty {
            OutputFormat::Text
        } else {
            OutputFormat::Json
        })
    }

    /// `flag.ignored` notices for the modifiers given that VERB does not
    /// honor (HONORED: modifier ids, e.g. `["limit", "offset"]`).
    pub fn ignored(&self, verb: &str, honored: &[&str]) -> Vec<Notice> {
        FLAGS
            .iter()
            .filter(|f| f.group == Modifier && self.given.contains(&f.name))
            .filter(|f| !honored.contains(&f.name))
            .map(|f| Notice {
                code: "flag.ignored",
                msg: format!("{} does not apply to `{verb}`; ignored", f.flag),
                hint: None,
            })
            .collect()
    }
}

/// `--timeout`: seconds (`30`, `1.5`) or a number with ms, s, m or h.
pub fn parse_duration(s: &str) -> Option<Duration> {
    let (num, per) = [("ms", 0.001), ("s", 1.0), ("m", 60.0), ("h", 3600.0)]
        .iter()
        .find_map(|(u, per)| s.strip_suffix(u).map(|n| (n, *per)))
        .unwrap_or((s, 1.0));
    let n: f64 = num.trim().parse().ok()?;
    (n.is_finite() && n >= 0.0).then(|| Duration::from_secs_f64(n * per))
}

fn count(flag: &str, raw: &str, positive: bool) -> Result<usize, FlagError> {
    raw.parse::<usize>()
        .ok()
        .filter(|n| !positive || *n > 0)
        .ok_or_else(|| {
            let want = if positive {
                "a positive integer"
            } else {
                "a whole number"
            };
            bad(format!("{flag} {raw}: want {want}"))
        })
}

fn split_list(s: &str) -> Vec<String> {
    s.split(',')
        .map(str::trim)
        .filter(|f| !f.is_empty())
        .map(str::to_string)
        .collect()
}

/// The table entry ARG names (canonical spelling or alias).
fn lookup(arg: &str) -> Option<&'static Flag> {
    FLAGS
        .iter()
        .find(|f| f.flag == arg || f.aliases.contains(&arg))
}

fn set(g: &mut Globals, f: &'static Flag, value: Option<String>) -> Result<(), FlagError> {
    let v = value.as_deref().unwrap_or_default();
    match f.name {
        "json" => g.format = Some(OutputFormat::Json),
        "robot_markdown" => g.format = Some(OutputFormat::Markdown),
        "robot_format" => {
            g.format = Some(OutputFormat::parse(v).ok_or_else(|| {
                bad(format!(
                    "--robot-format {v}: want {}",
                    OutputFormat::NAMES.join(", ")
                ))
            })?);
        }
        "fields" => g.fields = split_list(v),
        "brief" => g.brief = true,
        "verbose" => g.verbose = true,
        "no_color" => g.no_color = true,
        "limit" => g.limit = Some(count(f.flag, v, true)?),
        "offset" => g.offset = Some(count(f.flag, v, false)?),
        "since" => g.since = Some(v.to_string()),
        "timeout" => {
            g.timeout = Some(parse_duration(v).ok_or_else(|| {
                bad(format!(
                    "--timeout {v}: want seconds or a duration like 500ms, 30s, 5m"
                ))
            })?);
        }
        "dry_run" => g.dry_run = true,
        other => unreachable!("flag {other} has no setter"),
    }
    if !g.given.contains(&f.name) {
        g.given.push(f.name);
    }
    Ok(())
}

/// An old spelling: map it onto the new flag and note the deprecation.
fn deprecated(g: &mut Globals, name: &str, value: &str) -> Result<(), FlagError> {
    let d = DEPRECATED
        .iter()
        .find(|d| d.flag == name && d.value.is_none_or(|v| v == value))
        .ok_or_else(|| {
            bad(format!(
                "{name} {value}: want json, compact, text or pretty (deprecated; use --json or --robot-format)"
            ))
        })?;
    let (new, new_value) = match d.replacement.split_once('=') {
        Some((f, v)) => (f, Some(v.to_string())),
        None => (d.replacement, None),
    };
    set(g, lookup(new).expect("replacement is in FLAGS"), new_value)?;
    g.notices.push(Notice {
        code: "flag.deprecated",
        msg: format!("{name} {value} is deprecated; use {}", d.replacement),
        hint: Some(d.replacement.to_string()),
    });
    Ok(())
}

/// Take the global flags out of ARGS (no program name), wherever they
/// appear before a `--`; return them and the remaining words in order.
pub fn parse(args: &[String]) -> Result<(Globals, Vec<String>), FlagError> {
    let mut g = Globals::default();
    let mut rest = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a == "--" {
            rest.push(a.clone());
            rest.extend(it.by_ref().cloned());
            break;
        }
        let (name, inline) = match a.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_string())),
            _ => (a.as_str(), None),
        };
        let mut value = |inline: Option<String>| {
            inline
                .or_else(|| it.next().cloned())
                .ok_or_else(|| bad(format!("{name} needs a value")))
        };
        if let Some(f) = lookup(name) {
            let v = match (f.value, inline) {
                (None, Some(_)) => return Err(bad(format!("{name} takes no value"))),
                (None, None) => None,
                (Some(_), inline) => Some(value(inline)?),
            };
            set(&mut g, f, v)?;
        } else if DEPRECATED.iter().any(|d| d.flag == name) {
            let v = value(inline)?;
            deprecated(&mut g, name, &v)?;
        } else {
            rest.push(a.clone());
        }
    }
    Ok((g, rest))
}

/// The output format ARGS ask for, read leniently (last one wins, bad
/// values skipped): how to print the usage error when [`parse`] fails.
pub fn sniff_format(args: &[String]) -> Option<OutputFormat> {
    let mut found = None;
    let mut it = args.iter().take_while(|a| *a != "--").peekable();
    while let Some(a) = it.next() {
        let (name, inline) = match a.split_once('=') {
            Some((n, v)) => (n, Some(v.to_string())),
            None => (a.as_str(), None),
        };
        let pick = match name {
            "--json" => Some(OutputFormat::Json),
            "--robot-markdown" => Some(OutputFormat::Markdown),
            "--robot-format" | "--format" => {
                let v = inline.or_else(|| it.peek().map(|v| (*v).clone()));
                match (name, v.as_deref()) {
                    ("--format", Some("compact")) => Some(OutputFormat::Toon),
                    ("--format", Some("pretty")) => Some(OutputFormat::Text),
                    (_, v) => v.and_then(OutputFormat::parse),
                }
            }
            _ => None,
        };
        found = pick.or(found);
    }
    found
}

/// The table as capabilities data: `global_flags` in both tools.
pub fn capabilities() -> Value {
    FLAGS
        .iter()
        .map(|f| {
            let deprecated: Vec<Value> = DEPRECATED
                .iter()
                .filter(|d| {
                    let new = d.replacement.split('=').next().unwrap_or_default();
                    new == f.flag
                })
                .map(|d| {
                    let old = match d.value {
                        Some(v) => format!("{} {v}", d.flag),
                        None => d.flag.to_string(),
                    };
                    json!({"flag": old, "use": d.replacement})
                })
                .collect();
            json!({
                "name": f.name,
                "flag": f.flag,
                "group": f.group.as_str(),
                "takes_value": f.value.is_some(),
                "value_name": f.value,
                "values": f.values,
                "aliases": f.aliases,
                "deprecated_aliases": deprecated,
                "help": f.help,
            })
        })
        .collect()
}

/// The global flags as help text (pwm's `--help` epilogue, etm's help).
pub fn help_text() -> String {
    let line = |f: &Flag| {
        let head = match f.value {
            Some(v) => format!("{} {v}", f.flag),
            None => f.flag.to_string(),
        };
        let aliases = if f.aliases.is_empty() {
            String::new()
        } else {
            format!(" (alias {})", f.aliases.join(", "))
        };
        format!("  {head:<24} {}{aliases}\n", f.help)
    };
    let group = |g: Group| {
        FLAGS
            .iter()
            .filter(|f| f.group == g)
            .map(line)
            .collect::<String>()
    };
    let old: Vec<String> = DEPRECATED
        .iter()
        .map(|d| {
            format!(
                "{} {} -> {}",
                d.flag,
                d.value.unwrap_or_default(),
                d.replacement
            )
        })
        .collect();
    format!(
        "Global flags (shared with {}; ntm spellings):\n{}Modifiers (verbs that lack the notion ignore them with a flag.ignored warning):\n{}Deprecated, still accepted (flag.deprecated warning): {}\n",
        "pwm and etm",
        group(Output),
        group(Modifier),
        old.join("; ")
    )
}

#[cfg(test)]
#[path = "globals_tests.rs"]
mod tests;

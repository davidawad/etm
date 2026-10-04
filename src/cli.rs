//! argv → request. The grammar:
//!
//! ```text
//! etm [GLOBAL] snapshot [--fields a,b]
//! etm [GLOBAL] capabilities | doctor
//! etm [GLOBAL] ws ls [--limit N] [--offset N] | get [W] | new W [--subject S] [--switch] [--spec R] [--owner O] [--adopt FROM] | switch W | rename W NAME | kill W
//! etm [GLOBAL] pane ls [W|--all] [--limit N] [--offset N] | new W KEY --kind K [--region R] [--path P] [--cmd C] [--page P] [--backend B]
//! etm [GLOBAL] pane kill ADDR | focus ADDR
//! etm [GLOBAL] send ADDR TEXT|- [--enter]
//! etm [GLOBAL] capture ADDR [--since CURSOR] [--lines N] [--max-chars N]
//! etm [GLOBAL] wait ADDR --until idle|exit|match:RE [--timeout S] [--idle-ms N] [--since C] [--poll-ms N]
//! etm [GLOBAL] events [--since T|EVENT_ID] [--limit N] [--offset N]
//! etm [GLOBAL] eval FORM
//! etm [GLOBAL] bench [--n N]
//! etm [GLOBAL] install-elisp DIR
//!
//! GLOBAL: --socket|-s NAME_OR_PATH  --transport auto|socket|emacsclient
//!         --emacsclient PATH  --rpc-el PATH  --no-autoload  --io-timeout S
//!         plus the shared output set (workspace_cli::globals):
//!         --json --robot-format=json|toon|markdown|text --robot-markdown
//!         --fields a,b --brief --verbose --no-color, and the modifiers
//!         --limit N --offset N --since T --timeout DUR --dry-run
//! ```
//!
//! The shared flags are taken out of argv first (`workspace_cli::parse`),
//! wherever they appear; the verb reads the modifiers it honors
//! ([`MODIFIERS`]) from [`Invocation::globals`].

use crate::flags::{split_flags, Parsed};
use crate::transport::TransportMode;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::Duration;
use workspace_cli::Globals;

/// The shared modifiers each verb honors (`dry_run` is every verb's:
/// the request is shown, not sent); any other given is `flag.ignored`.
pub const MODIFIERS: &[(&str, &[&str])] = &[
    ("ws.ls", &["limit", "offset"]),
    ("pane.ls", &["limit", "offset"]),
    ("events", &["limit", "offset", "since"]),
    ("capture", &["since"]),
    ("wait", &["since", "timeout"]),
];

/// The modifiers VERB honors, `dry_run` included.
pub fn modifiers(verb: &str) -> Vec<&'static str> {
    MODIFIERS
        .iter()
        .find(|(v, _)| *v == verb)
        .map_or(&[][..], |(_, m)| *m)
        .iter()
        .copied()
        .chain(["dry_run"])
        .collect()
}

/// etm's own global flags (the transport), beside the shared set.
pub const TOOL_FLAGS: [(&str, &str); 6] = [
    (
        "--socket",
        "NAME_OR_PATH (alias -s): the Emacs server socket",
    ),
    ("--transport", "auto|socket|emacsclient"),
    ("--emacsclient", "PATH of the emacsclient fallback"),
    (
        "--rpc-el",
        "PATH of the elisp to autoload (etm.el, its directory, or a config loading it)",
    ),
    ("--no-autoload", "never load etm into Emacs"),
    ("--io-timeout", "S: one round trip's budget"),
];

/// Default `etm events` page when `--limit` is absent (the elisp's).
pub const EVENTS_LIMIT: usize = 50;

/// What to do once parsed.
#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    Call {
        verb: String,
        args: Value,
    },
    Wait {
        args: Value,
        timeout: Duration,
        poll: Duration,
    },
    Bench {
        n: usize,
    },
    /// Write the bundled elisp into a directory.
    InstallElisp {
        dir: PathBuf,
    },
    Help,
    Version,
}

/// A fully parsed command line.
#[derive(Debug, Clone, PartialEq)]
pub struct Invocation {
    pub socket: Option<String>,
    pub transport: Option<TransportMode>,
    pub emacsclient: Option<PathBuf>,
    pub rpc_el: Option<PathBuf>,
    pub no_autoload: bool,
    pub io_timeout: Option<Duration>,
    /// The shared global flags (output, modifiers, deprecation notices).
    pub globals: Globals,
    pub action: Action,
}

/// A usage error: message plus the verb it concerns (for the envelope).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Usage {
    pub verb: String,
    pub msg: String,
}

pub(crate) fn usage(verb: &str, msg: impl Into<String>) -> Usage {
    Usage {
        verb: verb.to_string(),
        msg: msg.into(),
    }
}

fn call(verb: &str, args: Value) -> Action {
    Action::Call {
        verb: verb.to_string(),
        args,
    }
}

/// Whole numbers go out as JSON integers (elisp counts want fixnums).
fn num_json(v: Option<f64>) -> Value {
    v.map_or(Value::Null, |n| {
        if n.fract() == 0.0 && n.abs() < 9.0e15 {
            json!(n as i64)
        } else {
            json!(n)
        }
    })
}

/// Why a pane may not open at a path (`Some(reason)`), or `None` when it
/// may: a policy an embedding binary supplies ([`parse_with`]).
pub type PathGuard<'a> = &'a dyn Fn(&str) -> Option<String>;

/// Parse the verb part (after global options).
fn parse_verb(
    words: &[String],
    g: &Globals,
    stdin_text: &mut dyn FnMut() -> std::io::Result<String>,
    guard: Option<PathGuard>,
) -> Result<Action, Usage> {
    let Some(head) = words.first() else {
        return Ok(Action::Help);
    };
    let (verb, rest): (String, &[String]) = match head.as_str() {
        "ws" | "pane" => {
            let sub = words
                .get(1)
                .ok_or_else(|| usage(head, format!("etm {head} needs a subcommand")))?;
            (format!("{head}.{sub}"), &words[2..])
        }
        _ => (head.clone(), &words[1..]),
    };
    let p = split_flags(&verb, rest)?;
    let v = verb.as_str();
    Ok(match v {
        "help" | "-h" | "--help" => Action::Help,
        "version" | "--version" => Action::Version,
        "snapshot" => {
            p.only(v, &[])?;
            p.arity(v, 0, 0, "snapshot [--fields a,b]")?;
            call(v, json!({}))
        }
        "capabilities" | "doctor" => {
            p.only(v, &[])?;
            p.arity(v, 0, 0, v)?;
            call(v, json!({}))
        }
        "events" => {
            p.only(v, &[])?;
            p.arity(
                v,
                0,
                0,
                "events [--since T|EVENT_ID] [--limit N] [--offset N]",
            )?;
            let since = g
                .since
                .as_ref()
                .map(|s| s.parse::<f64>().map_or(json!(s), |n| json!(n)));
            // Emacs keeps the newest LIMIT; the page skips the newest OFFSET.
            let limit = g.limit.unwrap_or(EVENTS_LIMIT) + g.offset.unwrap_or(0);
            call(v, json!({"since": since, "limit": limit}))
        }
        "eval" => {
            p.only(v, &[])?;
            p.arity(v, 1, 1, "eval FORM")?;
            call(v, json!({"form": p.pos(0)}))
        }
        "bench" => {
            p.only(v, &["--n"])?;
            p.arity(v, 0, 0, "bench [--n N]")?;
            let n = p.num(v, "--n")?.unwrap_or(50.0).max(1.0) as usize;
            Action::Bench { n }
        }
        "install-elisp" => {
            p.only(v, &[])?;
            p.arity(v, 1, 1, "install-elisp DIR")?;
            Action::InstallElisp {
                dir: PathBuf::from(absolutize(&p.positional[0])),
            }
        }
        _ if v.starts_with("ws.") => parse_ws(v, &p)?,
        _ if v.starts_with("pane.") => parse_pane(v, &p, guard)?,
        "send" | "capture" | "wait" => parse_io(v, &p, g, stdin_text)?,
        other => {
            return Err(usage(
                other,
                format!("unknown verb `{other}` (try `etm capabilities`)"),
            ))
        }
    })
}

fn parse_ws(v: &str, p: &Parsed) -> Result<Action, Usage> {
    Ok(match v {
        "ws.ls" => {
            p.only(v, &[])?;
            p.arity(v, 0, 0, "ws ls")?;
            call(v, json!({}))
        }
        "ws.get" => {
            p.only(v, &[])?;
            p.arity(v, 0, 1, "ws get [W]")?;
            call(v, json!({"ws": p.pos(0)}))
        }
        "ws.new" => {
            p.only(
                v,
                &["--subject", "--switch", "--spec", "--owner", "--adopt"],
            )?;
            p.arity(
                v,
                1,
                1,
                "ws new W [--subject S] [--switch] [--spec R] [--owner O] [--adopt FROM]",
            )?;
            call(
                v,
                json!({"ws": p.pos(0), "subject": p.str("--subject"), "switch": p.has("--switch"),
                       "spec": p.str("--spec"), "owner": p.str("--owner"), "adopt": p.str("--adopt")}),
            )
        }
        "ws.switch" | "ws.kill" => {
            p.only(v, &[])?;
            p.arity(v, 1, 1, &format!("{} W", v.replace('.', " ")))?;
            call(v, json!({"ws": p.pos(0)}))
        }
        "ws.rename" => {
            p.only(v, &[])?;
            p.arity(v, 2, 2, "ws rename W NAME")?;
            call(v, json!({"ws": p.pos(0), "name": p.pos(1)}))
        }
        other => {
            return Err(usage(
                other,
                format!("unknown verb `{other}` (try `etm capabilities`)"),
            ))
        }
    })
}

fn parse_pane(v: &str, p: &Parsed, guard: Option<PathGuard>) -> Result<Action, Usage> {
    Ok(match v {
        "pane.ls" => {
            p.only(v, &["--all"])?;
            p.arity(v, 0, 1, "pane ls [W|--all]")?;
            let ws = if p.has("--all") { json!("*") } else { p.pos(0) };
            call(v, json!({"ws": ws}))
        }
        "pane.new" => {
            p.only(
                v,
                &[
                    "--kind",
                    "--region",
                    "--path",
                    "--cmd",
                    "--page",
                    "--backend",
                ],
            )?;
            p.arity(
                v,
                2,
                2,
                "pane new W KEY --kind K [--region R] [--path P] [--cmd C] [--page P]",
            )?;
            let kind = p
                .str("--kind")
                .ok_or_else(|| usage(v, "pane new needs --kind"))?;
            let path = p.str("--path").map(|s| absolutize(&s));
            if let (Some(path), Some(guard)) = (&path, guard) {
                if let Some(why) = guard(path) {
                    return Err(usage(v, why));
                }
            }
            call(
                v,
                json!({"ws": p.pos(0), "key": p.pos(1), "kind": kind, "region": p.str("--region"),
                           "path": path, "cmd": p.str("--cmd"), "page": p.str("--page"),
                           "backend": p.str("--backend")}),
            )
        }
        "pane.kill" | "pane.focus" => {
            p.only(v, &[])?;
            p.arity(v, 1, 1, &format!("{} ADDR", v.replace('.', " ")))?;
            call(v, json!({"addr": p.pos(0)}))
        }
        other => {
            return Err(usage(
                other,
                format!("unknown verb `{other}` (try `etm capabilities`)"),
            ))
        }
    })
}

fn parse_io(
    v: &str,
    p: &Parsed,
    g: &Globals,
    stdin_text: &mut dyn FnMut() -> std::io::Result<String>,
) -> Result<Action, Usage> {
    Ok(match v {
        "send" => {
            p.only(v, &["--enter"])?;
            p.arity(v, 2, 2, "send ADDR TEXT|- [--enter]")?;
            let text = if p.positional[1] == "-" {
                stdin_text().map_err(|e| usage(v, format!("reading stdin: {e}")))?
            } else {
                p.positional[1].clone()
            };
            call(
                v,
                json!({"addr": p.pos(0), "text": text, "enter": p.has("--enter")}),
            )
        }
        "capture" => {
            p.only(v, &["--lines", "--max-chars"])?;
            p.arity(
                v,
                1,
                1,
                "capture ADDR [--since C] [--lines N] [--max-chars N]",
            )?;
            call(
                v,
                json!({"addr": p.pos(0), "since": g.since,
                           "lines": num_json(p.num(v, "--lines")?),
                           "max_chars": num_json(p.num(v, "--max-chars")?)}),
            )
        }
        "wait" => {
            p.only(v, &["--until", "--idle-ms", "--poll-ms"])?;
            p.arity(
                v,
                1,
                1,
                "wait ADDR --until idle|exit|match:RE [--timeout DUR]",
            )?;
            let until = p
                .str("--until")
                .ok_or_else(|| usage(v, "wait needs --until idle|exit|match:RE"))?;
            let timeout = g.timeout.unwrap_or(Duration::from_secs(30));
            let poll = p.num(v, "--poll-ms")?.unwrap_or(100.0).max(10.0);
            Action::Wait {
                args: json!({"addr": p.pos(0), "until": until, "since": g.since,
                             "idle_ms": num_json(p.num(v, "--idle-ms")?)}),
                timeout,
                poll: Duration::from_secs_f64(poll / 1000.0),
            }
        }
        other => {
            return Err(usage(
                other,
                format!("unknown verb `{other}` (try `etm capabilities`)"),
            ))
        }
    })
}

/// Paths are resolved here, not in Emacs, whose cwd is its own.
fn absolutize(p: &str) -> String {
    let path = PathBuf::from(p);
    if path.is_absolute() || p.starts_with('~') {
        return p.to_string();
    }
    std::env::current_dir().map_or_else(|_| p.to_string(), |d| d.join(path).display().to_string())
}

/// Parse a whole argv (without argv[0]). STDIN_TEXT supplies `send ... -`.
pub fn parse(
    argv: &[String],
    stdin_text: &mut dyn FnMut() -> std::io::Result<String>,
) -> Result<Invocation, Usage> {
    parse_with(argv, stdin_text, None)
}

/// [`parse`], with GUARD deciding whether `pane new --path P` may open
/// at P (it sees P made absolute; `~` stays as written).
pub fn parse_with(
    argv: &[String],
    stdin_text: &mut dyn FnMut() -> std::io::Result<String>,
    guard: Option<PathGuard>,
) -> Result<Invocation, Usage> {
    let (globals, argv) = workspace_cli::parse(argv).map_err(|e| usage("etm", e.msg))?;
    let argv = argv.as_slice();
    let mut inv = Invocation {
        socket: None,
        transport: None,
        emacsclient: None,
        rpc_el: None,
        no_autoload: false,
        io_timeout: None,
        globals,
        action: Action::Help,
    };
    // Global options are accepted anywhere before a `--`; everything else
    // is the verb's own words.
    let mut words: Vec<String> = Vec::new();
    let mut i = 0;
    let need = |i: usize, flag: &str| -> Result<String, Usage> {
        argv.get(i + 1)
            .cloned()
            .ok_or_else(|| usage("etm", format!("{flag} needs a value")))
    };
    while i < argv.len() {
        let a = argv[i].as_str();
        let mut step = 2;
        match a {
            "--" => {
                words.extend(argv[i..].iter().cloned());
                break;
            }
            "--socket" | "-s" => inv.socket = Some(need(i, a)?),
            "--transport" => {
                inv.transport = Some(
                    TransportMode::parse(&need(i, a)?)
                        .ok_or_else(|| usage("etm", "--transport is auto|socket|emacsclient"))?,
                );
            }
            "--emacsclient" => inv.emacsclient = Some(PathBuf::from(need(i, a)?)),
            "--rpc-el" => inv.rpc_el = Some(PathBuf::from(need(i, a)?)),
            "--no-autoload" => {
                inv.no_autoload = true;
                step = 1;
            }
            "--io-timeout" => {
                let s: f64 = need(i, a)?
                    .parse()
                    .map_err(|_| usage("etm", "--io-timeout must be seconds"))?;
                inv.io_timeout = Some(Duration::from_secs_f64(s.max(0.1)));
            }
            _ => {
                words.push(argv[i].clone());
                step = 1;
            }
        }
        i += step;
    }
    inv.action = parse_verb(&words, &inv.globals, stdin_text, guard)?;
    if let Action::Call { verb, args } = &mut inv.action {
        if verb == "snapshot" && !inv.globals.fields.is_empty() {
            args["fields"] = json!(inv.globals.fields);
        }
    }
    Ok(inv)
}

#[cfg(test)]
#[path = "cli_tests.rs"]
mod tests;

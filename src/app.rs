//! The `etm` program as a library function, so a binary that embeds etm
//! (with its own path policy or client defaults) runs the same CLI.

use crate::cli::{self, Action, PathGuard};
use crate::client::{quantile, Client, Config};
use crate::elisp;
use crate::envelope::{self, exit};
use crate::output;
use serde_json::{json, Value};
use std::io::{IsTerminal, Read};
use workspace_cli::OutputFormat;

pub const HELP: &str = "etm -- drive a running Emacs: workspaces, panes, terminals, as JSON verbs

  etm snapshot [--fields a,b]          whole session in one read
  etm capabilities | doctor            self-description | invariant probes
  etm ws ls [--limit N] [--offset N] | get [W] | new W [--subject S] [--switch] [--adopt FROM] | switch W | rename W NAME | kill W
  etm pane ls [W|--all] [--limit N] [--offset N] | new W KEY --kind shell|cmd|editor|tree|page [--region R] [--path P] [--cmd C] [--page P]
  etm pane kill ADDR | focus ADDR      ADDR = <workspace>/<pane-key>
  etm send ADDR TEXT|- [--enter]
  etm capture ADDR [--since CURSOR] [--lines N] [--max-chars N]
  etm wait ADDR --until idle|exit|match:RE [--timeout DUR] [--idle-ms N] [--poll-ms N]
  etm events [--since T|EVENT_ID] [--limit N] [--offset N]
  etm eval FORM                        escape hatch (logged)
  etm bench [--n N]                    snapshot round-trip timing
  etm install-elisp DIR                write the bundled elisp package into DIR

etm flags: --socket|-s NAME|PATH  --transport auto|socket|emacsclient  --emacsclient PATH
           --rpc-el PATH  --no-autoload  --io-timeout S
exit:   0 ok, 1 failure, 2 usage, 3 not found, 4 rev conflict, 5 unreachable, 6 partial, 7 wait timeout
manual: info etm (in Emacs: C-h i m etm), built from docs/etm.texi
";

/// What an embedding binary changes about the CLI.
#[derive(Default)]
pub struct Hooks<'a> {
    /// The client settings flags start from (`Config::default()`).
    pub base: Config,
    /// Whether `pane new --path P` may open at P.
    pub path_guard: Option<PathGuard<'a>>,
}

/// Run the CLI on ARGV (without argv[0]); returns the exit code.
pub fn run(argv: &[String], hooks: Hooks) -> i32 {
    let mut stdin_text = || {
        let mut s = String::new();
        std::io::stdin().read_to_string(&mut s).map(|_| s)
    };
    let started = std::time::Instant::now();
    let tty = std::io::stdout().is_terminal();
    let inv = match cli::parse_with(argv, &mut stdin_text, hooks.path_guard) {
        Ok(inv) => inv,
        Err(u) => {
            // The format flags may be what failed: read them again alone.
            let format = workspace_cli::sniff_format(argv).unwrap_or(if tty {
                OutputFormat::Text
            } else {
                OutputFormat::Json
            });
            let env = envelope::failure(&u.verb, "usage.argv", &u.msg, Some("etm help"), false);
            println!("{}", output::render(&env, format));
            eprintln!("etm: {}", u.msg);
            return exit::USAGE;
        }
    };
    let mut config = hooks.base;
    if let Some(m) = inv.transport {
        config.mode = m;
    }
    if inv.socket.is_some() {
        config.socket = inv.socket.clone();
    }
    if let Some(p) = &inv.emacsclient {
        config.emacsclient = p.clone();
    }
    if inv.rpc_el.is_some() {
        config.rpc_el = inv.rpc_el.clone();
    }
    if inv.no_autoload {
        config.rpc_el = None;
        config.discover = false;
    }
    if let Some(t) = inv.io_timeout {
        config.io_timeout = t;
    }
    let client = Client::new(config);
    let format = inv.globals.format(tty);
    let mut env = match &inv.action {
        Action::Help => {
            print!("{HELP}\n{}", workspace_cli::globals::help_text());
            return exit::OK;
        }
        Action::Version => {
            println!("etm {}", env!("CARGO_PKG_VERSION"));
            return exit::OK;
        }
        action if inv.globals.dry_run => output::dry_run(action),
        Action::Call { verb, args } => client.call(verb, args.clone()),
        Action::Wait {
            args,
            timeout,
            poll,
        } => client.wait(args.clone(), *timeout, *poll),
        Action::Bench { n } => bench(&client, *n),
        Action::InstallElisp { dir } => install_elisp(dir),
    };
    output::shape(&mut env, &inv);
    println!("{}", output::render(&env, format));
    if inv.globals.verbose {
        let verb = env["verb"].as_str().unwrap_or("?");
        let ms = started.elapsed().as_millis();
        eprintln!(
            "{}",
            workspace_cli::output::trace("etm", verb, &inv.globals, format, ms)
        );
    }
    envelope::exit_code(&env)
}

fn ok(verb: &str, data: Value, next: Vec<String>) -> Value {
    json!({
        "schema": envelope::SCHEMA, "ok": true, "verb": verb, "data": data,
        "rev": null, "warnings": [], "errors": [], "next": next, "events": [],
    })
}

fn bench(client: &Client, n: usize) -> Value {
    match client.bench(n) {
        Ok(ms) => ok(
            "bench",
            json!({"n": n, "target_ms": 30.0,
                   "p50_ms": quantile(&ms, 0.5), "p95_ms": quantile(&ms, 0.95),
                   "min_ms": quantile(&ms, 0.0), "max_ms": quantile(&ms, 1.0),
                   "under_target": quantile(&ms, 0.5) < 30.0}),
            vec![],
        ),
        Err(env) => env,
    }
}

/// `etm install-elisp DIR`: the bundled package, written where asked.
fn install_elisp(dir: &std::path::Path) -> Value {
    match elisp::install(dir) {
        Ok(files) => ok(
            "install-elisp",
            json!({"dir": dir.display().to_string(),
                   "files": files.iter().map(|f| f.display().to_string()).collect::<Vec<_>>(),
                   "version": env!("CARGO_PKG_VERSION"), "digest": elisp::digest()}),
            vec![format!(
                "emacs --eval '(progn (add-to-list (quote load-path) \"{}\") (require (quote etm)))'",
                dir.display()
            )],
        ),
        Err(e) => envelope::failure(
            "install-elisp",
            "install.failed",
            &format!("cannot write {}: {e}", dir.display()),
            None,
            false,
        ),
    }
}

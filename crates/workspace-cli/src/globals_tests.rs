use super::*;

fn argv(args: &[&str]) -> Vec<String> {
    args.iter().map(|s| (*s).to_string()).collect()
}

fn ok(args: &[&str]) -> (Globals, Vec<String>) {
    parse(&argv(args)).unwrap_or_else(|e| panic!("{args:?}: {e}"))
}

fn err(args: &[&str]) -> String {
    parse(&argv(args)).unwrap_err().msg
}

#[test]
fn output_flags_pick_the_format_last_one_winning() {
    assert_eq!(ok(&["--json"]).0.format, Some(OutputFormat::Json));
    assert_eq!(
        ok(&["--robot-markdown"]).0.format,
        Some(OutputFormat::Markdown)
    );
    for (raw, want) in [
        ("json", OutputFormat::Json),
        ("toon", OutputFormat::Toon),
        ("markdown", OutputFormat::Markdown),
        ("text", OutputFormat::Text),
    ] {
        assert_eq!(ok(&["--robot-format", raw]).0.format, Some(want), "{raw}");
        let inline = format!("--robot-format={raw}");
        assert_eq!(ok(&[&inline]).0.format, Some(want), "{inline}");
    }
    assert_eq!(
        ok(&["--json", "--robot-format=toon"]).0.format,
        Some(OutputFormat::Toon)
    );
    assert_eq!(
        ok(&["--robot-markdown", "--json"]).0.format,
        Some(OutputFormat::Json)
    );
    let (g, _) = ok(&[]);
    assert_eq!(
        (g.format(true), g.format(false)),
        (OutputFormat::Text, OutputFormat::Json)
    );
    assert!(err(&["--robot-format=yaml"]).contains("want json, toon, markdown, text"));
}

#[test]
fn every_deprecated_spelling_still_works_with_a_notice() {
    for (value, want, replacement) in [
        ("json", OutputFormat::Json, "--json"),
        ("compact", OutputFormat::Toon, "--robot-format=toon"),
        ("text", OutputFormat::Text, "--robot-format=text"),
        ("pretty", OutputFormat::Text, "--robot-format=text"),
    ] {
        for args in [vec!["--format", value], vec![&*format!("--format={value}")]] {
            let (g, rest) = ok(&args.iter().map(|s| &**s).collect::<Vec<_>>());
            assert_eq!(g.format, Some(want), "{args:?}");
            assert!(rest.is_empty());
            assert_eq!(g.notices.len(), 1);
            assert_eq!(g.notices[0].code, "flag.deprecated");
            assert_eq!(g.notices[0].hint.as_deref(), Some(replacement));
            assert_eq!(
                g.notices[0].msg,
                format!("--format {value} is deprecated; use {replacement}")
            );
        }
    }
    assert!(err(&["--format", "yaml"]).contains("deprecated"));
    assert_eq!(err(&["--format"]), "--format needs a value");
    let n = ok(&["--format", "compact"]).0.notices[0].to_json();
    assert_eq!(n["hint"], "--robot-format=toon");
}

#[test]
fn modifiers_and_their_aliases_parse() {
    let (g, rest) = ok(&[
        "ls",
        "--limit",
        "5",
        "--offset=10",
        "--since",
        "10m",
        "--timeout",
        "2.5",
        "--dry-run",
        "--brief",
        "--verbose",
        "--no-color",
        "--fields",
        "a, b,",
        "x",
    ]);
    assert_eq!(rest, ["ls", "x"]);
    assert_eq!((g.limit, g.offset), (Some(5), Some(10)));
    assert_eq!(g.since.as_deref(), Some("10m"));
    assert_eq!(g.timeout, Some(Duration::from_millis(2500)));
    assert!(g.dry_run && g.brief && g.verbose && g.no_color);
    assert_eq!(g.fields, ["a", "b"]);
    assert_eq!(
        g.given,
        [
            "limit", "offset", "since", "timeout", "dry_run", "brief", "verbose", "no_color",
            "fields"
        ]
    );
    assert!(g.notices.is_empty(), "aliases are not deprecated");
    let (g, _) = ok(&["--robot-limit=3", "--robot-offset", "6"]);
    assert_eq!((g.limit, g.offset), (Some(3), Some(6)));
    assert_eq!(ok(&["--offset", "0"]).0.offset, Some(0));
}

#[test]
fn timeouts_take_seconds_or_units() {
    for (raw, ms) in [
        ("30", 30_000),
        ("500ms", 500),
        ("2s", 2000),
        ("1.5m", 90_000),
        ("1h", 3_600_000),
    ] {
        assert_eq!(
            parse_duration(raw),
            Some(Duration::from_millis(ms)),
            "{raw}"
        );
    }
    for raw in ["", "x", "-1", "5d", "inf"] {
        assert_eq!(parse_duration(raw), None, "{raw}");
    }
    assert!(err(&["--timeout", "soon"]).starts_with("--timeout soon"));
}

#[test]
fn bad_values_are_usage_errors() {
    assert_eq!(err(&["--limit", "0"]), "--limit 0: want a positive integer");
    assert_eq!(
        err(&["--limit", "-1"]),
        "--limit -1: want a positive integer"
    );
    assert_eq!(err(&["--offset", "x"]), "--offset x: want a whole number");
    assert_eq!(err(&["--json=yes"]), "--json takes no value");
    assert_eq!(err(&["--limit"]), "--limit needs a value");
    assert_eq!(FlagError::CODE, "usage.bad_flag");
}

#[test]
fn the_pre_pass_leaves_verb_words_and_stops_at_double_dash() {
    let (g, rest) = ok(&["send", "w/a", "--enter", "--", "--json", "--limit"]);
    assert_eq!(rest, ["send", "w/a", "--enter", "--", "--json", "--limit"]);
    assert_eq!(g, Globals::default());
    let (_, rest) = ok(&["--root", "/x", "--with=a.b=c", "-s", "sock"]);
    assert_eq!(rest, ["--root", "/x", "--with=a.b=c", "-s", "sock"]);
}

#[test]
fn modifiers_a_verb_lacks_are_reported_not_fatal() {
    let (g, _) = ok(&["--limit", "2", "--timeout", "1", "--json"]);
    let ignored = g.ignored("render", &["limit"]);
    assert_eq!(ignored.len(), 1);
    assert_eq!(ignored[0].code, "flag.ignored");
    assert_eq!(
        ignored[0].msg,
        "--timeout does not apply to `render`; ignored"
    );
    assert!(g.ignored("wait", &["limit", "timeout"]).is_empty());
}

#[test]
fn capabilities_and_help_cover_the_whole_table() {
    let caps = capabilities();
    let list = caps.as_array().unwrap();
    assert_eq!(list.len(), FLAGS.len());
    let names: Vec<&str> = list.iter().map(|f| f["flag"].as_str().unwrap()).collect();
    assert_eq!(
        names,
        [
            "--json",
            "--robot-format",
            "--robot-markdown",
            "--fields",
            "--brief",
            "--verbose",
            "--no-color",
            "--limit",
            "--offset",
            "--since",
            "--timeout",
            "--dry-run"
        ]
    );
    let json_flag = &list[0];
    assert_eq!(
        json_flag["deprecated_aliases"],
        json!([{"flag": "--format json", "use": "--json"}])
    );
    assert_eq!(list[1]["deprecated_aliases"].as_array().unwrap().len(), 3);
    assert_eq!(
        list[1]["values"],
        json!(["json", "toon", "markdown", "text"])
    );
    assert_eq!(list[7]["aliases"], json!(["--robot-limit"]));
    assert_eq!(list[7]["group"], "modifier");
    let help = help_text();
    for f in FLAGS {
        assert!(help.contains(f.flag), "{}", f.flag);
    }
    assert!(help.contains("--format compact -> --robot-format=toon"));
}

#[test]
fn the_format_is_sniffed_even_when_parsing_fails() {
    let sniff = |args: &[&str]| sniff_format(&argv(args));
    assert_eq!(
        sniff(&["--robot-format=toon", "--limit", "0"]),
        Some(OutputFormat::Toon)
    );
    assert_eq!(
        sniff(&["--json", "--robot-markdown"]),
        Some(OutputFormat::Markdown)
    );
    assert_eq!(sniff(&["--format", "compact"]), Some(OutputFormat::Toon));
    assert_eq!(sniff(&["--format=pretty"]), Some(OutputFormat::Text));
    assert_eq!(
        sniff(&["--robot-format", "yaml", "--json"]),
        Some(OutputFormat::Json)
    );
    assert_eq!(sniff(&["--", "--json"]), None);
    assert_eq!(sniff(&[]), None);
}

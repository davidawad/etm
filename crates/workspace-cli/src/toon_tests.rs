use super::*;
use serde_json::json;

#[test]
fn objects_nest_by_indentation() {
    let v = json!({"ok": true, "verb": "ls", "rev": null, "data": {"n": 3, "inner": {"x": 1.5}, "empty": {}}});
    assert_eq!(
        encode(&v),
        "ok: true\nverb: ls\nrev: null\ndata:\n  n: 3\n  inner:\n    x: 1.5\n  empty:\n"
    );
}

#[test]
fn uniform_lists_are_tables() {
    let v = json!({"panes": [
        {"addr": "w/a", "kind": "shell", "n": 1},
        {"addr": "w/b", "kind": "cmd", "n": 2}
    ]});
    assert_eq!(
        encode(&v),
        "panes[2]{addr,kind,n}:\n  w/a,shell,1\n  w/b,cmd,2\n"
    );
}

#[test]
fn primitive_and_empty_lists_are_inline() {
    let v = json!({"tags": ["a", "b c", 3, true], "none": []});
    assert_eq!(encode(&v), "tags[4]: a,b c,3,true\nnone[0]:\n");
}

#[test]
fn mixed_lists_use_hyphen_items() {
    let v = json!({"items": [
        1,
        {"id": "x", "sub": {"k": "v"}, "more": 2},
        ["a", "b"],
        {},
        {"rows": [{"a": 1}]}
    ]});
    assert_eq!(
        encode(&v),
        "items[5]:\n  - 1\n  - id: x\n    sub:\n      k: v\n    more: 2\n  - [2]: a,b\n  -\n  - rows[1]{a}:\n      1\n"
    );
}

#[test]
fn non_uniform_object_lists_are_not_tables() {
    let v = json!({"l": [{"a": 1}, {"b": 2}], "n": [{"a": {"deep": 1}}]});
    assert_eq!(
        encode(&v),
        "l[2]:\n  - a: 1\n  - b: 2\nn[1]:\n  - a:\n      deep: 1\n"
    );
}

#[test]
fn strings_are_quoted_only_when_ambiguous() {
    let cases = [
        ("plain words", "plain words"),
        ("", "\"\""),
        (" pad", "\" pad\""),
        ("true", "\"true\""),
        ("null", "\"null\""),
        ("42", "\"42\""),
        ("-3.5e2", "\"-3.5e2\""),
        ("4x", "4x"),
        ("a,b", "\"a,b\""),
        ("k: v", "\"k: v\""),
        ("- item", "\"- item\""),
        ("say \"hi\"", "\"say \\\"hi\\\"\""),
        ("two\nlines", "\"two\\nlines\""),
        ("[x]", "\"[x]\""),
        ("client:datics/pm", "\"client:datics/pm\""),
        ("b3:9f", "\"b3:9f\""),
    ];
    for (raw, want) in cases {
        assert_eq!(
            encode(&json!({"s": raw})),
            format!("s: {want}\n"),
            "{raw:?}"
        );
    }
}

#[test]
fn keys_are_quoted_when_not_identifiers() {
    let v = json!({"pwm/dispatch": 1, "_meta": 2, "a.b": 3, "1x": 4});
    assert_eq!(
        encode(&v),
        "\"pwm/dispatch\": 1\n_meta: 2\na.b: 3\n\"1x\": 4\n"
    );
}

#[test]
fn a_whole_envelope_cuts_tokens() {
    let panes: Vec<_> = (0..20)
        .map(|i| json!({"address": format!("client:x/eng.{i}"), "surface": "tmux", "mount": "managed"}))
        .collect();
    let env = json!({"schema": "pwm.result/1", "ok": true, "verb": "status",
                     "data": {"panes": panes}, "rev": null, "warnings": [], "errors": [],
                     "next": ["pwm ls"], "events": []});
    let toon = encode(&env);
    assert!(
        toon.contains("  panes[20]{address,surface,mount}:\n    \"client:x/eng.0\",tmux,managed\n"),
        "{toon}"
    );
    assert!(
        toon.len() * 10 < env.to_string().len() * 7,
        "TOON is at least 30% smaller"
    );
    assert_eq!(encode(&json!("x")), "x\n");
    assert_eq!(encode(&json!([1, 2])), "[2]: 1,2\n");
}

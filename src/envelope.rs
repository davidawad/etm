//! The result envelope: one shape for every
//! `--json` response, typed errors, stable exit codes.
//!
//! The elisp package builds the envelope inside Emacs; this module validates it,
//! builds envelopes for failures that never reached Emacs (usage errors,
//! an unreachable server), and maps error codes to exit codes.

use serde_json::{json, Value};

/// Schema tag every envelope etm answers with.
pub const SCHEMA: &str = "etm.result/1";

/// Stable exit codes.
pub mod exit {
    pub const OK: i32 = 0;
    pub const FAILURE: i32 = 1;
    pub const USAGE: i32 = 2;
    pub const NOT_FOUND: i32 = 3;
    pub const REV_CONFLICT: i32 = 4;
    pub const UNREACHABLE: i32 = 5;
    pub const PARTIAL_APPLY: i32 = 6;
    pub const WAIT_TIMEOUT: i32 = 7;
}

/// Exit code for a dotted error CODE: its family picks the number.
pub fn exit_code_for(code: &str) -> i32 {
    if code.starts_with("usage.") {
        exit::USAGE
    } else if code.starts_with("not_found.") {
        exit::NOT_FOUND
    } else if code.starts_with("rev.") {
        exit::REV_CONFLICT
    } else if code.ends_with(".unreachable") {
        exit::UNREACHABLE
    } else if code == "apply.partial" {
        exit::PARTIAL_APPLY
    } else if code == "wait.timeout" {
        exit::WAIT_TIMEOUT
    } else {
        exit::FAILURE
    }
}

/// Exit code for a whole envelope: 0 when ok, else its first error's code.
pub fn exit_code(envelope: &Value) -> i32 {
    if envelope["ok"].as_bool() == Some(true) {
        return exit::OK;
    }
    envelope["errors"]
        .as_array()
        .and_then(|errs| errs.first())
        .and_then(|e| e["code"].as_str())
        .map_or(exit::FAILURE, exit_code_for)
}

/// A failure envelope built on this side of the transport.
pub fn failure(verb: &str, code: &str, msg: &str, hint: Option<&str>, retryable: bool) -> Value {
    json!({
        "schema": SCHEMA, "ok": false, "verb": verb, "data": null, "rev": null,
        "warnings": [],
        "errors": [{"code": code, "surface": "emacs", "msg": msg,
                    "hint": hint, "retryable": retryable}],
        "next": [], "events": [],
    })
}

/// Check that VALUE is an [`SCHEMA`] envelope; returns what's wrong.
pub fn validate(value: &Value) -> Result<(), String> {
    validate_with(value, &[])
}

/// [`validate`], also accepting the envelope shape under the schema
/// names in ALSO (an embedding tool's own name for the same envelope).
pub fn validate_with(value: &Value, also: &[String]) -> Result<(), String> {
    let obj = value.as_object().ok_or("envelope is not an object")?;
    let schema = obj.get("schema").and_then(Value::as_str);
    if schema != Some(SCHEMA) && !also.iter().any(|a| schema == Some(a.as_str())) {
        return Err(format!("schema is not {SCHEMA}"));
    }
    if !obj.get("ok").is_some_and(Value::is_boolean) {
        return Err("`ok` is not a boolean".into());
    }
    for key in ["warnings", "errors", "next", "events"] {
        if !obj.get(key).is_some_and(Value::is_array) {
            return Err(format!("`{key}` is not an array"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_codes_follow_w7() {
        assert_eq!(exit_code_for("usage.bad_arg"), 2);
        assert_eq!(exit_code_for("not_found.pane"), 3);
        assert_eq!(exit_code_for("rev.conflict"), 4);
        assert_eq!(exit_code_for("driver.unreachable"), 5);
        assert_eq!(exit_code_for("apply.partial"), 6);
        assert_eq!(exit_code_for("wait.timeout"), 7);
        assert_eq!(exit_code_for("capability.unavailable"), 1);
        assert_eq!(exit_code(&json!({"ok": true})), 0);
        assert_eq!(exit_code(&failure("x", "wait.timeout", "m", None, true)), 7);
        assert_eq!(exit_code(&json!({"ok": false, "errors": []})), 1);
    }

    #[test]
    fn failure_is_a_valid_envelope() {
        assert_eq!(
            validate(&failure("v", "usage.x", "m", Some("h"), false)),
            Ok(())
        );
        assert!(validate(&json!({"schema": SCHEMA})).is_err());
        let other = json!({"schema": "other.result/1", "ok": true, "warnings": [],
                           "errors": [], "next": [], "events": []});
        assert!(validate(&other).is_err());
        assert_eq!(validate_with(&other, &["other.result/1".into()]), Ok(()));
    }
}

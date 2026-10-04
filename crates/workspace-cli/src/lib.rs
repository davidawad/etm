//! workspace-cli: the one global flag set `pwm` and `etm` both accept,
//! spelled the way ntm spells them so an agent that drives ntm drives
//! these too. (It ships with etm's public tree as `etm-workspace-cli`, so
//! these docs name no private paths.)
//!
//! [`globals`] is the flag table and the argv pre-pass each CLI runs
//! before its own parser (clap for pwm, the verb grammar for etm): it
//! takes the global flags out wherever they appear, maps the old
//! spellings (`--format json|compact|text|pretty`) onto the new ones with
//! a `flag.deprecated` notice for the envelope, and leaves the verb's own
//! words. [`output`] picks and applies the output format (JSON, TOON,
//! markdown or the tool's own text view) plus `--fields` and `--brief`;
//! [`toon`] and [`markdown`] are the two token-cutting encoders; [`page`]
//! is `--limit`/`--offset` over a list with the `next_offset` hint.

pub mod globals;
pub mod markdown;
pub mod output;
pub mod page;
pub mod toon;

pub use globals::{parse, sniff_format, FlagError, Globals, Notice, FLAGS};
pub use output::OutputFormat;
pub use page::Page;

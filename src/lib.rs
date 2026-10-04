//! etm: drive a running Emacs's workspaces, panes and terminals with
//! structured verbs, from outside.
//!
//! Two halves, one contract: the elisp package (`lisp/`, bundled here by
//! [`elisp`]) dispatches a closed verb table inside Emacs; this crate turns
//! argv into a request, sends it base64-wrapped over the Emacs server
//! socket ([`transport`]), and returns the `etm.result/1` envelope
//! ([`envelope`]) with its stable exit code. [`client::Client`] is the
//! library surface for tools that embed etm; [`app::run`] is the CLI.

pub mod app;
pub mod cli;
pub mod client;
pub mod elisp;
pub mod envelope;
mod flags;
pub mod output;
pub mod transport;

pub use client::{Client, Config};
pub use transport::TransportMode;

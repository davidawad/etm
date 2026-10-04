//! The elisp half, bundled into the binary.
//!
//! Every `lisp/etm*.el` file is compiled in ([`FILES`]), so a bare
//! `cargo install etm` can drive an Emacs that has never seen the
//! package: the client writes the files to a versioned cache directory
//! ([`materialize`]) and loads them from there. `etm install-elisp DIR`
//! writes the same files where a user wants them ([`install`]).

use std::io;
use std::path::{Path, PathBuf};

/// (file name, contents) of every bundled elisp file, `etm.el` first.
pub const FILES: &[(&str, &str)] = &[
    ("etm.el", include_str!("../lisp/etm.el")),
    ("etm-base.el", include_str!("../lisp/etm-base.el")),
    ("etm-backend.el", include_str!("../lisp/etm-backend.el")),
    ("etm-persp.el", include_str!("../lisp/etm-persp.el")),
    ("etm-tab-bar.el", include_str!("../lisp/etm-tab-bar.el")),
    ("etm-tabspaces.el", include_str!("../lisp/etm-tabspaces.el")),
    ("etm-ext.el", include_str!("../lisp/etm-ext.el")),
    ("etm-ws.el", include_str!("../lisp/etm-ws.el")),
    ("etm-page.el", include_str!("../lisp/etm-page.el")),
    ("etm-pane.el", include_str!("../lisp/etm-pane.el")),
    ("etm-io.el", include_str!("../lisp/etm-io.el")),
    ("etm-verbs.el", include_str!("../lisp/etm-verbs.el")),
];

/// A short digest of the bundled sources (FNV-1a), so a cache directory
/// never serves files from another build.
pub fn digest() -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for (name, text) in FILES {
        for b in name.bytes().chain(text.bytes()) {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x0100_0000_01b3);
        }
    }
    format!("{h:016x}")
}

/// Write every bundled file into DIR (created when missing); returns
/// the paths written.
pub fn install(dir: &Path) -> io::Result<Vec<PathBuf>> {
    std::fs::create_dir_all(dir)?;
    FILES
        .iter()
        .map(|(name, text)| {
            let path = dir.join(name);
            std::fs::write(&path, text)?;
            Ok(path)
        })
        .collect()
}

/// Where [`materialize`] keeps the bundled files: under
/// `$XDG_CACHE_HOME` (else `~/.cache`), one directory per build.
pub fn cache_dir() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))?;
    Some(
        base.join("etm")
            .join(format!("lisp-{}-{}", env!("CARGO_PKG_VERSION"), digest())),
    )
}

/// The cache directory holding the bundled files, written on first use.
pub fn materialize() -> io::Result<PathBuf> {
    let dir = cache_dir().ok_or_else(|| io::Error::other("no HOME or XDG_CACHE_HOME"))?;
    let complete = FILES
        .iter()
        .all(|(name, text)| std::fs::read_to_string(dir.join(name)).is_ok_and(|t| t == *text));
    if !complete {
        // Write beside, then rename: a concurrent first call never loads
        // a half-written file.
        let tmp = dir.with_extension(format!("tmp{}", std::process::id()));
        install(&tmp)?;
        if std::fs::rename(&tmp, &dir).is_err() {
            let _ = std::fs::remove_dir_all(&tmp);
            install(&dir)?;
        }
    }
    Ok(dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_bundled_file_provides_its_feature() {
        for (name, text) in FILES {
            let feature = name.trim_end_matches(".el");
            assert!(
                text.contains(&format!("(provide '{feature})")),
                "{name} provides {feature}"
            );
        }
        assert_eq!(FILES[0].0, "etm.el");
    }

    #[test]
    fn install_writes_every_file() {
        let dir = tempfile::tempdir().unwrap();
        let written = install(&dir.path().join("lisp")).unwrap();
        assert_eq!(written.len(), FILES.len());
        assert!(dir.path().join("lisp/etm.el").is_file());
        assert_eq!(digest().len(), 16);
    }
}

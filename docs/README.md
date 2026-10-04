# etm docs

`etm.texi` is etm's manual, in Texinfo: overview, installation, quick
start, every option, the workspace backends, the extension points with a
worked example, the verb reference, the `etm.result/1` envelope and exit
codes, the global flags, the wire protocol, and troubleshooting, with
concept, function and variable indices.

```sh
makeinfo --no-split -o docs/etm.info docs/etm.texi
install-info docs/etm.info docs/dir   # then add docs/ to Info-additional-directory-list
```

MELPA, `package-vc-install` (`:doc "docs/etm.texi"`) and straight build
and register it for you: `C-h i m etm`. CI builds it and fails on any
makeinfo warning; `lisp/test/test-etm-manual.el` checks it against the
code.

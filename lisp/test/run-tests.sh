#!/bin/sh
# run-tests.sh -- etm's ERT suites.
#
#   run-tests.sh [unit] [single] [tab-bar] [tabspaces] [persp-mode]
#
# `unit' runs test-etm.el, test-etm-pane.el, test-etm-page.el and
# test-etm-manual.el (docs/etm.texi against the code) in one batch Emacs.  Each backend name runs test-etm-backend.el inside its own
# throwaway `emacs -Q --daemon' (private 0700 socket dir and HOME, killed
# afterwards) with that backend's mode turned on.  No argument runs all.
#
# persp-mode and tabspaces come from package.el: ETM_TEST_PACKAGE_DIR is a
# `package-user-dir' holding them (default: the user's ~/.emacs.d/elpa).
# A backend whose package is missing fails, unless ETM_TEST_SKIP_MISSING=1.
# EMACS and EMACSCLIENT pick the binaries.  When tmux is installed each
# daemon also gets a terminal client frame (`emacsclient -t' in a private
# `tmux -f /dev/null' server), since persp-mode ignores a daemon's own
# frame; ETM_TEST_FRAME=0 turns that off.
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
lisp=$(dirname -- "$here")
emacs=${EMACS:-emacs}
emacsclient=${EMACSCLIENT:-emacsclient}
pkgdir=${ETM_TEST_PACKAGE_DIR:-$HOME/.emacs.d/elpa}
[ $# -gt 0 ] || set -- unit single tab-bar tabspaces persp-mode

status=0

run_unit() {
    "$emacs" -Q --batch -L "$lisp" \
        -l "$here/test-etm.el" -l "$here/test-etm-pane.el" -l "$here/test-etm-page.el" \
        -l "$here/test-etm-manual.el" \
        -f ert-run-tests-batch-and-exit
}

# elisp string literal of $1
lit() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

run_backend() {
    backend=$1
    case $backend in
        persp-mode) setup='(progn (require (quote persp-mode)) (setq persp-auto-resume-time -1 persp-auto-save-opt 0) (persp-mode 1))' ;;
        tabspaces) setup='(progn (require (quote tabspaces)) (tabspaces-mode 1))' ;;
        tab-bar) setup='(tab-bar-mode 1)' ;;
        single) setup='nil' ;;
        *) echo "run-tests.sh: unknown backend $backend" >&2; return 2 ;;
    esac
    dir=$(mktemp -d /tmp/etm-ert.XXXXXX)
    chmod 700 "$dir"
    mkdir "$dir/home"
    sock="$dir/s"
    HOME="$dir/home" "$emacs" -Q --daemon="$sock" >"$dir/daemon.log" 2>&1 || {
        cat "$dir/daemon.log" >&2
        rm -rf "$dir"
        return 1
    }
    tmux_sock=
    if [ "${ETM_TEST_FRAME:-1}" = 1 ] && command -v tmux >/dev/null 2>&1; then
        tmux_sock="$dir/tmux"
        tmux -S "$tmux_sock" -f /dev/null new-session -d -x 200 -y 50 \
            "HOME='$dir/home' '$emacsclient' -t -s '$sock'"
        n=0
        while [ $n -lt 50 ]; do
            frames=$("$emacsclient" -s "$sock" --eval '(length (frame-list))' 2>/dev/null || echo 0)
            [ "$frames" -gt 1 ] && break
            sleep 0.1
            n=$((n + 1))
        done
    fi
    form="(progn
      (setq package-user-dir $(lit "$pkgdir"))
      (package-initialize)
      (setenv \"ETM_TEST_BACKEND\" $(lit "$backend"))
      (add-to-list (quote load-path) $(lit "$lisp"))
      (condition-case err $setup
        (error (with-temp-file $(lit "$dir/out") (insert (format \"setup failed: %S\nETM-RESULT $backend missing\n\" err)))))
      (unless (file-exists-p $(lit "$dir/out"))
        (load $(lit "$here/test-etm-backend.el") nil t)
        (etm-test-backend-run $(lit "$dir/out"))))"
    timeout 300 "$emacsclient" -s "$sock" --eval "$form" >/dev/null 2>&1 || true
    "$emacsclient" -s "$sock" --eval '(kill-emacs)' >/dev/null 2>&1 || true
    [ -z "$tmux_sock" ] || tmux -S "$tmux_sock" kill-server >/dev/null 2>&1 || true
    out=$(cat "$dir/out" 2>/dev/null || echo "ETM-RESULT $backend crashed")
    rm -rf "$dir"
    printf '%s\n' "$out" | grep -E '^ *(passed|FAILED|skipped)|^Ran |^ETM-RESULT|setup failed|condition:' || true
    [ "${ETM_TEST_VERBOSE:-0}" = 1 ] && printf '%s\n' "$out"
    result=$(printf '%s\n' "$out" | sed -n 's/^ETM-RESULT [^ ]* //p' | tail -1)
    case $result in
        0) return 0 ;;
        missing) [ "${ETM_TEST_SKIP_MISSING:-0}" = 1 ] && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

for what in "$@"; do
    echo "=== $what"
    if [ "$what" = unit ]; then
        run_unit || status=1
    else
        run_backend "$what" || status=1
    fi
done
exit $status

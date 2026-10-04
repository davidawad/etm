#!/usr/bin/env bash
# make-screenshots.sh -- regenerate every image in docs/images from scratch.
#
#   docs/showcase/make-screenshots.sh [--only PATTERN] [--keep-work]
#
# Every picture is a real render of a real session on synthetic demo data:
#
#   * Emacs frames: a plain `emacs -Q` (docs/showcase/init.el: a built-in dark
#     theme, one font, etm, and the workspace backend under test) on a
#     headless Xvfb display, exported to PNG with `x-export-frames`.
#   * CLI output: the real `etm` binary run against that Emacs, rendered with
#     charmbracelet freeze.
#
# Nothing of the machine it runs on leaks in: Emacs and the shell run with a
# private HOME in a temp dir, and the server socket lives under /tmp.
#
# Needs, on PATH or named by the variable in parentheses:
#   an X11 Emacs 29.1+ built with cairo   emacs-gtk or emacs-lucid  (ETM_SHOWCASE_EMACS)
#   Xvfb, emacsclient, curl                xvfb, emacs packages      (ETM_SHOWCASE_XVFB)
#   freeze                                 downloaded when missing   (ETM_SHOWCASE_FREEZE)
#   pngquant or oxipng                     image optimizer           (optional)
#   makeinfo (texinfo 6+)                  for the Info screenshots  (MAKEINFO)
#   cargo                                  builds the etm binary     (ETM_SHOWCASE_ETM skips it)
#   the JetBrains Mono font                fonts-jetbrains-mono      (else DejaVu Sans Mono)
# persp-mode, tabspaces and eat are installed from MELPA / NonGNU ELPA into a
# throwaway package directory (ETM_SHOWCASE_ELPA, default: inside the work dir).
#
# Debian/Ubuntu: apt install emacs-gtk xvfb fonts-jetbrains-mono texinfo pngquant
set -euo pipefail

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
root=$(CDPATH='' cd -- "$here/../.." && pwd -P)
images="$root/docs/images"

only=
keep=0
while [ $# -gt 0 ]; do
    case $1 in
        --only) only=$2; shift 2 ;;
        --keep-work) keep=1; shift ;;
        -h|--help) sed -n "2,/^set -euo/p" "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 0 ;;
        *) echo "make-screenshots: unknown argument $1" >&2; exit 2 ;;
    esac
done

die() { echo "make-screenshots: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }
want() {
    [ -z "$only" ] && return 0
    # shellcheck disable=SC2254 # $only is a glob pattern on purpose (--only foo*)
    case $1 in $only) return 0 ;; esac
    return 1
}

work=${ETM_SHOWCASE_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/etm-showcase.XXXXXX")}
mkdir -p "$work" "$images"
# The server socket is shown in `etm snapshot`; keep it short and generic.
run=/tmp/etm-showcase
EMACS=${ETM_SHOWCASE_EMACS:-emacs}
XVFB=${ETM_SHOWCASE_XVFB:-Xvfb}
display=${ETM_SHOWCASE_DISPLAY:-:97}
xvfb_pid=
emacs_pid=

cleanup() {
    [ -z "$emacs_pid" ] || kill "$emacs_pid" 2>/dev/null || true
    [ -z "$xvfb_pid" ] || kill "$xvfb_pid" 2>/dev/null || true
    rm -rf "$run"
    [ "$keep" = 1 ] || [ -n "${ETM_SHOWCASE_WORK:-}" ] || rm -rf "$work"
}
trap cleanup EXIT INT TERM

#### tools ##################################################################

command -v "$EMACS" >/dev/null || die "no Emacs ($EMACS); see the header for what is needed"
command -v "$XVFB" >/dev/null || die "no Xvfb ($XVFB)"
command -v emacsclient >/dev/null || die "no emacsclient"
"$EMACS" -Q --batch --eval '(unless (string-match-p "CAIRO" system-configuration-features) (kill-emacs 3))' \
    >/dev/null 2>&1 || die "$EMACS is not built with cairo (x-export-frames needs it); use emacs-gtk or emacs-lucid"

freeze=${ETM_SHOWCASE_FREEZE:-}
if [ -z "$freeze" ]; then
    if command -v freeze >/dev/null 2>&1; then
        freeze=$(command -v freeze)
    else
        v=0.2.2
        log "downloading freeze $v"
        mkdir -p "$work/freeze"
        curl -fsSL "https://github.com/charmbracelet/freeze/releases/download/v$v/freeze_${v}_Linux_x86_64.tar.gz" |
            tar -xz -C "$work/freeze"
        freeze=$(find "$work/freeze" -name freeze -type f | head -1)
    fi
fi

# The etm binary: built from the standalone tree (this one, or a fresh export
# of the repository this tree lives in).
etm_bin=${ETM_SHOWCASE_ETM:-}
if [ -z "$etm_bin" ]; then
    command -v cargo >/dev/null || die "no cargo to build etm (or set ETM_SHOWCASE_ETM)"
    tree=$root
    if [ ! -f "$root/Cargo.toml" ]; then
        exporter=$(CDPATH='' cd -- "$root/../../../.." && pwd -P)/scripts/etm-export
        [ -x "$exporter" ] || die "no Cargo.toml here and no scripts/etm-export above"
        log "exporting the standalone tree"
        "$exporter" --no-git "$work/tree" >/dev/null
        tree=$work/tree
    fi
    log "building etm"
    CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$work/target} cargo build --release --manifest-path "$tree/Cargo.toml" >&2
    etm_bin=${CARGO_TARGET_DIR:-$work/target}/release/etm
fi
mkdir -p "$work/bin"
cp "$etm_bin" "$work/bin/etm"
PATH="$work/bin:$PATH"
export PATH

# Throwaway package directory: the backends under test, and the eat terminal.
elpa=${ETM_SHOWCASE_ELPA:-$work/elpa}
if ! ls -d "$elpa"/eat-* >/dev/null 2>&1; then
    log "installing persp-mode, tabspaces and eat into $elpa"
    "$EMACS" -Q --batch --eval "(progn
      (require 'package)
      (setq package-user-dir \"$elpa\"
            package-archives '((\"melpa\" . \"https://melpa.org/packages/\")
                               (\"gnu\" . \"https://elpa.gnu.org/packages/\")
                               (\"nongnu\" . \"https://elpa.nongnu.org/nongnu/\")))
      (package-initialize)
      (package-refresh-contents)
      (dolist (p '(persp-mode tabspaces eat)) (package-install p)))" >&2
fi

# The Info manual, for the Info screenshots.
info_dir=$work/info
mkdir -p "$info_dir"
makeinfo=${MAKEINFO:-makeinfo}
if command -v "$makeinfo" >/dev/null 2>&1; then
    "$makeinfo" --no-split -o "$info_dir/etm.info" "$root/docs/etm.texi"
    printf 'This is the top of the Info tree.\n\n\037\nFile: dir,\tNode: Top\tThis is the top of the INFO tree\n\n' >"$info_dir/dir"
    printf '* Menu:\n\nEmacs misc features\n' >>"$info_dir/dir"
    printf '* etm: (etm).           Emacs Terminal Manager: drive Emacs as JSON verbs.\n' >>"$info_dir/dir"
else
    log "no makeinfo: the Info screenshots are skipped"
    info_dir=
fi

#### display and the demo Emacs #############################################

log "starting Xvfb on $display"
"$XVFB" "$display" -screen 0 1400x900x24 >"$work/xvfb.log" 2>&1 &
xvfb_pid=$!
for _ in $(seq 50); do [ -S "/tmp/.X11-unix/X${display#:}" ] && break; sleep 0.2; done
[ -S "/tmp/.X11-unix/X${display#:}" ] || die "Xvfb did not start: $(cat "$work/xvfb.log")"
DISPLAY=$display
export DISPLAY

# up BACKEND: a fresh Emacs (and a fresh private HOME) on that backend.
up() {
    down
    rm -rf "$run"
    mkdir -p "$run/home/project"
    chmod 700 "$run"
    home=$run/home
    printf 'PS1="\\w\\$ "\n' >"$home/.bashrc"
    cat >"$home/project/app.py" <<'PY'
"""A small demo service."""
import json
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def summarize(items):
    total = sum(item["count"] for item in items)
    return {"items": len(items), "total": total}


if __name__ == "__main__":
    print(summarize(load(sys.argv[1])))
PY
    cat >"$home/project/run-tests.sh" <<'SH'
#!/bin/sh
sleep 0.5
for t in parse load summarize render export; do
    echo "test $t ... ok"
    sleep 0.3
done
echo "test result: ok. 5 passed; 0 failed"
SH
    chmod +x "$home/project/run-tests.sh"
    printf 'build\nlint\ntest\n' >"$home/project/TODO.txt"
    HOME=$home SHELL=/bin/bash \
        ETM_SHOWCASE_LISP=$root/lisp ETM_SHOWCASE_ELPA=$elpa \
        ETM_SHOWCASE_BACKEND=$1 ETM_SHOWCASE_SOCKET=$run/server \
        ETM_SHOWCASE_INFO=$info_dir \
        "$EMACS" -Q -l "$here/init.el" >"$run/emacs.log" 2>&1 &
    emacs_pid=$!
    for _ in $(seq 150); do [ -S "$run/server" ] && break; sleep 0.2; done
    [ -S "$run/server" ] || die "Emacs did not come up: $(cat "$run/emacs.log")"
    ETM_SOCKET=$run/server
    export ETM_SOCKET HOME=$home
    # Make sure etm answers (and has loaded) before the first picture.
    etm --json snapshot --fields backend >/dev/null
}

down() {
    [ -z "$emacs_pid" ] || { kill "$emacs_pid" 2>/dev/null || true; wait "$emacs_pid" 2>/dev/null || true; }
    emacs_pid=
}

el() { emacsclient -s "$run/server" --eval "$1" >/dev/null; }

#### pictures ###############################################################

optimize() {
    if command -v pngquant >/dev/null 2>&1; then
        pngquant --force --skip-if-larger --quality 70-95 --output "$1" "$1" 2>/dev/null || true
    elif command -v oxipng >/dev/null 2>&1; then
        oxipng -q -o 4 --strip safe "$1" || true
    fi
    size=$(wc -c <"$1")
    [ "$size" -le 300000 ] || echo "make-screenshots: $1 is $size bytes (over 300000)" >&2
}

# frame NAME: the selected Emacs frame, as docs/images/NAME.png.
frame() {
    want "$1" || return 0
    log "frame $1"
    sleep 0.4
    el "(showcase-shot \"$images/$1.png\")"
    optimize "$images/$1.png"
}

# freeze's built-in JetBrains Mono draws "|-" and "->" as ligatures, which
# garbles CLI text.  The no-ligature build (fonts-jetbrains-mono ships it as
# JetBrainsMonoNL) is found through freeze's own HOME, a private font dir.
nl_dir=
for d in "${ETM_SHOWCASE_FONT_DIR:-}" /usr/share/fonts/truetype/jetbrains-mono; do
    [ -n "$d" ] && [ -f "$d/JetBrainsMonoNL-Regular.ttf" ] && { nl_dir=$d; break; }
done
freeze_home=$work/freeze-home
if [ -n "$nl_dir" ]; then
    mkdir -p "$freeze_home/.local/share/fonts"
    cp "$nl_dir"/JetBrainsMonoNL-*.ttf "$freeze_home/.local/share/fonts/"
    font_family="JetBrains Mono NL"
else
    log "no JetBrainsMonoNL font: CLI text may show ligatures"
    font_family="JetBrains Mono"
fi

run_freeze() { # OUT: reads the transcript on stdin
    HOME=$freeze_home "$freeze" --language ansi --theme dracula --background '#1e1e2e' \
        --window --width 1400 --padding 24,28 --margin 0 \
        --font.family "$font_family" --font.size 15 --line-height 1.3 --wrap 120 \
        -o "$1" >/dev/null
}

# A terminal transcript: term_begin NAME; term_run 'etm ...'; ...; term_end.
# Each command is run in a pty, as at a terminal, so the output is what a
# person sees; $LAST holds the last output.
term_begin() { tname=$1; tfile=$work/$1.txt; : >"$tfile"; LAST=; }
term_run() {
    printf '\033[1;32m$\033[0m \033[1m%s\033[0m\n' "$1" >>"$tfile"
    out=$(script -qec "stty cols 130; $1" /dev/null </dev/null 2>&1 | tr -d '\r' || true)
    LAST=$out
    printf '%s\n\n' "$out" >>"$tfile"
}
term_end() {
    want "$tname" || return 0
    log "terminal $tname"
    run_freeze "$images/$tname.png" <"$tfile"
    optimize "$images/$tname.png"
}

# term NAME CMD...: a transcript of independent commands.
term() { n=$1; shift; term_begin "$n"; for c in "$@"; do term_run "$c"; done; term_end; }

cursor() { printf '%s' "$LAST" | grep -o 'c1:[0-9a-f]*:[0-9]*' | head -1; }

# The reference layout: an editor, a terminal docked at the bottom and a
# page docked at the right, in workspace $1.
layout() {
    w=$1
    etm pane new "$w" ed --kind editor --path "$HOME/project/app.py" >/dev/null
    etm pane focus "$w/ed" >/dev/null
    etm pane new "$w" sh --kind shell --backend eat --region bottom --path "$HOME/project" >/dev/null
    etm pane new "$w" dash --kind page --page dashboard --region right >/dev/null
    sleep 0.6
}

#### the main session: tab-bar ##############################################

up tab-bar

case $only in backend-*) ;; *)

    term help 'etm --help'

    # Workspaces.
    term_begin ws-lifecycle
    term_run "etm --json --fields name,current,panes ws ls"
    term_run "etm --json --fields name,current,created ws new review --switch"
    term_run "etm --json --fields name,current,created ws new notes"
    term_run "etm --json --fields name,current ws switch notes"
    term_run "etm --json --fields name,current ws rename notes docs"
    term_run "etm --json --fields name,current,panes ws ls"
    term_run "etm --json --fields name,killed ws kill docs"
    term_end
    # Panes, one of each kind.
    term_begin pane-new
    term_run "etm --json --fields addr,kind,region,mode pane new review ed --kind editor --path ~/project/app.py"
    term_run "etm --json --fields addr,kind,region,mode pane focus review/ed"
    term_run "etm --json --fields addr,kind,region,mode pane new review sh --kind shell --backend eat --region bottom --path ~/project"
    term_run "etm --json --fields addr,kind,region,mode,page_state pane new review dash --kind page --page dashboard --region right"
    term_run "etm --json --fields addr,kind,region,mode,visible pane ls"
    term_end
    sleep 0.6
    frame pane-layout

    # The workspace frames: three more workspaces, then a rename and a kill.
    etm ws new docs --switch >/dev/null
    etm pane new docs tree --kind tree --path "$HOME/project" >/dev/null
    etm pane focus docs/tree >/dev/null
    etm ws new api --switch >/dev/null
    etm pane new api ed --kind editor --path "$HOME/project/run-tests.sh" >/dev/null
    etm pane focus api/ed >/dev/null
    etm ws switch review >/dev/null
    frame ws-tabs
    etm ws switch docs >/dev/null
    etm ws rename docs guide >/dev/null
    etm ws kill api >/dev/null
    frame ws-tabs-after
    etm ws switch review >/dev/null

    # A second workspace with the other kinds.
    etm ws new tour --switch >/dev/null
    etm pane new tour tree --kind tree --path "$HOME/project" --region left >/dev/null
    etm pane new tour log --kind cmd --cmd 'cd ~/project && cat TODO.txt && ls' >/dev/null
    etm pane focus tour/log >/dev/null
    etm pane new tour esh --kind shell --region bottom --path "$HOME/project" >/dev/null
    etm send tour/esh 'ls' --enter >/dev/null
    sleep 0.8
    frame pane-kinds-more
    etm ws kill tour >/dev/null
    etm ws switch review >/dev/null

    # The snapshot, and the frame it describes.
    term snapshot-cli "etm --json --fields emacs,backend,current,workspaces snapshot" \
        "etm --json --fields addr,kind,region,mode,running,visible pane ls"
    frame snapshot-frame

    # send and capture, with cursors.
    el "(showcase-reset-windows)"
    etm ws new work --switch >/dev/null
    etm pane new work sh --kind shell --backend eat --path "$HOME/project" >/dev/null
    etm pane focus work/sh >/dev/null
    sleep 0.6
    frame send-before
    term_begin send-capture
    term_run "etm --json --fields addr,chars,cursor send work/sh 'ls && wc -l app.py' --enter"
    c=$(cursor)
    sleep 0.6
    term_run "etm --json --fields text,cursor capture work/sh --since $c"
    term_end
    frame send-after

    # wait --until match.
    term_begin wait-match
    term_run "etm --json --fields addr,chars,cursor send work/sh './run-tests.sh' --enter"
    term_run "etm --json --fields addr,until,elapsed_ms,match wait work/sh --until match:'test result' --timeout 30s"
    term_run "etm --json --fields text capture work/sh --lines 8"
    term_end
    frame wait-after

    term doctor "etm --robot-format=toon --fields healthy,rows doctor"
    term events "etm --robot-format=toon events --limit 6"
    term robot-toon "etm --robot-format=toon --fields addr,kind,region,mode,running pane ls --all"
    term robot-markdown "etm --robot-markdown --fields addr,kind,region,mode,running pane ls --all"

    # The Info manual.
    if [ -n "$info_dir" ]; then
        el "(progn (showcase-reset-windows) (Info-directory) (goto-char (point-min)) (search-forward \"* etm\") (beginning-of-line))"
        frame info-dir
        el "(progn (Info-goto-node \"(etm)Quick Start\") (goto-char (point-min)))"
        frame info-etm
    fi
;; esac

#### the four backends ######################################################

for b in persp-mode tab-bar tabspaces single; do
    want "backend-$b*" || continue
    up "$b"
    if [ "$b" = single ]; then
        w=global
        term_begin "backend-$b-cli"
        term_run "etm --json --fields name,current,panes ws ls"
        term_run "etm --json ws new review"
        term_end
    else
        w=review
        term_begin "backend-$b-cli"
        term_run "etm --json --fields name,current,panes ws ls"
        term_run "etm --json --fields name,current,created ws new review --switch"
        term_end
    fi
    layout "$w"
    frame "backend-$b"
    down
done

log "done: $(find "$images" -maxdepth 1 -name "*.png" | wc -l | tr -d " ") images in $images"

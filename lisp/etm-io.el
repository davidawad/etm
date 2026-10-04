;;; etm-io.el --- Pane I/O for etm: send, capture with cursors, wait -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; URL: https://github.com/davidawad/etm
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Talking to a pane resolved by etm-pane.el.  Capture cursors are
;; `c1:<buffer id>:<char pos>': the second read returns only what
;; arrived since.  A cursor from a different buffer object (the pane was
;; recreated) or past the end (the buffer was cleared) resets to the
;; start, with a warning.
;;
;; `wait' never blocks Emacs for longer than the caller's TIMEOUT; the
;; etm CLI polls with TIMEOUT 0 so the session stays responsive, and
;; marks such polls `poll' so only the deciding check is logged as an
;; event (the dispatcher honors `:quiet').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etm-base)
(require 'etm-ext)
(require 'etm-pane)

(defvar eat-terminal)
(declare-function eshell-send-input "esh-mode"
                  (&optional use-region queue-p no-newline))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function vterm-send-string "vterm"
                  (string &optional paste-p))
(declare-function vterm-send-return "vterm" ())
(declare-function comint-send-input "comint"
                  (&optional no-newline artificial))
(declare-function term-send-string "term" (proc str))

;;;; Send and capture

(defun etm-pane-send (addr text enter)
  "Type TEXT into the terminal pane at ADDR; submit it when ENTER."
  (let* ((hit (etm-pane-resolve addr))
         (buf (cdr hit))
         (cursor (etm-pane-cursor buf)))
    (with-current-buffer buf
      (let ((proc (get-buffer-process buf)))
        (cond
         ((derived-mode-p 'eshell-mode)
          (goto-char (point-max))
          (insert text)
          (when enter
            (eshell-send-input)))
         ((bound-and-true-p eat-terminal)
          (eat-term-send-string
           eat-terminal
           (if enter
               (concat text "\r")
             text)))
         ((derived-mode-p 'vterm-mode)
          (vterm-send-string text)
          (when enter
            (vterm-send-return)))
         ((and proc (derived-mode-p 'comint-mode))
          (goto-char (point-max))
          (insert text)
          (when enter
            (comint-send-input)))
         ((and proc (derived-mode-p 'term-mode))
          (term-send-string
           proc
           (if enter
               (concat text "\r")
             text)))
         (proc
          (process-send-string
           proc
           (if enter
               (concat text "\n")
             text)))
         (t
          (etm-fail
           "pane.not_terminal"
           (format "pane `%s' has no terminal or process" addr)
           :hint "send targets shell/cmd panes")))))
    (etm-next
     (format "etm wait %s --until idle" addr)
     (format "etm capture %s --since %s" addr cursor)
     (format "etm wait %s --until match:REGEXP --since %s"
             addr cursor))
    (list
     :addr addr
     :chars (length text)
     :enter
     (if enter
         t
       :false)
     :cursor cursor)))

(defun etm-pane--start (buffer since)
  "Start position in BUFFER for cursor SINCE (nil = start); warns on reset."
  (if (null since)
      1
    (let ((c (etm-cursor-parse since)))
      (cond
       ((not (equal (car c) (etm-resource-buffer-id buffer)))
        (etm-warn
         "capture.cursor_reset"
         "cursor is from another buffer; reading from start")
        1)
       ((> (cdr c)
           (with-current-buffer buffer
             (point-max)))
        (etm-warn
         "capture.cursor_reset"
         "buffer shrank past the cursor; reading from start")
        1)
       (t
        (max 1 (cdr c)))))))

(defun etm-pane-capture (addr since lines max-chars)
  "Text of the pane at ADDR after cursor SINCE, and the cursor after it.
The text is tail-limited by LINES and MAX-CHARS; pass the cursor
returned to the next capture."
  (let* ((buf (cdr (etm-pane-resolve addr)))
         (from (etm-pane--start buf since)))
    (with-current-buffer buf
      (let* ((to (point-max))
             (text (buffer-substring-no-properties from to))
             (full (length text)))
        (when (and lines (> lines 0))
          (let ((parts (split-string text "\n")))
            (when (> (length parts) lines)
              (setq text (string-join (last parts lines) "\n")))))
        (when (and max-chars (> (length text) max-chars))
          (setq text (substring text (- (length text) max-chars))))
        (list
         :addr addr
         :text text
         :from from
         :to to
         :truncated
         (if (< (length text) full)
             t
           :false)
         :cursor (etm-pane-cursor buf to))))))

;;;; Wait

(defun etm-pane--check (buf until re from idle-ms)
  "Return a plist when condition UNTIL is met in BUF now, else nil.
RE is the `match' regexp searched from FROM; IDLE-MS the `idle' quiet time."
  (pcase until
    ("idle"
     (let ((quiet (- (float-time) (etm-pane-track buf))))
       (and (>= (* 1000 quiet) idle-ms)
            (list :idle_ms (round (* 1000 quiet))))))
    ("exit"
     (and (not (etm-pane-running-p buf))
          (let ((proc
                 (or (get-buffer-process buf)
                     (buffer-local-value 'etm-pane--process buf))))
            (list
             :exit_status
             (if proc
                 (process-exit-status proc)
               :null)))))
    ("match"
     (with-current-buffer buf
       (save-excursion
         (goto-char (min from (point-max)))
         (and (re-search-forward re nil t)
              (list
               :match (match-string-no-properties 0)
               :cursor (etm-pane-cursor buf (match-end 0)))))))))

(defun etm-pane-wait (args)
  "Block up to ARGS' timeout until the pane meets ARGS' `until' condition.
`until' is `idle', `exit' or `match:REGEXP' (an Emacs regexp searched
from `since', default the pane's end when the wait began -- so to catch
output a `send' already produced, pass the cursor `send' returned)."
  (let* ((addr (etm-arg-string args :addr t))
         (buf (cdr (etm-pane-resolve addr)))
         (spec (etm-arg-string args :until t))
         (until
          (if (string-prefix-p "match:" spec)
              "match"
            spec))
         (re (and (equal until "match") (substring spec 6)))
         (timeout (etm-arg-number args :timeout 30))
         (idle-ms (etm-arg-number args :idle_ms 1000))
         (since (etm-arg-string args :since))
         (from
          (if since
              (etm-pane--start buf since)
            (with-current-buffer buf
              (point-max))))
         (start (float-time))
         (deadline (+ start timeout))
         hit)
    (unless (member until '("idle" "exit" "match"))
      (etm-fail
       "usage.bad_arg"
       (format "bad --until `%s'" spec)
       :hint "--until idle|exit|match:REGEXP"))
    (when (and re (string-empty-p re))
      (etm-fail "usage.bad_arg" "match: needs a regexp"))
    (while (and (buffer-live-p buf)
                (not
                 (setq hit
                       (etm-pane--check
                        buf until re from idle-ms)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (unless (buffer-live-p buf)
      (if (equal until "exit")
          (setq hit (list :exit_status :null :killed t))
        (etm-fail
         "not_found.pane"
         (format "pane `%s' was killed while waiting" addr))))
    (let ((data
           (append
            (list
             :addr addr
             :until spec
             :elapsed_ms (round (* 1000 (- (float-time) start))))
            (if (buffer-live-p buf)
                (list :cursor (etm-pane-cursor buf))
              (list :cursor :null))
            hit)))
      (unless hit
        (etm-fail
         "wait.timeout"
         (format "`%s' not met for %s within %ss" spec addr timeout)
         :retryable t
         :data data
         :quiet
         (and (etm-arg-bool args :poll)
              (not (etm-arg-bool args :final)))))
      (when (buffer-live-p buf)
        (etm-next
         (format "etm capture %s --since %s"
                 addr
                 (etm-pane-cursor buf from))))
      data)))

(provide 'etm-io)
;;; etm-io.el ends here

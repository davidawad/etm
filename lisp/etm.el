;;; etm.el --- Drive workspaces, panes and terminals as JSON verbs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; Maintainer: David Awad <davidawad@protonmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/davidawad/etm
;; Keywords: tools, processes, terminals
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; etm is the Emacs half of a control plane: an external program (the
;; `etm' CLI, or any client that can reach the Emacs server) names a
;; verb, and Emacs answers with one JSON envelope.  One entry point:
;;
;;   (etm-rpc REQUEST-BASE64) -> RESPONSE-BASE64
;;
;; REQUEST is UTF-8 JSON {"v":1,"verb":"pane.new","args":{...}}, base64
;; wrapped so no caller ever quotes an Elisp string.  RESPONSE is the
;; `etm.result/1' envelope:
;;
;;   {"schema": "etm.result/1", "ok": true, "verb": "...", "data": ...,
;;    "rev": ..., "warnings": [...], "errors": [...], "next": [...],
;;    "events": [...]}
;;
;; base64 wrapped the same way so the reply survives server.el's
;; framing byte for byte.  `etm-rpc-json' is the same call with plain
;; JSON strings, for in-process callers.
;;
;; The verb table `etm-verbs' is closed: an unknown verb is a typed
;; usage error, never an eval.  Workspaces come from whichever backend
;; is in effect (`etm-workspace-backend': persp-mode, tab-bar,
;; tabspaces, or one global workspace).  Pane identity, docking, page
;; types, doctor rows and the event store are extension points with
;; working defaults (etm-ext.el, etm-page.el).  `eval' is the one
;; escape hatch: logged and flagged, never offered in `next'.
;;
;; Handlers never signal past `etm-dispatch': a failure is an envelope
;; with `ok' false, because server.el answers an escaped error by
;; sleeping two seconds in the user's session.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etm-base)
(require 'etm-backend)
(require 'etm-persp)
(require 'etm-tab-bar)
(require 'etm-tabspaces)
(require 'etm-ext)
(require 'etm-ws)
(require 'etm-page)
(require 'etm-pane)
(require 'etm-io)
(require 'etm-verbs)

(defconst etm-version "0.1.0"
  "Version of the etm package.")

(defconst etm-verbs
  '(("snapshot" etm--v-snapshot read
     "whole session: workspaces, panes, windows, registry, events")
    ("capabilities" etm--v-capabilities read "verbs, kinds, regions, backends")
    ("ws.ls" etm--v-ws-ls read "list workspaces")
    ("ws.get" etm--v-ws-get read "one workspace with its panes")
    ("ws.new" etm--v-ws-new write "create workspace (idempotent)")
    ("ws.switch" etm--v-ws-switch write "show workspace in the selected frame")
    ("ws.rename" etm--v-ws-rename write "relabel workspace (identity unchanged)")
    ("ws.kill" etm--v-ws-kill write "kill workspace and reap its panes")
    ("pane.ls" etm--v-pane-ls read "list panes of a workspace (\"*\" = all)")
    ("pane.new" etm--v-pane-new write "create pane KEY of KIND (idempotent)")
    ("pane.kill" etm--v-pane-kill write "kill pane")
    ("pane.focus" etm--v-pane-focus write "bring pane to the selected window")
    ("send" etm--v-send write "type text into a terminal pane")
    ("capture" etm--v-capture read "pane text since a cursor")
    ("wait" etm--v-wait read "until idle|exit|match:RE")
    ("doctor" etm--v-doctor read "invariant probes, plus `etm-doctor-functions'")
    ("events" etm--v-events read "events since a time or event id")
    ("eval" etm--v-eval write "escape hatch: evaluate a form (logged)"))
  "The closed verb table: (VERB HANDLER READ-OR-WRITE SUMMARY).
HANDLER takes the request's args plist and returns the envelope data.")

(defconst etm-planned-verbs '("apply")
  "Verbs of the shared vocabulary etm will answer in a later version.")

;;;; Envelope

(defun etm--rev ()
  "Digest of the observed workspace and pane state, for `--if-rev'."
  (concat "sha1:"
          (substring
           (sha1 (prin1-to-string
                  (mapcar (lambda (ws)
                            (cons (etm-ws-id ws)
                                  (cons (etm-ws-name ws)
                                        (mapcar (lambda (b)
                                                  (cons (buffer-local-value 'etm-pane-key b)
                                                        (etm-resource-buffer-id b)))
                                                (etm-pane-buffers ws)))))
                          (etm-ws-all))))
           0 16)))

(defun etm--target (args)
  "The pane address or workspace ARGS names, for the event message, or nil."
  (let ((v (ignore-errors (or (plist-get args :addr) (plist-get args :ws)))))
    (and (stringp v) (not (string-empty-p v)) v)))

(defun etm--log (verb ok code ms quiet &optional target)
  "Record the event for one call of VERB; return its id, or nil when QUIET.
OK, CODE and MS are its outcome, error code and duration.  TARGET (a
pane address or workspace) follows the verb, so a reader can tell which
workspace a call touched.  Typed errors log at `info'; only an
`internal.error' (a handler bug) logs at `warn'."
  (unless quiet
    (plist-get
     (etm-event-log (cond ((equal code "internal.error") 'warn)
                          ((or (not ok) (equal verb "eval")) 'info)
                          (t 'debug))
                    "%s%s %s%s (%.1fms)" verb (if target (concat " " target) "")
                    (if ok "ok" "error ") (or code "") ms)
     :id)))

(defun etm--error-entry (err)
  "Envelope `errors' entry for ERR (an `etm-error' plist)."
  (list :code (plist-get err :code)
        :msg (plist-get err :msg)
        :hint (plist-get err :hint)
        :surface "emacs"
        :retryable (if (plist-get err :retryable) t :false)))

(defun etm--run (request)
  "Run REQUEST's handler; return (DATA . ERR), never signaling."
  (let* ((verb (plist-get request :verb))
         (entry (and (stringp verb) (assoc verb etm-verbs))))
    (condition-case e
        (cons
         (cond
          ((plist-get request :bad)
           (etm-fail "usage.bad_request"
                     (format "request is not base64 UTF-8 JSON: %s"
                             (plist-get request :bad))))
          ((not (eql (or (plist-get request :v) etm-protocol) etm-protocol))
           (etm-fail "usage.protocol"
                     (format "protocol %s unsupported" (plist-get request :v))
                     :hint (format "this etm speaks protocol %d" etm-protocol)))
          ((null entry)
           (etm-fail "usage.unknown_verb" (format "unknown verb `%s'" verb)
                     :hint "etm capabilities"))
          (t (funcall (nth 1 entry) (plist-get request :args))))
         nil)
      (etm-error (cons nil (cadr e)))
      (error (cons nil (list :code "internal.error"
                             :msg (error-message-string e)))))))

(defun etm-dispatch (request)
  "Run REQUEST (a parsed plist) through the verb table; return an envelope.
Never signals."
  (let* ((verb (plist-get request :verb))
         (args (plist-get request :args))
         (etm--warnings nil)
         (etm--next nil)
         (t0 (float-time))
         (result (etm--run request))
         (data (car result))
         (err (cdr result))
         (ms (* 1000 (- (float-time) t0)))
         (ev (ignore-errors
               (etm--log (or verb "?") (null err) (plist-get err :code) ms
                         (plist-get err :quiet) (etm--target args)))))
    (list :schema etm-schema
          :ok (if err :false t)
          :verb (or verb :null)
          :data (if err (or (plist-get err :data) :null) (or data :null))
          :rev (if (and (not err) (member verb '("snapshot" "ws.ls" "pane.ls")))
                   (ignore-errors (etm--rev))
                 :null)
          :warnings (vconcat (reverse etm--warnings))
          :errors (if err (vector (etm--error-entry err)) [])
          :next (vconcat (seq-take (reverse etm--next) 3))
          :events (if ev (vector ev) [])
          :elapsed_ms (/ (round (* ms 10)) 10.0))))

(defun etm--encode (envelope)
  "ENVELOPE as a unibyte UTF-8 JSON string."
  (etm-json-encode (etm-json-safe envelope)))

(defun etm-rpc-json (request-json)
  "Answer REQUEST-JSON (a JSON string) with the envelope as a JSON string."
  (let ((request (condition-case e
                     (etm-json-decode request-json)
                   (error (list :bad (error-message-string e))))))
    (decode-coding-string (etm--encode (etm-dispatch request)) 'utf-8)))

(defun etm-rpc (request-base64)
  "The etm entry point: REQUEST-BASE64 (UTF-8 JSON) in, base64 envelope out."
  (let ((request (condition-case e
                     (etm-json-decode
                      (decode-coding-string (base64-decode-string request-base64)
                                            'utf-8))
                   (error (list :bad (error-message-string e))))))
    (base64-encode-string (etm--encode (etm-dispatch request)) t)))

(provide 'etm)
;;; etm.el ends here

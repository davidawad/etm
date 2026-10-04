;;; etm-verbs.el --- Verb handlers for etm: observation, health, trail -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; URL: https://github.com/davidawad/etm
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The handlers `etm-verbs' (etm.el) dispatches to.  Each takes the
;; request's args plist and returns the envelope's data, signaling
;; `etm-fail' for typed errors.  Workspace and pane mechanics live in
;; etm-ws.el, etm-pane.el and etm-io.el; this file only maps arguments
;; onto them, plus the verbs that read the session as a whole:
;; snapshot, capabilities, doctor, events and the eval escape hatch.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etm-base)
(require 'etm-backend)
(require 'etm-ext)
(require 'etm-ws)
(require 'etm-pane)
(require 'etm-io)
(require 'etm-page)

(defvar server-process)
(defvar server-name)

(defcustom etm-allow-eval t
  "Non-nil lets the `eval' escape-hatch verb run arbitrary forms."
  :type 'boolean
  :group 'etm)

(defvar etm-verbs)
(defvar etm-planned-verbs)

;;;; Observation

(defun etm--windows ()
  "Live windows of the selected frame, tagged with their pane key."
  (vconcat
   (mapcar (lambda (w)
             (let ((b (window-buffer w)))
               (list :buffer (buffer-name b)
                     :pane (or (buffer-local-value 'etm-pane-key b) :null)
                     :side (or (window-parameter w 'window-side) :null)
                     :slot (or (window-parameter w 'window-slot) :null)
                     :selected (if (eq w (selected-window)) t :false))))
           (window-list))))

(defun etm--snapshot-extra (snap)
  "SNAP plus the sections `etm-snapshot-functions' add."
  (dolist (fn etm-snapshot-functions snap)
    (let ((extra (ignore-errors (funcall fn))))
      (while extra
        (let ((k (pop extra)) (v (pop extra)))
          (unless (plist-member snap k)
            (setq snap (append snap (list k v)))))))))

(defun etm--v-snapshot (args)
  "The whole session in one read; ARGS `fields' names the keys to keep."
  (let* ((snap (etm--snapshot-extra
                (list :emacs (list :version emacs-version
                                   :pid (emacs-pid)
                                   :daemon (if (daemonp) t :false)
                                   :server (and (boundp 'server-name) server-name))
                      :backend (symbol-name (etm-backend))
                      :current (etm-ws-name (etm-ws-current))
                      :workspaces (vconcat
                                   (mapcar (lambda (ws)
                                             (etm-ws-record
                                              ws (length (etm-pane-buffers ws))))
                                           (etm-ws-all)))
                      :panes (etm-pane-ls "*")
                      :windows (etm--windows)
                      :namespace (etm-resource-snapshot)
                      :events (vconcat (reverse (last (etm-event-list) 10))))))
         (fields (etm-arg args :fields)))
    (etm-next "etm pane ls" "etm events")
    (if (not fields)
        snap
      (cl-loop for (k v) on snap by #'cddr
               when (member (substring (symbol-name k) 1) (append fields nil))
               append (list k v)))))

(defun etm--v-capabilities (_args)
  "Self-description: the verb table, kinds, regions and backends."
  (list :schema etm-schema
        :protocol etm-protocol
        :surface "emacs"
        :verbs (vconcat (mapcar (lambda (e)
                                  (list :verb (car e)
                                        :mode (symbol-name (nth 2 e))
                                        :summary (nth 3 e)))
                                etm-verbs))
        :planned (vconcat etm-planned-verbs)
        :kinds (vconcat etm-pane-kinds)
        :unsupported_kinds ["agent"]
        :regions (vconcat etm-pane-regions)
        :backends (vconcat (delq nil (list "eshell" "comint"
                                           (and (fboundp 'eat-make) "eat"))))
        :workspaces (symbol-name (etm-backend))
        :workspace_backends (vconcat (mapcar #'symbol-name
                                             etm-workspace-backend-candidates))
        :layout (format "%s" etm-layout-dock-function)
        :pages (vconcat (etm-page-names))
        :eval (if etm-allow-eval t :false)))

(defun etm--v-ws-ls (_args)
  "Every workspace."
  (vconcat (mapcar (lambda (ws) (etm-ws-record ws (length (etm-pane-buffers ws))))
                   (etm-ws-all))))

(defun etm--v-ws-get (args)
  "One workspace (ARGS `ws', default current) with its panes."
  (let ((ws (etm-ws-resolve (etm-arg-string args :ws))))
    (append (etm-ws-record ws (length (etm-pane-buffers ws)))
            (list :pane_list (etm-pane-ls (etm-ws-name ws))))))

(defun etm--v-ws-new (args)
  "ARGS: `ws' name, optional `subject', `switch', `spec', `owner', `adopt'."
  (etm-ws-new (etm-arg-string args :ws t)
              (etm-arg-string args :subject)
              (etm-arg-bool args :switch)
              (etm-arg-string args :spec)
              (etm-arg-string args :owner)
              (etm-arg-string args :adopt)))

(defun etm--v-ws-switch (args)
  "ARGS: `ws'."
  (etm-ws-switch (etm-ws-resolve (etm-arg-string args :ws t))))

(defun etm--v-ws-rename (args)
  "ARGS: `ws', `name'."
  (etm-ws-rename (etm-ws-resolve (etm-arg-string args :ws t))
                 (etm-arg-string args :name t)))

(defun etm--v-ws-kill (args)
  "ARGS: `ws'."
  (etm-ws-kill (etm-ws-resolve (etm-arg-string args :ws t)) #'etm-pane-reap))

(defun etm--v-pane-ls (args)
  "ARGS: optional `ws' (\"*\" = every workspace)."
  (etm-pane-ls (etm-arg-string args :ws)))

(defun etm--v-pane-new (args)
  "ARGS: `ws', `key', `kind'; optional `region' `path' `cmd' `page'...
The rest of the optional ones are `backend' and `proxy'."
  (etm-pane-new args))

(defun etm--v-pane-kill (args)
  "ARGS: `addr'."
  (etm-pane-kill (etm-arg-string args :addr t)))

(defun etm--v-pane-focus (args)
  "ARGS: `addr'."
  (etm-pane-focus (etm-arg-string args :addr t)))

(defun etm--v-send (args)
  "ARGS: `addr', `text', optional `enter'."
  (etm-pane-send (etm-arg-string args :addr t)
                 (or (etm-arg-string args :text) "")
                 (etm-arg-bool args :enter)))

(defun etm--v-capture (args)
  "ARGS: `addr', optional `since' `lines' `max_chars'."
  (etm-pane-capture (etm-arg-string args :addr t)
                    (etm-arg-string args :since)
                    (etm-arg-int args :lines nil)
                    (etm-arg-int args :max_chars 262144)))

(defun etm--v-wait (args)
  "ARGS: `addr', `until', optional `timeout' `idle_ms' `since' `poll' `final'."
  (etm-pane-wait args))

;;;; Health and trail

(defun etm-probe (check ok hint &optional skip)
  "One doctor row: CHECK passes when OK, else fails (or skips when SKIP).
HINT says what the check means or what is wrong."
  (list :check check
        :status (cond (ok "pass") (skip "skip") (t "fail"))
        :hint hint))

(defun etm--probes ()
  "Return the invariant rows built into etm."
  (let ((unowned (cl-remove-if
                  (lambda (b) (or (not (buffer-local-value 'etm-pane-key b))
                                  (etm-resource-registered-p b)))
                  (buffer-list)))
        (backend (etm-backend)))
    (append
     (list
      (etm-probe "etm.server"
                 (and (boundp 'server-process) server-process
                      (process-live-p server-process))
                 "Emacs server running (what the etm CLI connects to)" t)
      (etm-probe "etm.json" (or (not (fboundp 'json-available-p))
                                (json-available-p))
                 "native JSON available")
      (etm-probe "etm.workspaces" (not (eq backend 'single))
                 (format "workspace backend: %s (single = one global workspace)"
                         backend)
                 t)
      (etm-probe "etm.panes-registered" (null unowned)
                 (if unowned
                     (format "pane buffers outside the registry: %s"
                             (mapconcat #'buffer-name unowned ", "))
                   "every pane buffer resolves through the registry")))
     (etm-page-probes #'etm-probe))))

(defun etm--extra-probes ()
  "Rows from `etm-doctor-functions', statuses as strings."
  (cl-loop for fn in etm-doctor-functions
           append (mapcar (lambda (r)
                            (list :check (format "%s" (plist-get r :check))
                                  :status (format "%s" (plist-get r :status))
                                  :hint (plist-get r :hint)))
                          (condition-case e
                              (funcall fn)
                            (error (list (list :check (format "%s" fn) :status 'fail
                                               :hint (error-message-string e))))))))

(defun etm--v-doctor (_args)
  "Run the built-in probes and every row from `etm-doctor-functions'."
  (let* ((rows (append (etm--probes) (etm--extra-probes)))
         (fails (cl-remove-if-not (lambda (r) (equal (plist-get r :status) "fail"))
                                  rows)))
    (dolist (r fails)
      (etm-warn (concat "doctor." (plist-get r :check)) (or (plist-get r :hint) "")))
    (list :healthy (if fails :false t)
          :rows (vconcat rows))))

(defun etm--event-after-p (event since)
  "Non-nil when EVENT is newer than SINCE (an event id or a float time)."
  (cond ((null since) t)
        ((numberp since) (> (plist-get event :ts) since))
        ((stringp since) (string< since (or (plist-get event :id) "")))
        (t t)))

(defun etm--v-events (args)
  "Events, oldest first, after ARGS `since'; at most `limit' (newest kept)."
  (let* ((since (etm-arg args :since))
         (limit (etm-arg-int args :limit 50))
         (all (cl-remove-if-not (lambda (e) (etm--event-after-p e since))
                                (etm-event-list)))
         (kept (last all limit)))
    (list :events (vconcat kept)
          :dropped (- (length all) (length kept))
          :next_since (if kept (plist-get (car (last kept)) :id) (or since :null)))))

(defun etm--v-eval (args)
  "The logged escape hatch: evaluate ARGS `form' and print the value."
  (unless etm-allow-eval
    (etm-fail "capability.disabled" "eval is disabled (etm-allow-eval)"))
  (let* ((form (etm-arg-string args :form t))
         (value (eval (car (read-from-string form)) t)))
    (etm-event-log 'info "eval escape hatch: %s" (truncate-string-to-width form 200))
    (etm-warn "eval.escape_hatch" "eval bypasses the verb table; prefer a verb")
    (list :value (prin1-to-string value))))

(provide 'etm-verbs)
;;; etm-verbs.el ends here

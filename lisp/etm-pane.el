;;; etm-pane.el --- Pane verbs for etm: new, ls, kill, focus -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; URL: https://github.com/davidawad/etm
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A pane is a buffer-shaped resource of one workspace, addressed
;; `<workspace>/<pane-key>'.  Identity goes through the resolver
;; (`etm-resource-resolver'): a pane IS the buffer registered under the
;; resource key `etm-pane:<key>' in its workspace's row, so the same key
;; in two workspaces is two buffers, and buffer names stay labels.
;; Tags live on the buffer: `etm-pane-key', `etm-pane-kind',
;; `etm-pane-region' and `etm-pane-proxy'; displayed windows carry the
;; `etm-pane' window parameter.
;;
;; A pane's region (`left'/`right'/`bottom') docks through
;; `etm-layout-dock-function'; `main' is the ordinary window area.
;;
;; Talking to a pane (send, capture, wait) lives in etm-io.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etm-base)
(require 'etm-backend)
(require 'etm-ext)
(require 'etm-ws)
(require 'etm-page)

(defvar dired-buffers)
(declare-function eshell-mode "esh-mode" ())
(declare-function eshell-head-process "esh-cmd" ())
(declare-function eat-make "eat" (name program &optional startfile &rest switches))
(declare-function make-comint-in-buffer "comint"
                  (name buffer program &optional startfile &rest switches))

(defconst etm-pane-kinds '("shell" "cmd" "editor" "tree" "page")
  "Pane kinds etm renders natively.
`page' is a registered page type (etm-page.el); `agent' is refused as
unsupported: a controller runs an agent CLI as a `cmd' pane.")

(defconst etm-pane-regions '("main" "left" "right" "bottom" "top")
  "The region vocabulary a pane may ask for.")

(defcustom etm-pane-buffer-name-function #'generate-new-buffer-name
  "Function turning a pane's base label into a new buffer's name.
The label (`*etm:WS/KEY*') is never identity, only what a human sees."
  :type 'function
  :group 'etm)

(defvar-local etm-pane-key nil
  "Pane key of this buffer (its tag), or nil.")
(put 'etm-pane-key 'permanent-local t)

(defvar-local etm-pane-proxy nil
  "What this pane is a proxy of (a free-form tag the creator set), or nil.")
(put 'etm-pane-proxy 'permanent-local t)

(defvar-local etm-pane-kind nil
  "Pane kind string this buffer was created as.")
(put 'etm-pane-kind 'permanent-local t)

(defvar-local etm-pane-region nil
  "Region string this pane was asked to occupy.")
(put 'etm-pane-region 'permanent-local t)

(defvar-local etm-pane--process nil
  "The process a `cmd' pane was created with.")
(put 'etm-pane--process 'permanent-local t)

(defvar-local etm-pane--last-change nil
  "`float-time' of this buffer's last change.")
(put 'etm-pane--last-change 'permanent-local t)

(setq etm-page-tag-variables
      '(etm-pane-key etm-pane-proxy etm-pane-kind etm-pane-region))

(defun etm-pane--resource-key (key)
  "Resource key symbol for pane KEY."
  (intern (concat "etm-pane:" key)))

;;;; Liveness

(defun etm-pane--note-change (&rest _)
  "Stamp the time of this change (an `after-change-functions' entry)."
  (setq etm-pane--last-change (float-time)))

(defun etm-pane-track (buffer)
  "Make BUFFER record when it last changed; return that time."
  (with-current-buffer buffer
    (unless (memq #'etm-pane--note-change after-change-functions)
      (add-hook 'after-change-functions #'etm-pane--note-change nil t))
    (or etm-pane--last-change (setq etm-pane--last-change (float-time)))))

(defun etm-pane-running-p (buffer)
  "Non-nil while BUFFER has a live foreground process."
  (with-current-buffer buffer
    (if (derived-mode-p 'eshell-mode)
        (and (fboundp 'eshell-head-process) (eshell-head-process) t)
      (let ((proc (get-buffer-process buffer)))
        (and proc (process-live-p proc))))))

;;;; Resolution

(defun etm-pane-addr (ws key)
  "Address string of pane KEY in workspace WS."
  (format "%s/%s" (etm-ws-name ws) key))

(defun etm-pane-resolve (addr)
  "Resolve ADDR to (WS . BUFFER); `not_found.pane' if absent."
  (let* ((parsed (etm-parse-addr addr))
         (ws (etm-ws-resolve (car parsed)))
         (buf (etm-resource-peek (etm-pane--resource-key (cdr parsed)) ws)))
    (unless buf
      (etm-fail "not_found.pane"
                (format "no pane `%s' in workspace `%s'" (cdr parsed) (etm-ws-name ws))
                :hint (format "etm pane ls %s" (etm-ws-name ws))))
    (cons ws buf)))

(defun etm-pane-buffers (ws)
  "Live pane buffers owned by workspace WS, ordered by key."
  (sort (cl-remove-if-not (lambda (b) (buffer-local-value 'etm-pane-key b))
                          (etm-resource-owned ws))
        (lambda (a b) (string< (buffer-local-value 'etm-pane-key a)
                               (buffer-local-value 'etm-pane-key b)))))

(defun etm-pane-cursor (buffer &optional pos)
  "Capture cursor for BUFFER at POS (default: its end)."
  (etm-cursor-format (etm-resource-buffer-id buffer)
                     (or pos (with-current-buffer buffer (point-max)))))

(defun etm-pane-record (ws buffer)
  "JSON-ready description of pane BUFFER in workspace WS."
  (let* ((key (buffer-local-value 'etm-pane-key buffer))
         (proc (get-buffer-process buffer))
         (last (etm-pane-track buffer)))
    (append
     (list :addr (etm-pane-addr ws key)
           :ws (etm-ws-name ws)
           :ws_id (etm-ws-id ws)
           :key key
           :kind (buffer-local-value 'etm-pane-kind buffer)
           :region (buffer-local-value 'etm-pane-region buffer)
           :buffer (buffer-name buffer)
           :buffer_id (etm-resource-buffer-id buffer)
           :mode (symbol-name (buffer-local-value 'major-mode buffer))
           :process (if proc (symbol-name (process-status proc)) :null)
           :pid (or (and proc (process-id proc)) :null)
           :proxy (or (buffer-local-value 'etm-pane-proxy buffer) :null)
           :running (if (etm-pane-running-p buffer) t :false)
           :visible (if (get-buffer-window buffer t) t :false)
           :size (with-current-buffer buffer (1- (point-max)))
           :idle_ms (round (* 1000 (- (float-time) last)))
           :cursor (etm-pane-cursor buffer))
     (etm-page-record buffer))))

;;;; Creation

(defun etm-pane--label (ws key)
  "Human label for a new pane buffer of KEY in WS (never identity)."
  (funcall etm-pane-buffer-name-function
           (format "*etm:%s/%s*" (etm-ws-name ws) key)))

(defun etm-pane--dir (ws path)
  "Working directory for a new pane in WS: PATH, else WS's root, else ~."
  (file-name-as-directory (expand-file-name (or path (etm-ws-root ws) "~"))))

(defun etm-pane--make-shell (label dir backend)
  "Fresh interactive shell buffer LABEL in DIR using BACKEND."
  (pcase backend
    ("eat"
     (unless (fboundp 'eat-make)
       (etm-fail "capability.unavailable" "backend `eat' is not installed"
                 :hint "use --backend eshell"))
     (let ((default-directory dir))
       (eat-make (string-trim label "\\*" "\\*")
                 (or (getenv "SHELL") shell-file-name))))
    ((or "eshell" 'nil)
     (require 'eshell)
     (let ((buf (generate-new-buffer label)))
       (with-current-buffer buf
         (setq default-directory dir)
         (eshell-mode))
       buf))
    (_ (etm-fail "usage.bad_arg" (format "unknown shell backend `%s'" backend)
                 :hint "backends: eshell, eat"))))

(defun etm-pane--make-comint (label dir cmd)
  "Fresh comint buffer LABEL running shell command CMD in DIR."
  (require 'comint)
  (let ((buf (generate-new-buffer label)))
    ;; `make-comint-in-buffer' starts the process with BUF's own
    ;; `default-directory', so set it there rather than binding it here.
    (with-current-buffer buf (setq default-directory dir))
    (make-comint-in-buffer label buf shell-file-name nil "-c" cmd)
    (let ((proc (get-buffer-process buf)))
      (when proc
        (set-process-query-on-exit-flag proc nil)
        (with-current-buffer buf (setq etm-pane--process proc))))
    buf))

(defun etm-pane--make-cmd (label dir cmd &optional backend)
  "Fresh process buffer LABEL running shell command CMD in DIR.
BACKEND \"eat\" runs it in a terminal; without eat installed that
degrades to comint, with a warning."
  (unless cmd
    (etm-fail "usage.missing_arg" "kind `cmd' needs --cmd COMMAND"))
  (if (and (equal backend "eat") (fboundp 'eat-make))
      (let ((default-directory dir))
        (eat-make (string-trim label "\\*" "\\*") shell-file-name nil "-c" cmd))
    (when (equal backend "eat")
      (etm-warn "degraded.eat_unavailable"
                "eat is not installed; the command runs in comint"))
    (etm-pane--make-comint label dir cmd)))

(defun etm-pane--make (ws kind dir args)
  "Create the buffer for a pane of KIND in WS from DIR; ARGS is the request."
  (let ((label (etm-pane--label ws (etm-arg-string args :key t))))
    (pcase kind
      ("shell" (etm-pane--make-shell label dir (etm-arg-string args :backend)))
      ("cmd" (etm-pane--make-cmd label dir (etm-arg-string args :cmd)
                                 (etm-arg-string args :backend)))
      ("editor"
       ;; An indirect buffer over the file's buffer: one per workspace,
       ;; text and saving shared with the file.
       (make-indirect-buffer
        (find-file-noselect (expand-file-name (etm-arg-string args :path t) dir))
        label t))
      ("tree"
       ;; Hide `dired-buffers' so dired makes a fresh buffer rather than
       ;; handing back one another workspace already owns.
       (let ((dired-buffers nil))
         (dired-noselect dir)))
      ("page" (etm-page-make label (etm-arg-string args :page t) dir ws))
      (_ (etm-fail "capability.unsupported_kind"
                   (format "pane kind `%s' is not supported by etm" kind)
                   :hint (format "kinds: %s" (string-join etm-pane-kinds ", ")))))))

(defun etm-pane--display (buffer region)
  "Show BUFFER in REGION of the selected frame; return the window or nil."
  (let ((region (if (equal region "top")
                    (progn (etm-warn "degraded.region_top"
                                     "no top region in Emacs; docked at bottom")
                           "bottom")
                  region)))
    (condition-case err
        (let ((win (if (equal region "main")
                       (display-buffer buffer '(display-buffer-use-some-window))
                     (or (funcall etm-layout-dock-function buffer (intern region))
                         (progn (etm-warn "degraded.layout_unavailable"
                                          "the dock function showed nothing")
                                nil)))))
          (when (windowp win)
            (set-window-parameter win 'etm-pane (buffer-local-value 'etm-pane-key buffer)))
          win)
      (error (etm-warn "layout.failed" (error-message-string err))
             nil))))

(defun etm-pane--check-args (key region)
  "Signal a usage error unless KEY and REGION are well formed."
  (unless (etm-valid-key-p key)
    (etm-fail "usage.bad_arg" (format "bad pane key `%s'" key)))
  (when (and region (not (member region etm-pane-regions)))
    (etm-fail "usage.bad_arg" (format "unknown region `%s'" region)
              :hint "regions: main, left, right, bottom, top")))

(defun etm-pane-new (args)
  "Create (or return) pane KEY of KIND in workspace WS per request ARGS.
Idempotent: an existing pane of the same kind is returned with
`created' false; the same key with another kind is a conflict."
  (let* ((ws (etm-ws-resolve (etm-arg-string args :ws)))
         (key (etm-arg-string args :key t))
         (kind (etm-arg-string args :kind t))
         (region (etm-arg-string args :region))
         (rkey (progn (etm-pane--check-args key region)
                      (etm-pane--resource-key key)))
         (existing (etm-resource-peek rkey ws))
         (dir (etm-pane--dir ws (etm-arg-string args :path)))
         (buf (or existing
                  (etm-resource-get rkey (lambda () (etm-pane--make ws kind dir args))
                                    ws))))
    (when (and existing
               (not (equal (buffer-local-value 'etm-pane-kind existing) kind)))
      (etm-fail "conflict.kind_mismatch"
                (format "pane `%s' exists with kind `%s'"
                        key (buffer-local-value 'etm-pane-kind existing))
                :hint (format "etm pane kill %s" (etm-pane-addr ws key))))
    (unless existing
      (with-current-buffer buf
        (setq etm-pane-key key
              etm-pane-proxy (etm-arg-string args :proxy)
              etm-pane-kind kind
              etm-pane-region region))
      (etm-pane-track buf)
      (ignore-errors (etm-ws-add-buffer ws buf)))
    (when region
      (if (etm-ws-current-p ws)
          (etm-pane--display buf region)
        (etm-warn "layout.deferred"
                  "workspace not shown; region applies on `pane focus'")))
    (let ((addr (etm-pane-addr ws key)))
      (etm-next (format "etm send %s TEXT --enter" addr)
                (format "etm capture %s" addr))
      (append (etm-pane-record ws buf)
              (list :created (if existing :false t))))))

(defun etm-pane-ls (ws-name)
  "Pane records of WS-NAME (nil = current workspace, \"*\" = all)."
  (let ((wss (if (equal ws-name "*")
                 (etm-ws-all)
               (list (etm-ws-resolve ws-name)))))
    (vconcat (cl-mapcan (lambda (ws)
                          (mapcar (lambda (b) (etm-pane-record ws b))
                                  (etm-pane-buffers ws)))
                        wss))))

(defun etm-pane--kill-buffer (buf)
  "Kill pane buffer BUF, its process without confirmation."
  (let ((proc (get-buffer-process buf)))
    (when proc (set-process-query-on-exit-flag proc nil)))
  (let ((kill-buffer-query-functions nil))
    (kill-buffer buf)))

(defun etm-pane-kill (addr)
  "Kill the pane at ADDR (its process without confirmation)."
  (let ((hit (etm-pane-resolve addr)))
    (etm-pane--kill-buffer (cdr hit))
    (list :addr (etm-pane-addr (car hit) (cdr (etm-parse-addr addr)))
          :killed t)))

(defun etm-pane-reap (ws)
  "Kill the pane buffers of WS, except those on display outside it."
  (dolist (buf (etm-pane-buffers ws))
    (unless (and (not (etm-ws-current-p ws)) (get-buffer-window buf t))
      (etm-pane--kill-buffer buf))))

(defun etm-pane-focus (addr)
  "Bring the pane at ADDR to the selected window, switching workspace."
  (let* ((hit (etm-pane-resolve addr))
         (ws (car hit))
         (buf (cdr hit)))
    (unless (etm-ws-current-p ws)
      (etm-backend-switch (etm-backend) (etm-ws-handle ws)))
    (let ((win (or (get-buffer-window buf)
                   (let ((region (buffer-local-value 'etm-pane-region buf)))
                     (and region (etm-pane--display buf region)))
                   (progn (pop-to-buffer-same-window buf)
                          (selected-window)))))
      (select-window win)
      (set-window-parameter win 'etm-pane (buffer-local-value 'etm-pane-key buf)))
    (etm-pane-record ws buf)))

(provide 'etm-pane)
;;; etm-pane.el ends here

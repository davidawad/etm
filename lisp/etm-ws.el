;;; etm-ws.el --- Workspace verbs for etm, over the backend protocol -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; URL: https://github.com/davidawad/etm
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `etm ws ls|get|new|switch|rename|kill'.  Every call goes through the
;; workspace backend in effect (etm-backend.el), so the same verbs work
;; over persp-mode, tab-bar, tabspaces, or the single global workspace.
;; A workspace's identity is its backend id, never its display name, so
;; `rename' keeps every pane address's ownership intact.
;;
;; Workspaces are tagged in place: the parameters named by
;; `etm-tag-parameters' hold the name a controller mounted it under,
;; its subject, spec revision and owner.  Nothing about them is kept
;; anywhere else.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etm-base)
(require 'etm-backend)
(require 'etm-ext)

(defun etm-ws-from-handle (handle &optional backend)
  "The `etm-ws' for HANDLE of BACKEND (default: the one in effect)."
  (let ((b (or backend (etm-backend))))
    (etm-ws--make :name (etm-backend-name b handle)
                  :handle handle
                  :id (etm-backend-id b handle))))

(defun etm-ws-all ()
  "Every workspace, in the backend's order."
  (let ((b (etm-backend)))
    (mapcar (lambda (h) (etm-ws-from-handle h b)) (etm-backend-list b))))

(defun etm-ws-current ()
  "The workspace shown in the selected frame."
  (let ((b (etm-backend)))
    (etm-ws-from-handle (etm-backend-current b) b)))

(defun etm-ws-current-p (ws)
  "Non-nil when WS is the workspace shown in the selected frame."
  (equal (etm-ws-id ws) (etm-ws-id (etm-ws-current))))

(defun etm-ws-find (name-or-id)
  "Workspace whose name (or else id) is NAME-OR-ID, or nil."
  (let ((all (etm-ws-all)))
    (or (cl-find name-or-id all :key #'etm-ws-name :test #'equal)
        (cl-find name-or-id all :key #'etm-ws-id :test #'equal))))

(defun etm-ws-resolve (name-or-id)
  "Workspace NAME-OR-ID (nil = current); `not_found.workspace' if absent."
  (if (null name-or-id)
      (etm-ws-current)
    (or (etm-ws-find name-or-id)
        (etm-fail "not_found.workspace" (format "no workspace `%s'" name-or-id)
                  :hint "etm ws ls"))))

(defun etm-ws-tag (ws tag)
  "Value of TAG (see `etm-tag-parameters') on WS, or nil."
  (ignore-errors
    (etm-backend-parameter (etm-backend) (etm-ws-handle ws) (etm-tag-parameter tag))))

(defun etm-ws--set-tag (ws tag value)
  "Set TAG on WS to VALUE."
  (etm-backend-set-parameter (etm-backend) (etm-ws-handle ws)
                             (etm-tag-parameter tag) value))

(defun etm-ws-subject (ws)
  "The subject WS was created for, or nil."
  (etm-ws-tag ws 'subject))

(defun etm-ws-root (ws)
  "WS's declared root directory, or nil."
  (let ((root (etm-ws-tag ws 'root)))
    (and (stringp root) (file-directory-p root) root)))

(defun etm-ws-add-buffer (ws buffer)
  "Make BUFFER a member of WS in the backend."
  (etm-backend-add-buffer (etm-backend) (etm-ws-handle ws) buffer))

(defun etm-ws-record (ws &optional pane-count)
  "JSON-ready description of WS; PANE-COUNT when the caller knows it."
  (list :name (etm-ws-name ws)
        :id (etm-ws-id ws)
        :current (if (etm-ws-current-p ws) t :false)
        :managed (if (etm-ws-tag ws 'tag) t :false)
        :subject (etm-ws-tag ws 'subject)
        :tag (etm-ws-tag ws 'tag)
        :spec (etm-ws-tag ws 'spec)
        :owner (etm-ws-tag ws 'owner)
        :root (etm-ws-root ws)
        :panes pane-count))

;;;; Mutating verbs

(defun etm-ws--require-mutable (verb)
  "Signal `capability.unavailable' for VERB unless the backend can do it."
  (let ((b (etm-backend)))
    (etm-backend-require-available b)
    (unless (etm-backend-mutable-p b)
      (etm-fail "capability.unavailable"
                (format "`ws %s' needs a workspace backend; this session has one global workspace"
                        verb)
                :hint "enable persp-mode, tabspaces-mode or tab-bar-mode, or set `etm-workspace-backend'"))))

(defun etm-ws--require-real (ws verb)
  "Signal `usage.bad_target' when WS cannot take VERB (the nil workspace)."
  (unless (etm-backend-real-p (etm-backend) (etm-ws-handle ws))
    (etm-fail "usage.bad_target"
              (format "cannot %s the `%s' workspace" verb (etm-ws-name ws)))))

(defun etm-ws--adopt (from name)
  "Take over the untagged workspace FROM as NAME; return its handle.
FROM is renamed to NAME (its id, and so every pane, is unchanged).  A
workspace already tagged NAME is returned as is (re-adopting is
idempotent); one tagged for another name is a conflict."
  (let* ((ws (etm-ws-resolve from))
         (tag (etm-ws-tag ws 'tag)))
    (unless (etm-backend-real-p (etm-backend) (etm-ws-handle ws))
      (etm-fail "usage.bad_target"
                (format "cannot adopt the `%s' workspace" (etm-ws-name ws))))
    (when (and tag (not (equal tag name)))
      (etm-fail "conflict.already_managed"
                (format "workspace `%s' is already managed as `%s'" from tag)))
    (unless (equal (etm-ws-name ws) name)
      (when (etm-ws-find name)
        (etm-fail "conflict.exists" (format "workspace `%s' already exists" name)))
      (etm-backend-rename (etm-backend) (etm-ws-handle ws) name))
    (etm-ws-handle ws)))

(defun etm-ws-new (name subject switch &optional spec owner adopt)
  "Create workspace NAME tagged with SUBJECT; show it when SWITCH.
Idempotent: an existing NAME is returned with `created' false.  SPEC
and OWNER, when given, set those tags, on an existing workspace too
\(re-tagging a workspace whose spec changed); OWNER never replaces an
existing owner.  ADOPT names an existing untagged workspace to take
over as NAME instead of creating one: it is renamed and tagged."
  (etm-ws--require-mutable "new")
  (unless (and (stringp name) (not (string-empty-p name))
               (not (string-match-p "/" name)))
    (etm-fail "usage.bad_arg" "workspace name must be non-empty, without `/'"))
  (let* ((b (etm-backend))
         (adopted (and adopt (etm-ws--adopt adopt name)))
         (existing (and (not adopt) (etm-ws-find name)))
         (handle (cond (adopt adopted)
                       (existing (etm-ws-handle existing))
                       (t (etm-backend-new b name))))
         (ws (etm-ws-from-handle handle b)))
    (unless (or existing (etm-ws-tag ws 'tag))
      (etm-ws--set-tag ws 'tag name)
      (when subject (etm-ws--set-tag ws 'subject subject)))
    (when spec (etm-ws--set-tag ws 'spec spec))
    (when (and owner (not (etm-ws-tag ws 'owner)))
      (etm-ws--set-tag ws 'owner owner))
    (when switch (etm-backend-switch b handle))
    (etm-next (format "etm pane new %s KEY --kind shell" name)
              (format "etm ws switch %s" name))
    (append (etm-ws-record (etm-ws-from-handle handle b))
            (list :created (if (or existing adopt) :false t)))))

(defun etm-ws-switch (ws)
  "Show WS in the selected frame."
  (etm-ws--require-mutable "switch")
  (etm-backend-switch (etm-backend) (etm-ws-handle ws))
  (etm-next (format "etm pane ls %s" (etm-ws-name ws)))
  (etm-ws-record (etm-ws-current)))

(defun etm-ws-rename (ws new-name)
  "Relabel WS as NEW-NAME; its id, and so every pane, is unchanged."
  (etm-ws--require-mutable "rename")
  (etm-ws--require-real ws "rename")
  (when (etm-ws-find new-name)
    (etm-fail "conflict.exists" (format "workspace `%s' already exists" new-name)))
  (etm-backend-rename (etm-backend) (etm-ws-handle ws) new-name)
  (append (etm-ws-record (etm-ws-from-handle (etm-ws-handle ws)))
          (list :old_name (etm-ws-name ws))))

(defun etm-ws-kill (ws &optional reap)
  "Kill WS, after calling REAP with it (to close its panes)."
  (etm-ws--require-mutable "kill")
  (etm-ws--require-real ws "kill")
  (when reap (funcall reap ws))
  (etm-backend-kill (etm-backend) (etm-ws-handle ws))
  (list :name (etm-ws-name ws) :id (etm-ws-id ws) :killed t))

(provide 'etm-ws)
;;; etm-ws.el ends here

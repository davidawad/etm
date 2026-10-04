;;; etm-backend.el --- The workspace backend protocol and its fallback -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; URL: https://github.com/davidawad/etm
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Emacs has several notions of "workspace" (persp-mode perspectives,
;; built-in tab-bar tabs, tabspaces) and none at all in a bare session.
;; etm talks to all of them through one small protocol: generic
;; functions whose first argument is the backend symbol, so a backend
;; is a set of `cl-defmethod's specialized with (eql \\='NAME).
;;
;;   list / current / name / id / get     read the workspaces
;;   new / switch / rename / kill         change them
;;   buffers / add-buffer                 buffer membership
;;   parameter / set-parameter            tags stored on a workspace
;;
;; A workspace is reached through a HANDLE, whatever the backend uses
;; (a perspective object, a tab id); `etm-backend-id' names it stably
;; across renames, which is what pane identity keys on.
;;
;; This file defines the protocol, the `single' fallback (one global
;; workspace that cannot be created, renamed or killed), and the
;; `etm-workspace-backend' option.  The persp-mode, tab-bar and
;; tabspaces backends live in etm-persp.el, etm-tab-bar.el and
;; etm-tabspaces.el.

;;; Code:

(require 'cl-lib)
(require 'etm-base)

(defcustom etm-workspace-backend 'auto
  "Which notion of workspace etm drives.
`auto' picks the first available backend in
`etm-workspace-backend-candidates' on every request, so enabling
`persp-mode' or `tabspaces-mode' later is picked up without a restart."
  :type '(choice (const :tag "Detect" auto)
                 (const :tag "persp-mode perspectives" persp-mode)
                 (const :tag "tabspaces" tabspaces)
                 (const :tag "Built-in tab-bar tabs" tab-bar)
                 (const :tag "One global workspace" single)
                 (symbol :tag "Another backend"))
  :group 'etm)

(defcustom etm-workspace-backend-candidates '(persp-mode tabspaces tab-bar single)
  "Backends `auto' tries, in order; the first available one wins.
The built-in `tab-bar' backend counts as available once `tab-bar-mode'
is on or the selected frame has more than one tab; `single' always is."
  :type '(repeat symbol)
  :group 'etm)

(cl-defstruct (etm-ws (:constructor etm-ws--make)
                      (:copier nil))
  "One resolved workspace: display NAME, backend HANDLE and stable ID."
  name handle id)

;;;; The protocol

(cl-defgeneric etm-backend-available-p (backend)
  "Non-nil when BACKEND can be used in this session.")

(cl-defgeneric etm-backend-list (backend)
  "Handles of every workspace of BACKEND, in its own order.")

(cl-defgeneric etm-backend-current (backend)
  "Return the handle of BACKEND's workspace in the selected frame.")

(cl-defgeneric etm-backend-name (backend handle)
  "Display name of the workspace HANDLE of BACKEND.")

(cl-defgeneric etm-backend-id (backend handle)
  "Stable id of the workspace HANDLE of BACKEND (survives renames).")

(cl-defgeneric etm-backend-get (backend name)
  "Handle of the workspace NAME of BACKEND, or nil."
  (cl-find name (etm-backend-list backend)
           :key (lambda (h) (etm-backend-name backend h)) :test #'equal))

(cl-defgeneric etm-backend-mutable-p (_backend)
  "Non-nil when BACKEND can create, switch, rename and kill workspaces."
  t)

(cl-defgeneric etm-backend-real-p (_backend _handle)
  "Non-nil unless HANDLE is a workspace BACKEND cannot rename or kill."
  t)

(cl-defgeneric etm-backend-new (backend name)
  "Create workspace NAME in BACKEND without showing it; return its handle.")

(cl-defgeneric etm-backend-switch (backend handle)
  "Show the workspace HANDLE of BACKEND in the selected frame.")

(cl-defgeneric etm-backend-rename (backend handle new-name)
  "Rename the workspace HANDLE of BACKEND to NEW-NAME.")

(cl-defgeneric etm-backend-kill (backend handle)
  "Remove the workspace HANDLE from BACKEND (its buffers stay alive).")

(cl-defgeneric etm-backend-buffers (backend handle)
  "Buffers that belong to the workspace HANDLE of BACKEND.")

(cl-defgeneric etm-backend-add-buffer (_backend _handle _buffer)
  "Make BUFFER a member of the workspace HANDLE of BACKEND."
  nil)

(cl-defgeneric etm-backend-parameter (backend handle param)
  "Value of parameter PARAM (a symbol) on the workspace HANDLE of BACKEND.")

(cl-defgeneric etm-backend-set-parameter (backend handle param value)
  "Set parameter PARAM of the workspace HANDLE of BACKEND to VALUE.")

;;;; The single-workspace fallback

(defconst etm-global-name "global"
  "Name and id of the one workspace of a session without workspaces.")

(defvar etm-single--parameters nil
  "Parameters of the `single' backend's one workspace, an alist.")

(cl-defmethod etm-backend-available-p ((_ (eql 'single)))
  "Non-nil when the single backend is usable now."
  t)
(cl-defmethod etm-backend-list ((_ (eql 'single)))
  "The one workspace, whose handle is nil."
  (list nil))
(cl-defmethod etm-backend-current ((_ (eql 'single)))
  "The one workspace's handle, nil."
  nil)
(cl-defmethod etm-backend-name ((_ (eql 'single)) _handle)
  "Name of the one workspace: `etm-global-name'."
  etm-global-name)
(cl-defmethod etm-backend-id ((_ (eql 'single)) _handle)
  "Id of the one workspace: `etm-global-name'."
  etm-global-name)
(cl-defmethod etm-backend-mutable-p ((_ (eql 'single)))
  "The single backend cannot create, rename or kill workspaces."
  nil)
(cl-defmethod etm-backend-real-p ((_ (eql 'single)) _handle)
  "The one workspace cannot be renamed or killed."
  nil)
(cl-defmethod etm-backend-buffers ((_ (eql 'single)) _handle)
  "Every buffer belongs to the one workspace."
  (buffer-list))

(cl-defmethod etm-backend-parameter ((_ (eql 'single)) _handle param)
  "Parameter PARAM of the one workspace."
  (alist-get param etm-single--parameters))

(cl-defmethod etm-backend-set-parameter ((_ (eql 'single)) _handle param value)
  "Set parameter PARAM of the one workspace to VALUE."
  (setf (alist-get param etm-single--parameters) value))

;;;; Choosing the backend

(defun etm-backend ()
  "The backend symbol in effect for this request."
  (if (eq etm-workspace-backend 'auto)
      (or (cl-find-if (lambda (b)
                        (ignore-errors (etm-backend-available-p b)))
                      etm-workspace-backend-candidates)
          'single)
    etm-workspace-backend))

(defun etm-backend-require-available (backend)
  "Signal `capability.unavailable' unless BACKEND is usable now."
  (unless (ignore-errors (etm-backend-available-p backend))
    (etm-fail "capability.unavailable"
              (format "workspace backend `%s' is not available" backend)
              :hint "customize `etm-workspace-backend', or set it to `auto'")))

(provide 'etm-backend)
;;; etm-backend.el ends here

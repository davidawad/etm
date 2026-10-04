;;; etm-tabspaces.el --- tabspaces workspace backend for etm -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; URL: https://github.com/davidawad/etm
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The `tabspaces' backend: tabspaces makes each tab-bar tab a
;; workspace with its own buffer list, so this backend is the tab-bar
;; one (etm-tab-bar.el) with tabspaces' notion of membership, used
;; while `tabspaces-mode' is on.  A new workspace is a new tab, whose
;; buffer list tabspaces resets through its tab-open hook.

;;; Code:

(require 'cl-lib)
(require 'etm-backend)
(require 'etm-tab-bar)

(declare-function tabspaces--buffer-list "tabspaces" (&optional frame tabnum))

(cl-defmethod etm-backend-available-p ((_ (eql 'tabspaces)))
  "Non-nil when the tabspaces backend is usable now."
  (and (bound-and-true-p tabspaces-mode) (fboundp 'tabspaces--buffer-list)))
(cl-defmethod etm-backend-list ((_ (eql 'tabspaces)))
  "Handles of every tabspaces workspace."
  (etm-tab-bar-list))
(cl-defmethod etm-backend-current ((_ (eql 'tabspaces)))
  "Handle of the current tabspaces workspace."
  (etm-tab-bar-current))
(cl-defmethod etm-backend-name ((_ (eql 'tabspaces)) handle)
  "Display name of the tabspaces workspace HANDLE."
  (etm-tab-bar-name handle))
(cl-defmethod etm-backend-id ((_ (eql 'tabspaces)) handle)
  "Stable id of the tabspaces workspace HANDLE."
  handle)
(cl-defmethod etm-backend-new ((_ (eql 'tabspaces)) name)
  "Create the tabspaces workspace NAME; return its handle."
  (etm-tab-bar-new name))
(cl-defmethod etm-backend-switch ((_ (eql 'tabspaces)) handle)
  "Show the tabspaces workspace HANDLE."
  (etm-tab-bar-switch handle))
(cl-defmethod etm-backend-rename ((_ (eql 'tabspaces)) handle new-name)
  "Rename the tabspaces workspace HANDLE to NEW-NAME."
  (etm-tab-bar-rename handle new-name))
(cl-defmethod etm-backend-kill ((_ (eql 'tabspaces)) handle)
  "Remove the tabspaces workspace HANDLE."
  (etm-tab-bar-kill handle))

(cl-defmethod etm-backend-buffers ((_ (eql 'tabspaces)) handle)
  "Buffers of the tabspaces workspace HANDLE."
  (let ((i (etm-tab-bar--index handle)))
    (unless i
      (etm-fail "not_found.workspace" "that tab no longer exists"))
    (tabspaces--buffer-list nil i)))

(cl-defmethod etm-backend-add-buffer ((_ (eql 'tabspaces)) handle buffer)
  "Add BUFFER to the tabspaces workspace HANDLE."
  (etm-tab-bar-add-buffer handle buffer))
(cl-defmethod etm-backend-parameter ((_ (eql 'tabspaces)) handle param)
  "Parameter PARAM of the tabspaces workspace HANDLE."
  (etm-tab-bar-parameter handle param))
(cl-defmethod etm-backend-set-parameter ((_ (eql 'tabspaces)) handle param value)
  "Set parameter PARAM of the tabspaces workspace HANDLE to VALUE."
  (etm-tab-bar-set-parameter handle param value))

(provide 'etm-tabspaces)
;;; etm-tabspaces.el ends here

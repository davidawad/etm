;;; etm-tab-bar.el --- Built-in tab-bar workspace backend for etm -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; URL: https://github.com/davidawad/etm
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The `tab-bar' backend: a workspace is a tab of the selected frame.
;; A tab is a fresh alist every time tab-bar saves it, so the handle is
;; an id etm stores in the tab itself (the `etm-id' entry, which
;; tab-bar carries along with every other unknown entry), assigned on
;; first sight.  Parameters live in the tab too, under `etm-params'.
;;
;; Membership is the tab's buffer list: the frame's `buffer-list'
;; parameter while the tab is current, the saved `wc-bl' while not.
;;
;; The tabspaces backend (etm-tabspaces.el) reuses these helpers.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tab-bar)
(require 'etm-base)
(require 'etm-backend)

(defun etm-tab-bar--tabs ()
  "The selected frame's tab list (the frame parameter, not a copy)."
  (funcall tab-bar-tabs-function))

(defun etm-tab-bar--id (tab)
  "TAB's etm id, stored into TAB on first ask."
  (or (alist-get 'etm-id (cdr tab))
      (let ((id (etm-new-id)))
        (setcdr tab (cons (cons 'etm-id id) (cdr tab)))
        id)))

(defun etm-tab-bar--index (id)
  "Zero-based index of the tab whose etm id is ID, or nil."
  (cl-position id (etm-tab-bar--tabs) :key #'etm-tab-bar--id :test #'equal))

(defun etm-tab-bar--tab (id)
  "The tab whose etm id is ID; `not_found.workspace' when it is gone."
  (let ((i (etm-tab-bar--index id)))
    (unless i
      (etm-fail "not_found.workspace" "that tab no longer exists"
                :hint "etm ws ls"))
    (nth i (etm-tab-bar--tabs))))

(defun etm-tab-bar--current-p (tab)
  "Non-nil when TAB is the selected frame's current tab."
  (eq (car tab) 'current-tab))

(defun etm-tab-bar-available-p ()
  "Non-nil when tabs are in use: `tab-bar-mode', or more than one tab."
  (or (bound-and-true-p tab-bar-mode)
      (> (length (frame-parameter nil 'tabs)) 1)))

(defun etm-tab-bar-list ()
  "Ids of every tab of the selected frame."
  (mapcar #'etm-tab-bar--id (etm-tab-bar--tabs)))

(defun etm-tab-bar-current ()
  "Id of the selected frame's current tab."
  (etm-tab-bar--id (tab-bar--current-tab-find (etm-tab-bar--tabs))))

(defun etm-tab-bar-name (id)
  "Display name of the tab ID (a current tab's name is computed live)."
  (let ((tab (etm-tab-bar--tab id)))
    (alist-get 'name (if (etm-tab-bar--current-p tab)
                         (tab-bar--current-tab-make tab)
                       tab))))

(defun etm-tab-bar-new (name)
  "Create tab NAME to the right of the current one, stay where we were.
Return its id."
  (let ((from (tab-bar--current-tab-index)))
    (tab-bar-new-tab)
    (tab-bar-rename-tab name)
    (let ((new (tab-bar--current-tab-index)))
      (tab-bar-select-tab (1+ from))
      (etm-tab-bar--id (nth new (etm-tab-bar--tabs))))))

(defun etm-tab-bar-switch (id)
  "Select the tab ID."
  (etm-tab-bar--tab id)
  (tab-bar-select-tab (1+ (etm-tab-bar--index id))))

(defun etm-tab-bar-rename (id new-name)
  "Rename the tab ID to NEW-NAME."
  (etm-tab-bar--tab id)
  (tab-bar-rename-tab new-name (1+ (etm-tab-bar--index id))))

(defun etm-tab-bar-kill (id)
  "Close the tab ID; the frame's only tab cannot be closed."
  (etm-tab-bar--tab id)
  (when (<= (length (etm-tab-bar--tabs)) 1)
    (etm-fail "usage.bad_target" "cannot close the frame's only tab"))
  (tab-bar-close-tab (1+ (etm-tab-bar--index id))))

(defun etm-tab-bar-buffers (id)
  "Buffers of the tab ID: its buffer list, plus what its windows show."
  (let ((tab (etm-tab-bar--tab id)))
    (seq-filter
     #'buffer-live-p
     (delete-dups
      (if (etm-tab-bar--current-p tab)
          (append (mapcar #'window-buffer (window-list nil 'nomini))
                  (frame-parameter nil 'buffer-list)
                  (frame-parameter nil 'buried-buffer-list))
        (append (alist-get 'wc-bl (cdr tab))
                (alist-get 'wc-bbl (cdr tab))))))))

(defun etm-tab-bar-add-buffer (id buffer)
  "Add BUFFER to the buffer list of the tab ID."
  (let ((tab (etm-tab-bar--tab id)))
    (if (etm-tab-bar--current-p tab)
        (let ((bl (frame-parameter nil 'buffer-list)))
          (unless (memq buffer bl)
            (set-frame-parameter nil 'buffer-list (cons buffer bl))))
      (unless (memq buffer (alist-get 'wc-bl (cdr tab)))
        (setf (alist-get 'wc-bl (cdr tab))
              (cons buffer (alist-get 'wc-bl (cdr tab))))))))

(defun etm-tab-bar-parameter (id param)
  "Parameter PARAM of the tab ID."
  (alist-get param (alist-get 'etm-params (cdr (etm-tab-bar--tab id)))))

(defun etm-tab-bar-set-parameter (id param value)
  "Set parameter PARAM of the tab ID to VALUE."
  (let* ((tab (etm-tab-bar--tab id))
         (params (copy-alist (alist-get 'etm-params (cdr tab)))))
    (setf (alist-get param params) value)
    (setf (alist-get 'etm-params (cdr tab)) params)))

(cl-defmethod etm-backend-available-p ((_ (eql 'tab-bar)))
  "Non-nil when the tab-bar backend is usable now."
  (etm-tab-bar-available-p))
(cl-defmethod etm-backend-list ((_ (eql 'tab-bar)))
  "Handles of every tab-bar workspace."
  (etm-tab-bar-list))
(cl-defmethod etm-backend-current ((_ (eql 'tab-bar)))
  "Handle of the current tab-bar workspace."
  (etm-tab-bar-current))
(cl-defmethod etm-backend-name ((_ (eql 'tab-bar)) handle)
  "Display name of the tab-bar workspace HANDLE."
  (etm-tab-bar-name handle))
(cl-defmethod etm-backend-id ((_ (eql 'tab-bar)) handle)
  "Stable id of the tab-bar workspace HANDLE."
  handle)
(cl-defmethod etm-backend-new ((_ (eql 'tab-bar)) name)
  "Create the tab-bar workspace NAME; return its handle."
  (etm-tab-bar-new name))
(cl-defmethod etm-backend-switch ((_ (eql 'tab-bar)) handle)
  "Show the tab-bar workspace HANDLE."
  (etm-tab-bar-switch handle))
(cl-defmethod etm-backend-rename ((_ (eql 'tab-bar)) handle new-name)
  "Rename the tab-bar workspace HANDLE to NEW-NAME."
  (etm-tab-bar-rename handle new-name))
(cl-defmethod etm-backend-kill ((_ (eql 'tab-bar)) handle)
  "Remove the tab-bar workspace HANDLE."
  (etm-tab-bar-kill handle))
(cl-defmethod etm-backend-buffers ((_ (eql 'tab-bar)) handle)
  "Buffers of the tab-bar workspace HANDLE."
  (etm-tab-bar-buffers handle))
(cl-defmethod etm-backend-add-buffer ((_ (eql 'tab-bar)) handle buffer)
  "Add BUFFER to the tab-bar workspace HANDLE."
  (etm-tab-bar-add-buffer handle buffer))
(cl-defmethod etm-backend-parameter ((_ (eql 'tab-bar)) handle param)
  "Parameter PARAM of the tab-bar workspace HANDLE."
  (etm-tab-bar-parameter handle param))
(cl-defmethod etm-backend-set-parameter ((_ (eql 'tab-bar)) handle param value)
  "Set parameter PARAM of the tab-bar workspace HANDLE to VALUE."
  (etm-tab-bar-set-parameter handle param value))

(provide 'etm-tab-bar)
;;; etm-tab-bar.el ends here

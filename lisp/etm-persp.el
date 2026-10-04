;;; etm-persp.el --- persp-mode workspace backend for etm -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; URL: https://github.com/davidawad/etm
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The `persp-mode' backend: a workspace is a perspective.  Its handle
;; is the perspective object; persp-mode's nil perspective (named
;; `persp-nil-name') is the handle nil, which can hold panes but cannot
;; be renamed or killed.  Its stable id is a perspective parameter
;; (`etm-persp-id-parameter'), assigned on first ask; persp-mode saves
;; parameters with the session, so ids survive a restart.  The nil
;; perspective's id is `etm-global-name'.
;;
;; Only the slice of persp-mode's API listed below is called, so a
;; stand-in defining that slice works too.

;;; Code:

(require 'cl-lib)
(require 'etm-base)
(require 'etm-backend)

(defvar persp-mode)
(defvar persp-nil-name)
(defvar *persp-hash*)
(declare-function get-current-persp "persp-mode" (&optional frame window))
(declare-function persp-names "persp-mode" (&optional phash reverse))
(declare-function persp-get-by-name "persp-mode" (name &optional phash default))
(declare-function persp-parameter "persp-mode" (param-name &optional persp))
(declare-function set-persp-parameter "persp-mode" (param-name value &optional persp))
(declare-function persp-name "persp-mode" (persp))
(declare-function persp-add-new "persp-mode" (name &optional phash))
(declare-function persp-switch "persp-mode"
                  (name &optional frame window called-interactively-p))
(declare-function persp-rename "persp-mode" (newname &optional persp phash))
(declare-function persp-kill "persp-mode"
                  (name &optional dont-kill-buffers called-interactively-p))
(declare-function persp-add-buffer "persp-mode"
                  (&optional buffs-or-names persp switchorno called-interactively-p))
(declare-function persp-buffers "persp-mode" (persp))
(declare-function persp-frame-good-p "persp-mode" (&optional f))

(defcustom etm-persp-id-parameter 'etm-ws-id
  "Perspective parameter that holds a perspective's stable etm id.
Set it to a parameter another package already keeps a stable id in to
share that id with it."
  :type 'symbol
  :group 'etm)

(defun etm-persp--nil-p (persp)
  "Non-nil when PERSP is the nil perspective (nil, or the struct named so)."
  (or (null persp) (equal (persp-name persp) (bound-and-true-p persp-nil-name))))

(defun etm-persp--frame ()
  "A frame `persp-mode' manages: the selected one, else the first, else nil.
A daemon's own frame is ignored by `persp-mode', and an `emacsclient
--eval' may run with it selected."
  (if (fboundp 'persp-frame-good-p)
      (cl-find-if #'persp-frame-good-p (cons (selected-frame) (frame-list)))
    (selected-frame)))

(cl-defmethod etm-backend-available-p ((_ (eql 'persp-mode)))
  "Non-nil when `persp-mode' is on and its API is loaded."
  (and (bound-and-true-p persp-mode)
       (fboundp 'persp-names)
       (fboundp 'get-current-persp)
       (fboundp 'persp-get-by-name)))

(cl-defmethod etm-backend-list ((_ (eql 'persp-mode)))
  "Handles of every perspective."
  (let (out)
    (dolist (name (persp-names))
      ;; Pass the hash: persp-mode defaults it only when the argument is
      ;; omitted, and an explicit nil means `(gethash nil)'.
      (let ((p (persp-get-by-name name *persp-hash* :none)))
        (unless (eq p :none) (push (unless (etm-persp--nil-p p) p) out))))
    (nreverse out)))

(cl-defmethod etm-backend-current ((_ (eql 'persp-mode)))
  "Handle of the current perspective."
  (let ((p (get-current-persp (or (etm-persp--frame) (selected-frame)))))
    (unless (etm-persp--nil-p p) p)))

(cl-defmethod etm-backend-name ((_ (eql 'persp-mode)) handle)
  "Display name of the perspective HANDLE."
  (if handle (persp-name handle) (or (bound-and-true-p persp-nil-name) "none")))

(cl-defmethod etm-backend-id ((_ (eql 'persp-mode)) handle)
  "Stable id of the perspective HANDLE."
  (if (null handle)
      etm-global-name
    (or (persp-parameter etm-persp-id-parameter handle)
        (let ((id (etm-new-id)))
          (set-persp-parameter etm-persp-id-parameter id handle)
          id))))

(cl-defmethod etm-backend-get ((_ (eql 'persp-mode)) name)
  "Handle of the perspective called NAME, or nil."
  (let ((p (persp-get-by-name name *persp-hash* :none)))
    (unless (or (eq p :none) (etm-persp--nil-p p)) p)))

(cl-defmethod etm-backend-real-p ((_ (eql 'persp-mode)) handle)
  "Non-nil unless HANDLE is nil, the perspective that cannot be renamed."
  (and handle t))

(cl-defmethod etm-backend-new ((_ (eql 'persp-mode)) name)
  "Create the perspective NAME; return its handle."
  (persp-add-new name))

(cl-defmethod etm-backend-switch ((_ (eql 'persp-mode)) handle)
  "Show the perspective HANDLE."
  (let ((frame (etm-persp--frame)))
    (unless frame
      (etm-fail "capability.unavailable"
                "persp-mode manages no frame here to show a workspace in"
                :hint "open a frame first (emacsclient -c, or -t)"))
    (with-selected-frame frame
      (persp-switch (etm-backend-name 'persp-mode handle)))))

(cl-defmethod etm-backend-rename ((_ (eql 'persp-mode)) handle new-name)
  "Rename the perspective HANDLE to NEW-NAME."
  (persp-rename new-name handle))

(cl-defmethod etm-backend-kill ((_ (eql 'persp-mode)) handle)
  "Remove the perspective HANDLE."
  (persp-kill (etm-backend-name 'persp-mode handle)))

(cl-defmethod etm-backend-buffers ((_ (eql 'persp-mode)) handle)
  "Buffers of the perspective HANDLE."
  (if handle (persp-buffers handle) (buffer-list)))

(cl-defmethod etm-backend-add-buffer ((_ (eql 'persp-mode)) handle buffer)
  "Add BUFFER to the perspective HANDLE."
  (when (and handle (fboundp 'persp-add-buffer))
    (persp-add-buffer buffer handle nil nil)))

(cl-defmethod etm-backend-parameter ((_ (eql 'persp-mode)) handle param)
  "Parameter PARAM of the perspective HANDLE."
  (and handle (persp-parameter param handle)))

(cl-defmethod etm-backend-set-parameter ((_ (eql 'persp-mode)) handle param value)
  "Set parameter PARAM of the perspective HANDLE to VALUE."
  (if handle
      (set-persp-parameter param value handle)
    (etm-fail "usage.bad_target"
              (format "the `%s' perspective holds no parameters"
                      (etm-backend-name 'persp-mode nil)))))

(provide 'etm-persp)
;;; etm-persp.el ends here

;;; etm-test-support.el --- Fixtures for the etm ERT suites -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Shared by the test-etm*.el suites (not itself a test file: the
;; runner only globs test-*.el).  Everything here is a per-test fixture
;; -- `cl-letf'/`let' scoped, never a top-level stub -- because the
;; runner loads every suite into one Emacs.
;;
;; `etm-test-with-clean' runs a test against etm's defaults: a fresh
;; registry and event ring and every extension point at its default
;; value, whatever configuration the Emacs running the tests loaded.
;;
;; `etm-test-with-persps' fakes the slice of persp-mode's API the
;; persp-mode backend calls (perspectives as plain structs; the nil
;; perspective named "none"), so the workspace verbs are exercised
;; without persp-mode installed.  The real backends are exercised by
;; test-etm-backend.el, which run-tests.sh runs once per backend.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst etm-test-lisp-dir
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "The directory holding etm.el.")

(add-to-list 'load-path etm-test-lisp-dir)
(require 'etm)

(cl-defstruct (etm-test-persp (:constructor etm-test-persp--make))
  name params buffers)

(defvar etm-test--persps nil "Fake perspectives of `etm-test-with-persps'.")
(defvar etm-test--current nil "The current fake perspective.")

(defmacro etm-test-with-clean (&rest body)
  "Run BODY against etm's defaults, a fresh registry and event ring.
Buffers BODY made are killed afterwards."
  (declare (indent 0))
  `(let ((before (buffer-list))
         (etm--resources (make-hash-table :test #'equal :weakness 'value))
         (etm--event-ring nil)
         (etm-single--parameters nil)
         (etm-allow-eval t)
         (etm-workspace-backend 'single)
         (etm-workspace-backend-candidates '(persp-mode tabspaces tab-bar single))
         (etm-resource-resolver nil)
         (etm-layout-dock-function #'etm-layout-dock-side-window)
         (etm-event-log-function #'etm-event-ring-log)
         (etm-event-list-function #'etm-event-ring-list)
         (etm-event-functions nil)
         (etm-doctor-functions nil)
         (etm-snapshot-functions nil)
         (etm-page-types nil)
         (etm-page-type-functions (list #'etm-page-command-type))
         (etm-pane-buffer-name-function #'generate-new-buffer-name)
         (etm-persp-id-parameter 'etm-ws-id)
         (etm-tag-parameters (eval (car (get 'etm-tag-parameters 'standard-value)) t)))
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (unless (memq b before)
           (let ((p (get-buffer-process b)))
             (when p (set-process-query-on-exit-flag p nil) (delete-process p)))
           (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))))

(defmacro etm-test-with-persps (names &rest body)
  "Run BODY with a fake persp-mode holding perspectives NAMES.
The first of NAMES is current; `etm-test--persps' is bound to the list."
  (declare (indent 1))
  `(let* ((etm-test--persps (mapcar (lambda (n) (etm-test-persp--make :name n)) ,names))
          (etm-test--current (car etm-test--persps))
          (etm-workspace-backend 'persp-mode))
     ;; `cl-progv': these must be DYNAMIC bindings without declaring
     ;; them special globally.
     (cl-progv '(persp-mode persp-nil-name *persp-hash*)
         (list t "none" (make-hash-table :test 'equal))
       (cl-letf* (((symbol-function 'get-current-persp) (lambda (&rest _) etm-test--current))
                  ((symbol-function 'persp-names)
                   (lambda (&rest _) (cons "none" (mapcar #'etm-test-persp-name etm-test--persps))))
                  ((symbol-function 'persp-get-by-name)
                   ;; Mirrors real persp-mode: its PHASH default applies only
                   ;; when omitted, so an explicit nil is `(gethash nil)'.
                   (lambda (name &rest args)
                     (when (and args (not (hash-table-p (car args))))
                       (signal 'wrong-type-argument (list 'hash-table-p (car args))))
                     (cond ((equal name "none") nil)
                           ((cl-find name etm-test--persps :key #'etm-test-persp-name
                                     :test #'equal))
                           (t (cadr args)))))
                  ((symbol-function 'persp-name) #'etm-test-persp-name)
                  ((symbol-function 'persp-parameter)
                   (lambda (param &optional p) (alist-get param (etm-test-persp-params p))))
                  ((symbol-function 'set-persp-parameter)
                   (lambda (param value &optional p)
                     (setf (alist-get param (etm-test-persp-params p)) value)))
                  ((symbol-function 'persp-add-new)
                   (lambda (name &rest _)
                     (let ((p (etm-test-persp--make :name name)))
                       (setq etm-test--persps (append etm-test--persps (list p)))
                       p)))
                  ((symbol-function 'persp-switch)
                   (lambda (name &rest _)
                     (setq etm-test--current
                           (cl-find name etm-test--persps :key #'etm-test-persp-name
                                    :test #'equal))))
                  ((symbol-function 'persp-rename)
                   (lambda (new &optional p &rest _) (setf (etm-test-persp-name p) new)))
                  ((symbol-function 'persp-kill)
                   (lambda (name &rest _)
                     (setq etm-test--persps
                           (cl-remove name etm-test--persps :key #'etm-test-persp-name
                                      :test #'equal))))
                  ((symbol-function 'persp-add-buffer)
                   (lambda (buf &optional p &rest _) (push buf (etm-test-persp-buffers p))))
                  ((symbol-function 'persp-buffers) #'etm-test-persp-buffers))
         ,@body))))

(defun etm-test-call (verb &rest args)
  "Run VERB with plist ARGS through the JSON entry point; parsed envelope.
JSON false reads back as `:false', null as nil."
  (json-parse-string
   (etm-rpc-json (json-serialize (list :v 1 :verb verb
                                       :args (or args (make-hash-table)))))
   :object-type 'plist :array-type 'list :null-object nil :false-object :false))

(defun etm-test-data (verb &rest args)
  "Like `etm-test-call' for VERB and ARGS, but assert ok and return the data."
  (let ((env (apply #'etm-test-call verb args)))
    (unless (eq (plist-get env :ok) t)
      (ert-fail (list verb args env)))
    (plist-get env :data)))

(defun etm-test-error-code (env)
  "First error code of envelope ENV."
  (plist-get (car (plist-get env :errors)) :code))

(defun etm-test-last-event ()
  "The newest recorded event."
  (car (last (etm-event-list))))

(defun etm-test-pane-buffer (addr)
  "The live buffer behind pane ADDR, resolved like the verbs do."
  (cdr (etm-pane-resolve addr)))

(provide 'etm-test-support)
;;; etm-test-support.el ends here

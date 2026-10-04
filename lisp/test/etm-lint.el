;;; etm-lint.el --- Lint the etm package: checkdoc and package-lint -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Batch driver: `emacs -Q --batch -l etm-lint.el -- FILE...' byte-
;; compiles FILE... with warnings as errors (in a scratch directory, so
;; no .elc is left behind), runs checkdoc and, when it is on `load-path'
;; (`package-user-dir' is initialized first), package-lint with etm.el as
;; the package's main file; prints every finding and exits nonzero when
;; there is one.  `ETM_REQUIRE_PACKAGE_LINT=1' makes
;; a missing package-lint a failure instead of a notice.

;;; Code:

(require 'checkdoc)
(require 'package)

(defconst etm-lint--buffer "*etm-lint-checkdoc*")

(defun etm-lint--checkdoc (file)
  "Checkdoc findings for FILE, as a string, or nil."
  (let ((checkdoc-diagnostic-buffer etm-lint--buffer))
    (with-current-buffer (get-buffer-create etm-lint--buffer)
      (let ((inhibit-read-only t)) (erase-buffer)))
    (with-current-buffer (find-file-noselect file)
      (checkdoc-current-buffer t))
    (with-current-buffer etm-lint--buffer
      (goto-char (point-min))
      (and (re-search-forward "^.+:[0-9]+: " nil t) (buffer-string)))))

(defun etm-lint--package-lint (file main)
  "package-lint findings for FILE of the package whose main file is MAIN."
  (let ((package-lint-main-file main) (text-quoting-style 'grave) out)
    (with-temp-buffer
      (insert-file-contents file t)
      (emacs-lisp-mode)
      (dolist (f (package-lint-buffer) (nreverse out))
        (push (format "%s:%d:%d: %s: %s" file (nth 0 f) (nth 1 f) (nth 2 f) (nth 3 f))
              out)))))

(defun etm-lint--byte-compile (files)
  "Byte-compile FILES in a scratch directory, warnings as errors.
Return non-nil when any file failed."
  (let* ((dir (make-temp-file "etm-lint" t))
         (copies (mapcar (lambda (f)
                           (let ((c (expand-file-name (file-name-nondirectory f) dir)))
                             (copy-file f c t)
                             c))
                         files))
         (load-path (cons dir load-path))
         (byte-compile-warnings t)
         (byte-compile-error-on-warn t)
         (failed nil))
    (unwind-protect
        (dolist (c copies failed)
          (unless (ignore-errors (byte-compile-file c))
            (message "byte-compile failed: %s" (file-name-nondirectory c))
            (setq failed t)))
      (delete-directory dir t))))

(defvar package-lint-main-file)
(declare-function package-lint-buffer "package-lint" (&optional buffer))

(let* ((files (mapcar #'expand-file-name (cdr (member "--" command-line-args))))
       (main (seq-find (lambda (f) (equal (file-name-nondirectory f) "etm.el")) files))
       (found nil))
  (package-initialize)
  (when (etm-lint--byte-compile files) (setq found t))
  (dolist (file files)
    (let ((c (etm-lint--checkdoc file)))
      (when c (setq found t) (message "checkdoc %s:\n%s" file c))))
  (if (not (require 'package-lint nil t))
      (progn (message "package-lint not on load-path: skipped")
             (when (equal (getenv "ETM_REQUIRE_PACKAGE_LINT") "1") (setq found t)))
    (dolist (file files)
      (dolist (f (etm-lint--package-lint file main))
        (setq found t)
        (message "%s" f))))
  (kill-emacs (if found 1 0)))

;;; etm-lint.el ends here

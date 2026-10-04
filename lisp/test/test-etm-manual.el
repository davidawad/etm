;;; test-etm-manual.el --- etm: the Info manual matches the code -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; docs/etm.texi documents every user option with a @defopt, every
;; verb, and the package version; these tests hold it to `defgroup etm',
;; `etm-verbs' and `etm-version', so an option added without its entry
;; (or an entry left behind) fails here rather than in a reader's
;; hands.  The manual's "Worked Example" is evaluated as printed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "etm-test-support.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(defvar etm-test-lisp-dir)

(defconst etm-test-manual
  (expand-file-name "../docs/etm.texi" etm-test-lisp-dir)
  "The etm Texinfo manual.")

(defun etm-test-manual-text ()
  "The manual's source as a string."
  (with-temp-buffer
    (insert-file-contents etm-test-manual)
    (buffer-string)))

(defun etm-test-manual-matches (regexp)
  "Every first group of REGEXP in the manual, in order."
  (let ((text (etm-test-manual-text)) (start 0) out)
    (while (string-match regexp text start)
      (push (match-string 1 text) out)
      (setq start (match-end 0)))
    (nreverse out)))

(defun etm-test-group-options ()
  "Names of every user option in the `etm' customization group."
  (sort (cl-loop for (sym type) in (get 'etm 'custom-group)
                 when (eq type 'custom-variable) collect (symbol-name sym))
        #'string<))

(ert-deftest etm-manual-documents-every-option-of-the-group ()
  (let ((documented (sort (etm-test-manual-matches "^@defopt \\([^ \n]+\\)")
                          #'string<)))
    (should (equal documented (cl-remove-duplicates documented :test #'equal)))
    (should (equal documented (etm-test-group-options)))))

(ert-deftest etm-manual-lists-every-verb ()
  (let ((text (etm-test-manual-text)))
    (dolist (entry etm-verbs)
      (let ((cli (replace-regexp-in-string "\\." " " (car entry))))
        (should (string-match-p (regexp-quote (concat "@samp{etm " cli)) text))))))

(ert-deftest etm-manual-version-is-the-package-version ()
  (should (equal (etm-test-manual-matches "^@set VERSION \\(.+\\)$")
                 (list etm-version))))

(ert-deftest etm-manual-names-only-real-functions ()
  (dolist (name (etm-test-manual-matches
                 "^@\\(?:defunx?\\|deffnx? {Generic Function}\\) \\([^ \n]+\\)"))
    (should (fboundp (intern name)))))

(defun etm-test-manual-worked-example ()
  "The Lisp of the manual's Worked Example node, unescaped."
  (let* ((text (etm-test-manual-text))
         (node (string-search "@node Worked Example" text))
         (start (+ (string-search "\n@lisp\n" text node) (length "\n@lisp\n")))
         (end (string-search "\n@end lisp" text start)))
    (replace-regexp-in-string "@\\([@{}]\\)" "\\1" (substring text start end))))

(ert-deftest etm-manual-worked-example-runs-as-printed ()
  (etm-test-with-clean
    (let* ((home (make-temp-file "etm-manual" t))
           (process-environment (cons (concat "HOME=" home) process-environment))
           (form (car (read-from-string
                       (concat "(progn " (etm-test-manual-worked-example) ")")))))
      (unwind-protect
          (progn
            (eval form t)
            (should (assoc "agenda" etm-page-types))
            (should (assoc "notes" etm-page-types))
            (should (equal (etm-page-names) '("notes" "agenda")))
            (let ((rows (plist-get (etm-test-data "doctor") :rows)))
              (should (cl-find "my.git" rows
                               :key (lambda (r) (plist-get r :check))
                               :test #'equal)))
            (let ((log (expand-file-name "etm-events.jsonl" home)))
              (should (file-exists-p log))
              (with-temp-buffer
                (insert-file-contents log)
                (should (string-match-p "\"message\":\"doctor ok" (buffer-string))))))
        (delete-directory home t)))))

(provide 'test-etm-manual)
;;; test-etm-manual.el ends here

;;; etm-base.el --- Envelope parts, typed errors, addresses and JSON for etm -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; URL: https://github.com/davidawad/etm
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Shared plumbing for the etm verb table (etm.el): the result
;; envelope's moving parts (typed errors, warnings, `next' hints),
;; request argument access, `<workspace>/<pane-key>' address parsing,
;; capture cursors, and JSON in and out.
;;
;; Verb handlers never build an error envelope by hand.  They call
;; `etm-fail', which signals `etm-error' carrying a plist (:code :msg
;; :hint :retryable :data); the dispatcher turns that into the
;; envelope's `errors' entry.  Error codes are dotted and their first
;; segment picks the CLI exit code: `usage.*' 2, `not_found.*' 3,
;; `rev.*' 4, `*.unreachable' 5, `apply.partial' 6, `wait.timeout' 7,
;; anything else 1.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup etm nil
  "Drive Emacs workspaces, panes and terminals from outside, as JSON verbs."
  :group 'tools
  :prefix "etm-")

(defconst etm-schema "etm.result/1"
  "Schema tag of every envelope etm answers with.")

(defconst etm-protocol 1
  "Request protocol version this dispatcher speaks.")

(define-error 'etm-error "etm error")

(defvar etm--warnings nil
  "Warnings accumulated by the verb running now, newest first.
Bound per request by `etm-dispatch'.")

(defvar etm--next nil
  "`next' hints accumulated by the verb running now, newest first.
Bound per request by `etm-dispatch'.")

(defun etm-fail (code msg &rest props)
  "Signal a typed etm error with CODE (a dotted string) and MSG.
PROPS may carry :hint STRING, :retryable BOOL, :quiet BOOL and :data
PLIST (partial data the envelope still reports, e.g. the cursor at a
wait timeout)."
  (signal 'etm-error (list (append (list :code code :msg msg) props))))

(defun etm-warn (code msg &rest props)
  "Record a warning CODE/MSG (plus PROPS) on the current envelope."
  (push (append (list :code code :msg msg) props) etm--warnings))

(defun etm-next (&rest commands)
  "Offer COMMANDS (strings) as the envelope's `next' hints, in order."
  (setq etm--next (append (reverse commands) etm--next)))

;;;; Request arguments

(defun etm--arg-name (key)
  "The JSON name of argument KEY (a keyword)."
  (substring (symbol-name key) 1))

(defun etm-arg (args key &optional default)
  "Value of KEY (a keyword) in the request ARGS plist, else DEFAULT.
JSON null and an absent key both read as DEFAULT."
  (let ((v (plist-get args key)))
    (if (null v) default v)))

(defun etm-arg-string (args key &optional required)
  "String value of KEY in ARGS; signal `usage.*' unless it is one.
With REQUIRED, an absent or empty value is a usage error too."
  (let ((v (plist-get args key)))
    (cond
     ((and (null v) required)
      (etm-fail "usage.missing_arg"
                (format "missing required argument `%s'" (etm--arg-name key))))
     ((null v) nil)
     ((not (stringp v))
      (etm-fail "usage.bad_arg"
                (format "argument `%s' must be a string" (etm--arg-name key))))
     ((and required (string-empty-p v))
      (etm-fail "usage.missing_arg"
                (format "argument `%s' is empty" (etm--arg-name key))))
     (t v))))

(defun etm-arg-number (args key default)
  "Numeric value of KEY in ARGS, else DEFAULT; `usage.bad_arg' if not."
  (let ((v (plist-get args key)))
    (cond
     ((null v) default)
     ((numberp v) v)
     (t (etm-fail "usage.bad_arg"
                  (format "argument `%s' must be a number" (etm--arg-name key)))))))

(defun etm-arg-int (args key default)
  "Integer value of KEY in ARGS, else DEFAULT (JSON 2.0 is read as 2)."
  (let ((v (etm-arg-number args key default)))
    (if (numberp v) (truncate v) v)))

(defun etm-arg-bool (args key)
  "Non-nil when KEY in ARGS is JSON true."
  (eq (plist-get args key) t))

;;;; Addresses

(defconst etm--key-regexp "\\`[A-Za-z0-9][A-Za-z0-9._:+-]*\\'"
  "A pane key: the caller's own name for a pane (`pm', `eng.2').")

(defun etm-valid-key-p (key)
  "Non-nil when KEY is a well-formed pane key."
  (and (stringp key) (string-match-p etm--key-regexp key)))

(defun etm-parse-addr (addr)
  "Split ADDR `<workspace>/<pane-key>' into (WORKSPACE . KEY).
WORKSPACE is nil for a bare KEY (the current workspace).  The split is
on the LAST slash, so workspace labels may themselves contain one."
  (unless (and (stringp addr) (not (string-empty-p addr)))
    (etm-fail "usage.bad_addr" "pane address must be a non-empty string"
              :hint "address panes as <workspace>/<pane-key>"))
  (let* ((slash (cl-position ?/ addr :from-end t))
         (ws (and slash (substring addr 0 slash)))
         (key (if slash (substring addr (1+ slash)) addr)))
    (unless (etm-valid-key-p key)
      (etm-fail "usage.bad_addr" (format "bad pane key in address `%s'" addr)
                :hint "pane keys match [A-Za-z0-9][A-Za-z0-9._:+-]*"))
    (cons (and ws (not (string-empty-p ws)) ws) key)))

;;;; Cursors

(defun etm-cursor-format (buffer-id pos)
  "Capture cursor for BUFFER-ID (a stable buffer id) at character POS."
  (format "c1:%s:%d" buffer-id pos))

(defun etm-cursor-parse (cursor)
  "Parse CURSOR into (BUFFER-ID . POS); `usage.bad_cursor' if malformed."
  (if (and (stringp cursor)
           (string-match "\\`c1:\\([0-9a-z]+\\):\\([0-9]+\\)\\'" cursor))
      (cons (match-string 1 cursor) (string-to-number (match-string 2 cursor)))
    (etm-fail "usage.bad_cursor" (format "malformed cursor `%s'" cursor)
              :hint "pass a cursor exactly as a previous capture returned it")))

(defun etm-new-id ()
  "A fresh 32-hex-char id, distinct across sessions and processes."
  (md5 (format "%s-%s-%s" (float-time) (emacs-pid)
               (random most-positive-fixnum))))

;;;; JSON

(defconst etm--json-array-keys
  '(:windows :events :resources :owned :orphans :rows :warnings :errors
             :next)
  "Plist keys whose nil value means an empty JSON array.")

(defun etm--plist-p (value)
  "Non-nil if VALUE is a non-empty proper list whose head is a keyword."
  (and (consp value) (keywordp (car value)) (proper-list-p value)))

(defun etm-json-safe (value)
  "VALUE converted into something `json-serialize' accepts.
Plists become objects; lists of plists and other lists become arrays;
alists of (SYMBOL . VALUE) become objects; symbols become their names
\(keywords and t pass through); a nil leaf becomes JSON null, except
under the keys in `etm--json-array-keys', where it is an empty array."
  (cond
   ((null value) :null)
   ((eq value t) t)
   ((keywordp value) value)
   ((vectorp value) (vconcat (mapcar #'etm-json-safe value)))
   ((etm--plist-p value)
    (let (out (rest value))
      (while rest
        (let ((k (pop rest)) (v (pop rest)))
          (push k out)
          (push (if (and (null v) (memq k etm--json-array-keys))
                    []
                  (etm-json-safe v))
                out)))
      (nreverse out)))
   ((and (proper-list-p value)
         (cl-every (lambda (el) (and (consp el) (keywordp (car el)))) value))
    (vconcat (mapcar #'etm-json-safe value)))
   ((and (proper-list-p value)
         (cl-every (lambda (el) (and (consp el) (symbolp (car el))
                                     (not (keywordp (car el)))))
                   value))
    (mapcar (lambda (pair) (cons (car pair) (etm-json-safe (cdr pair)))) value))
   ((consp value) (vconcat (mapcar #'etm-json-safe
                                   (if (proper-list-p value)
                                       value
                                     (list (car value) (cdr value))))))
   ((symbolp value) (symbol-name value))
   ((or (stringp value) (numberp value)) value)
   (t (prin1-to-string value))))

(defun etm--json-scrub (value)
  "VALUE with every string's non-Unicode chars replaced by U+FFFD.
Terminal buffers can hold raw bytes, which `json-serialize' rejects;
this is the slow path, run only after a serialization failure."
  (cond
   ((stringp value)
    (if (cl-some (lambda (c) (> c #x10FFFF)) value)
        (concat (mapcar (lambda (c) (if (> c #x10FFFF) #xFFFD c)) value))
      value))
   ((vectorp value) (vconcat (mapcar #'etm--json-scrub value)))
   ((consp value)
    (cons (etm--json-scrub (car value)) (etm--json-scrub (cdr value))))
   (t value)))

(defun etm-json-encode (value)
  "Serialize VALUE (already `etm-json-safe'd) to a unibyte UTF-8 string."
  (let ((s (condition-case nil
               (json-serialize value)
             (error (json-serialize (etm--json-scrub value))))))
    (if (multibyte-string-p s) (encode-coding-string s 'utf-8 t) s)))

(defun etm-json-decode (json)
  "Parse request JSON (a string) into a plist; null and false read as nil."
  (json-parse-string json :object-type 'plist :array-type 'array
                     :null-object nil :false-object nil))

(provide 'etm-base)
;;; etm-base.el ends here

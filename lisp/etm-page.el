;;; etm-page.el --- Page panes for etm: named views rendered off the server loop -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; URL: https://github.com/davidawad/etm
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A `page' pane shows a named view: a function that displays a buffer
;; (a dashboard, an agenda, a board).  Names resolve through
;; `etm-page-types' (NAME -> FUNCTION), then the resolvers in
;; `etm-page-type-functions' (by default: an interactive command of
;; that name).
;;
;; Running a page inside `pane.new' would run it inside server.el's
;; process filter, where a page that prompts, or fetches synchronously,
;; wedges the whole server.  So `pane.new' answers at once with a
;; placeholder buffer registered as the pane (`page_state'
;; "rendering"), and the page renders on a timer, where the server
;; keeps answering while it waits.  The render binds
;; `inhibit-interaction', so a page that would prompt fails as
;; `page.needs_input' instead.  Once the page shows its buffer, that
;; buffer takes over the pane (registry row, windows, tags) and the
;; placeholder dies; a failed render leaves the placeholder holding the
;; error.
;;
;; A page function that needs arguments declares how to get them from
;; the workspace: the symbol property `etm-page-args' holds a function
;; of the plist (:subject S :dir D) returning the argument list.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etm-base)
(require 'etm-backend)
(require 'etm-ext)

(defcustom etm-page-types nil
  "Registered page types, an alist (NAME . FUNCTION).
NAME is the string a pane asks for (`--page NAME'); FUNCTION displays a
buffer: it is called interactively when it is a command without
`etm-page-args', else with the arguments those return."
  :type '(alist :key-type string :value-type function)
  :group 'etm)

(defcustom etm-page-type-functions (list #'etm-page-command-type)
  "Resolvers for page names `etm-page-types' does not list.
Each is called with NAME and returns a page function or nil."
  :type 'hook
  :group 'etm)

(defcustom etm-page-delay 0
  "Seconds after `pane.new' answers before its page renders."
  :type 'number
  :group 'etm)

(defcustom etm-page-slow-ms 2000
  "A render longer than this many milliseconds fails a doctor row."
  :type 'integer
  :group 'etm)

(defcustom etm-page-stuck-seconds 60
  "A page still rendering after this many seconds fails a doctor row."
  :type 'integer
  :group 'etm)

(defvar-local etm-page-state nil
  "Render state of a page pane: \"rendering\", \"ready\" or \"failed\".")
(put 'etm-page-state 'permanent-local t)

(defvar-local etm-page--info nil
  "Plist about this page's render: :page :started :ms :code :msg.")
(put 'etm-page--info 'permanent-local t)

(defvar etm-page-tag-variables nil
  "Buffer-local tag variables a page buffer takes over from its placeholder.
etm-pane.el fills this in.")

(defun etm-page-command-type (name)
  "The interactive command named NAME, or nil."
  (let ((cmd (intern-soft name)))
    (and cmd (commandp cmd) cmd)))

(defun etm-page-function (name)
  "The page function for NAME; `capability.unavailable' when none."
  (or (cdr (assoc name etm-page-types))
      (run-hook-with-args-until-success 'etm-page-type-functions name)
      (etm-fail "capability.unavailable"
                (format "page `%s' is not available in this Emacs" name)
                :hint "register it in `etm-page-types', or mount without it")))

(defun etm-page-names ()
  "Names of the registered page types."
  (mapcar #'car etm-page-types))

(defun etm-page-make (label page dir ws)
  "Placeholder buffer LABEL for PAGE, rendered from DIR on a timer.
WS is the pane's workspace."
  (let ((fn (etm-page-function page))
        (buf (generate-new-buffer label)))
    (with-current-buffer buf
      (setq default-directory dir)
      (insert (format "Rendering page `%s'...\n" page))
      (special-mode)
      (setq etm-page-state "rendering"
            etm-page--info (list :page page :started (float-time))))
    (run-at-time etm-page-delay nil #'etm-page--render buf fn dir ws)
    buf))

(defun etm-page--shown ()
  "Buffers in the selected frame's windows."
  (mapcar #'window-buffer (window-list nil 'nomini)))

(defun etm-page--run (fn dir subject)
  "Run page function FN from DIR, never prompting; return the buffer it showed.
SUBJECT feeds FN's `etm-page-args'.  The buffer is the selected
window's when that changed, else one newly shown in the frame, else nil."
  (let ((default-directory dir)
        (inhibit-interaction t)
        (args (and (symbolp fn) (get fn 'etm-page-args))))
    (save-window-excursion
      (let ((before (etm-page--shown)))
        (cond (args (apply fn (funcall args (list :subject subject :dir dir))))
              ((commandp fn) (call-interactively fn))
              (t (funcall fn)))
        (let ((sel (window-buffer (selected-window))))
          (if (memq sel before)
              (cl-find-if-not (lambda (b) (memq b before)) (etm-page--shown))
            sel))))))

(defun etm-page--render (placeholder fn dir ws)
  "Timer body: render FN for PLACEHOLDER's pane in WS from DIR.
A pane killed meanwhile is left alone.  Never signals."
  (when (buffer-live-p placeholder)
    (let ((t0 (float-time)) buf err)
      (condition-case e
          (setq buf (etm-page--run fn dir (ignore-errors
                                            (etm-backend-parameter
                                             (etm-backend) (etm-ws-handle ws)
                                             (etm-tag-parameter 'subject)))))
        (inhibited-interaction
         (setq err (list "page.needs_input"
                         (format "`%s' prompts for input; give it `etm-page-args'" fn))))
        (error (setq err (list "page.failed" (error-message-string e)))))
      (let ((ms (round (* 1000 (- (float-time) t0)))))
        (cond
         (err (etm-page--fail placeholder ms (car err) (cadr err)))
         ((or (null buf) (eq buf placeholder))
          (etm-page--fail placeholder ms "page.no_buffer"
                          (format "`%s' showed no buffer" fn)))
         (t (condition-case e
                (etm-page--adopt placeholder buf ws ms)
              (error (etm-page--fail placeholder ms "page.failed"
                                     (error-message-string e))))))))))

(defun etm-page--log (level fmt &rest args)
  "Record an event at LEVEL (FMT and ARGS); never signals."
  (ignore-errors (apply #'etm-event-log level fmt args)))

(defun etm-page--fail (placeholder ms code msg)
  "Leave PLACEHOLDER as the pane, showing CODE and MSG; MS is the render time."
  (with-current-buffer placeholder
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "Page `%s' did not render (%s):\n\n%s\n"
                      (plist-get etm-page--info :page) code msg)))
    (setq etm-page-state "failed"
          etm-page--info (append (list :ms ms :code code :msg msg) etm-page--info))
    (etm-page--log 'warn "page %s %s: %s" (plist-get etm-page--info :page) code msg)))

(defun etm-page--adopt (placeholder buf ws ms)
  "Make BUF the pane of WS in place of PLACEHOLDER; MS is the render time."
  (let ((info (buffer-local-value 'etm-page--info placeholder))
        (tags (mapcar (lambda (v) (cons v (buffer-local-value v placeholder)))
                      etm-page-tag-variables)))
    (with-current-buffer buf
      (dolist (tag tags) (set (make-local-variable (car tag)) (cdr tag)))
      (setq etm-page-state "ready"
            etm-page--info (append (list :ms ms) info)))
    (etm-resource-replace placeholder buf)
    (ignore-errors (etm-backend-add-buffer (etm-backend) (etm-ws-handle ws) buf))
    (dolist (win (get-buffer-window-list placeholder nil t))
      (set-window-buffer win buf))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer placeholder))
    (etm-page--log (if (> ms etm-page-slow-ms) 'warn 'debug)
                   "page %s ready in %dms" (plist-get info :page) ms)))

(defun etm-page-record (buffer)
  "The `page' part of a pane record for BUFFER, or nil for other panes."
  (with-current-buffer buffer
    (when etm-page-state
      (list :page_state etm-page-state
            :page_ms (or (plist-get etm-page--info :ms) :null)
            :page_error (or (plist-get etm-page--info :code) :null)))))

(defun etm-page--panes ()
  "Live page pane buffers with their render info: (BUFFER STATE . INFO)."
  (cl-loop for b in (buffer-list)
           for state = (buffer-local-value 'etm-page-state b)
           when state
           collect (cons b (cons state (buffer-local-value 'etm-page--info b)))))

(defun etm-page--describe (rows)
  "One line naming each of ROWS ((BUFFER STATE . INFO)) with its detail."
  (mapconcat
   (lambda (r)
     (let ((info (cddr r)))
       (format "%s (%s%s)" (plist-get info :page) (cadr r)
               (cond ((plist-get info :code)
                      (format ": %s %s" (plist-get info :code) (plist-get info :msg)))
                     ((plist-get info :ms) (format " in %dms" (plist-get info :ms)))
                     (t (format " for %ds" (- (float-time) (plist-get info :started))))))))
   rows "; "))

(defun etm-page-probes (probe)
  "Doctor rows about page renders, each built by PROBE (CHECK OK HINT)."
  (let* ((pages (etm-page--panes))
         (bad (cl-remove-if-not
               (lambda (r)
                 (or (equal (cadr r) "failed")
                     (and (equal (cadr r) "rendering")
                          (> (- (float-time) (plist-get (cddr r) :started))
                             etm-page-stuck-seconds))))
               pages))
         (slow (cl-remove-if-not
                (lambda (r) (> (or (plist-get (cddr r) :ms) 0) etm-page-slow-ms))
                pages)))
    (list
     (funcall probe "etm.pages" (null bad)
              (if bad
                  (concat "page panes not rendered: " (etm-page--describe bad))
                "every page pane rendered or is rendering"))
     (funcall probe "etm.pages-responsive" (null slow)
              (if slow
                  (concat "pages that rendered past the read budget (the server "
                          "may not answer during a blocking render; make it async): "
                          (etm-page--describe slow))
                "page renders stay within the read budget")))))

(provide 'etm-page)
;;; etm-page.el ends here

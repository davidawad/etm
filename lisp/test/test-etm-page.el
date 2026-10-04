;;; test-etm-page.el --- etm page panes render off the server loop -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The page half of `pane.new' (etm-page.el).  The load-bearing claims:
;; `pane.new' answers before the page runs (a placeholder holds the
;; pane); the page renders on a timer and its buffer then takes over the
;; pane's registry row and tags; a page that would prompt fails as
;; `page.needs_input' instead of wedging the server; `etm-page-args'
;; feeds a page its argument from the workspace; names resolve through
;; `etm-page-types' and `etm-page-type-functions'; doctor names failed,
;; stuck and slow renders.  The live proof that the server answers while
;; a page renders is the CLI's daemon test (tests/pages.rs).

;;; Code:

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "etm-test-support.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(defun etm-test--drain-pages ()
  "Run the pending page timers (batch Emacs runs timers while waiting)."
  (let ((tries 0))
    (while (and (< tries 100)
                (cl-some (lambda (b) (equal (buffer-local-value 'etm-page-state b)
                                            "rendering"))
                         (buffer-list)))
      (accept-process-output nil 0.01)
      (cl-incf tries))))

(defun etm-test--pane (addr)
  "The pane record of ADDR from `pane.ls'."
  (cl-find addr (etm-test-data "pane.ls" :ws "*")
           :key (lambda (p) (plist-get p :addr)) :test #'equal))

(defun etm-test--doctor-row (check)
  "The doctor row CHECK."
  (cl-find check (plist-get (etm-test-data "doctor") :rows)
           :key (lambda (r) (plist-get r :check)) :test #'equal))

(defmacro etm-test--with-page (body-fn &rest body)
  "Run BODY with `etm-test-page' an interactive command running BODY-FN."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'etm-test-page)
              (lambda () (interactive) (funcall ,body-fn))))
     ,@body))

(defun etm-test--show-page ()
  "What a board command does: show its buffer in the selected window."
  (switch-to-buffer (get-buffer-create "*etm-test-page*")))

(ert-deftest etm-page-answers-first-then-renders-on-a-timer ()
  (etm-test-with-clean
    (let ((ran 0))
      (etm-test--with-page (lambda () (cl-incf ran) (etm-test--show-page))
        (let ((made (etm-test-data "pane.new" :key "tasks" :kind "page"
                                    :page "etm-test-page")))
          (should (= ran 0))
          (should (eq (plist-get made :created) t))
          (should (equal (plist-get made :page_state) "rendering"))
          (should (string-prefix-p "*etm:global/tasks*" (plist-get made :buffer)))
          (etm-test--drain-pages)
          (should (= ran 1))
          (let ((page (get-buffer "*etm-test-page*"))
                (now (etm-test--pane "global/tasks")))
            (should (equal (plist-get now :buffer) "*etm-test-page*"))
            (should (equal (plist-get now :page_state) "ready"))
            (should (integerp (plist-get now :page_ms)))
            (should-not (equal (plist-get now :buffer_id) (plist-get made :buffer_id)))
            (should (equal (buffer-local-value 'etm-pane-key page) "tasks"))
            (should (equal (buffer-local-value 'etm-pane-kind page) "page"))
            (should (etm-resource-registered-p page))
            (should-not (get-buffer (plist-get made :buffer)))
            ;; Idempotent (W3): the rendered page is the pane now.
            (let ((again (etm-test-data "pane.new" :key "tasks" :kind "page"
                                         :page "etm-test-page")))
              (should (eq (plist-get again :created) :false))
              (should (equal (plist-get again :buffer) "*etm-test-page*")))
            (should (= ran 1))
            (should (equal (plist-get (etm-test--doctor-row "etm.pages") :status)
                           "pass"))))))))

(ert-deftest etm-page-that-prompts-fails-instead-of-waiting ()
  "A page reading a key with `completing-read' inside server.el's filter
left a daemon with no frame waiting forever."
  (etm-test-with-clean
    (etm-test--with-page
        (lambda ()
          (etm-test--show-page)
          (completing-read "KPI project: " '("a" "b") nil t))
      (etm-test-data "pane.new" :key "kpi" :kind "page" :page "etm-test-page")
      (etm-test--drain-pages)
      (let ((pane (etm-test--pane "global/kpi")))
        (should (equal (plist-get pane :page_state) "failed"))
        (should (equal (plist-get pane :page_error) "page.needs_input"))
        (should (string-prefix-p "*etm:global/kpi*" (plist-get pane :buffer))))
      (let ((row (etm-test--doctor-row "etm.pages")))
        (should (equal (plist-get row :status) "fail"))
        (should (string-match-p "page.needs_input" (plist-get row :hint)))))))

(ert-deftest etm-page-args-come-from-the-workspace ()
  (etm-test-with-clean
    (etm-test-with-persps '("main")
      (let (seen)
        (cl-letf (((symbol-function 'etm-test-arg-page)
                   (lambda (key)
                     (interactive (list (read-string "key: ")))
                     (setq seen key)
                     (etm-test--show-page))))
          (put 'etm-test-arg-page 'etm-page-args
               (lambda (ctx)
                 (list (string-remove-prefix "project:" (plist-get ctx :subject)))))
          (unwind-protect
              (progn
                (etm-test-data "ws.new" :ws "project:demo" :subject "project:demo")
                (etm-test-data "pane.new" :ws "project:demo" :key "kpi" :kind "page"
                                :page "etm-test-arg-page")
                (etm-test--drain-pages)
                (should (equal seen "demo"))
                (should (equal (plist-get (etm-test--pane "project:demo/kpi") :page_state)
                               "ready")))
            (put 'etm-test-arg-page 'etm-page-args nil)))))))

(ert-deftest etm-page-killed-before-render-never-runs ()
  (etm-test-with-clean
    (let ((ran 0))
      (etm-test--with-page (lambda () (cl-incf ran) (etm-test--show-page))
        (etm-test-data "pane.new" :key "p" :kind "page" :page "etm-test-page")
        (etm-test-data "pane.kill" :addr "global/p")
        (accept-process-output nil 0.05)
        (should (= ran 0))))))

(ert-deftest etm-page-that-shows-nothing-is-no-buffer ()
  (etm-test-with-clean
    (etm-test--with-page #'ignore
      (etm-test-data "pane.new" :key "p" :kind "page" :page "etm-test-page")
      (etm-test--drain-pages)
      (should (equal (plist-get (etm-test--pane "global/p") :page_error)
                     "page.no_buffer")))))

(ert-deftest etm-page-slow-render-fails-the-responsive-row ()
  (etm-test-with-clean
    (etm-test--with-page #'etm-test--show-page
      (let ((etm-page-slow-ms -1))
        (etm-test-data "pane.new" :key "p" :kind "page" :page "etm-test-page")
        (etm-test--drain-pages)
        (let ((row (etm-test--doctor-row "etm.pages-responsive")))
          (should (equal (plist-get row :status) "fail"))
          (should (string-match-p "etm-test-page (ready in" (plist-get row :hint))))))))

(ert-deftest etm-page-types-registry-resolves-names ()
  (etm-test-with-clean
    (let* (ran
           (etm-page-types `(("board" . ,(lambda () (setq ran t) (etm-test--show-page)))))
           (etm-page-type-functions nil))
      (etm-test-data "pane.new" :key "b" :kind "page" :page "board")
      (etm-test--drain-pages)
      (should ran)
      (should (equal (plist-get (etm-test--pane "global/b") :page_state) "ready"))
      (should (equal (plist-get (etm-test-data "capabilities") :pages) '("board")))
      ;; Without the command fallback, a bare command name is not a page.
      (cl-letf (((symbol-function 'etm-test-page) (lambda () (interactive))))
        (should (equal (etm-test-error-code
                        (etm-test-call "pane.new" :key "c" :kind "page" :page "etm-test-page"))
                       "capability.unavailable"))))))

(ert-deftest etm-page-type-functions-resolve-dynamic-catalogs ()
  (etm-test-with-clean
    (let ((etm-page-type-functions
           (list (lambda (name) (and (equal name "dyn") #'etm-test--show-page)))))
      (etm-test-data "pane.new" :key "d" :kind "page" :page "dyn")
      (etm-test--drain-pages)
      (should (equal (plist-get (etm-test--pane "global/d") :page_state) "ready")))))

(provide 'test-etm-page)
;;; test-etm-page.el ends here

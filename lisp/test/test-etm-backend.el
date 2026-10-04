;;; test-etm-backend.el --- The workspace backend contract, per real backend -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; One contract, run against whichever real backend the session has
;; on: run-tests.sh starts a throwaway `emacs -Q --daemon' per backend
;; (persp-mode, tabspaces, tab-bar, single), turns that backend's mode
;; on, sets ETM_TEST_BACKEND to its name and runs this suite there.
;; With `etm-workspace-backend' left at `auto', the first claim is that
;; detection picks that backend.  The rest hold for every backend that
;; can make workspaces: create without switching, tags, switch, panes
;; addressed in a background workspace, the same key in two workspaces
;; as two buffers, membership, rename keeping identity, kill reaping the
;; panes.  `single' instead refuses every mutating verb.

;;; Code:

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "etm-test-support.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(defun etm-test-backend-expected ()
  "The backend this run is for (ETM_TEST_BACKEND), as a symbol."
  (intern (or (getenv "ETM_TEST_BACKEND") "single")))

(defmacro etm-test-with-backend (&rest body)
  "Run BODY with etm's defaults but the auto-detected backend.
Workspaces BODY created are removed again."
  (declare (indent 0))
  `(etm-test-with-clean
     (let* ((etm-workspace-backend 'auto)
            (b (etm-backend))
            (before (etm-backend-list b)))
       (unwind-protect (progn ,@body)
         (when (etm-backend-mutable-p b)
           (ignore-errors (etm-backend-switch b (car before)))
           (dolist (h (etm-backend-list b))
             (unless (member h before)
               (ignore-errors (etm-backend-kill b h)))))))))

(defun etm-test-names ()
  "Names of every workspace, as `ws.ls' reports them."
  (mapcar (lambda (w) (plist-get w :name)) (etm-test-data "ws.ls")))

(ert-deftest etm-backend-auto-detects-the-backend-in-use ()
  (etm-test-with-backend
    (should (eq (etm-backend) (etm-test-backend-expected)))
    (should (equal (plist-get (etm-test-data "capabilities") :workspaces)
                   (symbol-name (etm-test-backend-expected))))
    (should (equal (plist-get (etm-test-data "snapshot") :backend)
                   (symbol-name (etm-test-backend-expected))))))

(ert-deftest etm-backend-current-workspace-is-listed ()
  (etm-test-with-backend
    (let* ((cur (etm-test-data "ws.get"))
           (all (etm-test-data "ws.ls")))
      (should (eq (plist-get cur :current) t))
      (should (member (plist-get cur :id) (mapcar (lambda (w) (plist-get w :id)) all)))
      (should (= 1 (cl-count t all :key (lambda (w) (plist-get w :current))))))))

(ert-deftest etm-backend-single-refuses-to-mutate ()
  (skip-unless (eq (etm-test-backend-expected) 'single))
  (etm-test-with-backend
    (should (equal (etm-test-names) '("global")))
    (dolist (verb '("ws.new" "ws.switch" "ws.rename" "ws.kill"))
      (should (equal (etm-test-error-code (etm-test-call verb :ws "global" :name "x"))
                     "capability.unavailable")))
    (etm-test-data "pane.new" :ws "global" :key "sh" :kind "cmd" :cmd "cat")
    (should (equal (plist-get (car (etm-test-data "pane.ls")) :addr) "global/sh"))))

(ert-deftest etm-backend-workspace-lifecycle ()
  (skip-unless (not (eq (etm-test-backend-expected) 'single)))
  (etm-test-with-backend
    (let* ((home (plist-get (etm-test-data "ws.get") :name))
           (made (etm-test-data "ws.new" :ws "etm-a" :subject "project:a"
                                :spec "r1" :owner "me")))
      ;; Created, tagged, not shown.
      (should (eq (plist-get made :created) t))
      (should (eq (plist-get made :current) :false))
      (should (equal (plist-get (etm-test-data "ws.get") :name) home))
      (should (member "etm-a" (etm-test-names)))
      (should (equal (list (plist-get made :tag) (plist-get made :subject)
                           (plist-get made :spec) (plist-get made :owner))
                     '("etm-a" "project:a" "r1" "me")))
      ;; Idempotent; the owner stays the creator.
      (let ((again (etm-test-data "ws.new" :ws "etm-a" :owner "other" :spec "r2")))
        (should (eq (plist-get again :created) :false))
        (should (equal (plist-get again :id) (plist-get made :id)))
        (should (equal (plist-get again :owner) "me"))
        (should (equal (plist-get again :spec) "r2")))
      ;; A pane in the background workspace is addressable.
      (etm-test-data "pane.new" :ws "etm-a" :key "sh" :kind "cmd" :cmd "cat")
      (should (equal (plist-get (car (etm-test-data "pane.ls" :ws "etm-a")) :addr)
                     "etm-a/sh"))
      (should (null (etm-test-data "pane.ls" :ws home)))
      ;; Switch.
      (should (eq (plist-get (etm-test-data "ws.switch" :ws "etm-a") :current) t))
      (should (equal (plist-get (etm-test-data "ws.get") :name) "etm-a"))
      (etm-test-data "ws.switch" :ws home)
      ;; Rename keeps identity and the pane.
      (let ((renamed (etm-test-data "ws.rename" :ws "etm-a" :name "etm-b")))
        (should (equal (plist-get renamed :id) (plist-get made :id)))
        (should (equal (plist-get renamed :old_name) "etm-a")))
      (should (equal (etm-test-error-code (etm-test-call "ws.get" :ws "etm-a"))
                     "not_found.workspace"))
      (should (equal (plist-get (car (etm-test-data "pane.ls" :ws "etm-b")) :addr)
                     "etm-b/sh"))
      (should (equal (plist-get (etm-test-data "ws.get" :ws (plist-get made :id)) :name)
                     "etm-b"))
      ;; Kill reaps the pane.
      (let ((buf (etm-test-pane-buffer "etm-b/sh")))
        (should (eq (plist-get (etm-test-data "ws.kill" :ws "etm-b") :killed) t))
        (should-not (buffer-live-p buf)))
      (should-not (member "etm-b" (etm-test-names))))))

(ert-deftest etm-backend-same-key-two-workspaces-two-buffers ()
  (skip-unless (not (eq (etm-test-backend-expected) 'single)))
  (etm-test-with-backend
    (etm-test-data "ws.new" :ws "etm-x")
    (etm-test-data "ws.new" :ws "etm-y")
    (dolist (ws '("etm-x" "etm-y"))
      (etm-test-data "pane.new" :ws ws :key "sh" :kind "cmd" :cmd "cat"))
    (let ((bx (etm-test-pane-buffer "etm-x/sh"))
          (by (etm-test-pane-buffer "etm-y/sh"))
          (b (etm-backend)))
      (should-not (eq bx by))
      ;; Membership: each pane buffer belongs to its own workspace.
      (should (memq bx (etm-backend-buffers b (etm-ws-handle (etm-ws-resolve "etm-x")))))
      (should (memq by (etm-backend-buffers b (etm-ws-handle (etm-ws-resolve "etm-y")))))
      (should-not (memq bx (etm-backend-buffers b (etm-ws-handle (etm-ws-resolve "etm-y"))))))))

(ert-deftest etm-backend-parameters-round-trip ()
  (etm-test-with-backend
    (let* ((b (etm-backend))
           (h (if (etm-backend-mutable-p b)
                  (etm-ws-handle (progn (etm-test-data "ws.new" :ws "etm-p")
                                        (etm-ws-resolve "etm-p")))
                (etm-backend-current b))))
      (etm-backend-set-parameter b h 'etm-test-param '(1 2))
      (should (equal (etm-backend-parameter b h 'etm-test-param) '(1 2)))
      (should (equal (etm-backend-id b h) (etm-backend-id b h)))
      (when (etm-backend-mutable-p b)
        ;; Survives showing another workspace and coming back.
        (etm-test-data "ws.switch" :ws "etm-p")
        (etm-test-data "ws.switch" :ws (etm-backend-name b (car (etm-backend-list b))))
        (should (equal (etm-backend-parameter b h 'etm-test-param) '(1 2)))))))

(defun etm-test-backend-run (file)
  "Run the backend suite, writing its report to FILE; return unexpected count."
  ;; Emacs 29's ERT sees a test's skip or failure only through `debugger',
  ;; which a plain `condition-case' suppresses -- and the server wraps
  ;; `emacsclient --eval' in one, so the signal would escape the whole
  ;; run.  A `debug' handler in between lets ERT's debugger see it again.
  (let* ((stats (condition-case nil
                    (ert-run-tests-batch "^etm-backend-")
                  ((debug error) nil)))
         (bad (if stats (ert-stats-completed-unexpected stats) 1)))
    (with-temp-file file
      (insert (with-current-buffer (messages-buffer) (buffer-string))
              (format "\nETM-RESULT %s %d\n" (etm-test-backend-expected) bad)))
    bad))

(provide 'test-etm-backend)
;;; test-etm-backend.el ends here

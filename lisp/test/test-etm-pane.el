;;; test-etm-pane.el --- etm panes: identity, layout, send/capture/wait -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The pane half of etm.  The load-bearing claims: a pane IS the buffer
;; the resolver registers for (workspace x `etm-pane:<key>'), so one key
;; in two workspaces is two isolated buffers (a category check across
;; every pane kind); a region in a background workspace waits for
;; `pane focus'; capture cursors return only what is new; wait polls
;; never block and only the deciding check is logged.

;;; Code:

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "etm-test-support.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

;;;; Identity

(ert-deftest etm-pane-same-key-two-workspaces-two-buffers ()
  "Every kind, both workspaces: disjoint, owned, registered.
Editor and tree panes are the trap: Emacs hands every caller the one
buffer visiting a file or directory, so without per-workspace buffers
the second workspace silently steals the first one's pane."
  (etm-test-with-clean
    (etm-test-with-persps '("a" "b")
      (let ((file (make-temp-file "etm-ed")) (dir (make-temp-file "etm-tree" t)))
        (dolist (spec `(("sh" "shell") ("job" "cmd" :cmd "cat") ("ed" "editor" :path ,file)
                        ("tree" "tree" :path ,dir)))
          (dolist (ws '("a" "b"))
            (apply #'etm-test-data "pane.new" :ws ws :key (car spec) :kind (cadr spec)
                   (cddr spec))))
        (dolist (key '("sh" "job"))
          (let ((ba (etm-test-pane-buffer (concat "a/" key)))
                (bb (etm-test-pane-buffer (concat "b/" key))))
            (should-not (eq ba bb))
            (should (equal (buffer-local-value 'etm--owner ba)
                           (etm-backend-id 'persp-mode (car etm-test--persps))))
            (should (equal (buffer-local-value 'etm--owner bb)
                           (etm-backend-id 'persp-mode (cadr etm-test--persps))))
            (should (equal (cdr (etm-resource-default-row ba))
                           (intern (concat "etm-pane:" key))))))
        (let ((a (mapcar (lambda (p) (plist-get p :buffer_id)) (etm-test-data "pane.ls" :ws "a")))
              (b (mapcar (lambda (p) (plist-get p :buffer_id)) (etm-test-data "pane.ls" :ws "b"))))
          (should (= 4 (length a)))
          (should (= 4 (length b)))
          (should-not (cl-intersection a b :test #'equal)))
        (dolist (key '("ed" "tree"))
          (should-not (eq (etm-test-pane-buffer (concat "a/" key))
                          (etm-test-pane-buffer (concat "b/" key)))))
        (should (memq (etm-test-pane-buffer "a/sh")
                      (etm-test-persp-buffers (car etm-test--persps))))))))

(ert-deftest etm-pane-new-is-idempotent-and-kind-checked ()
  (etm-test-with-clean
    (let ((first (etm-test-data "pane.new" :key "sh" :kind "shell")))
      (should (eq (plist-get first :created) t))
      (should (equal (plist-get first :addr) "global/sh"))
      (should (equal (plist-get first :mode) "eshell-mode"))
      (let ((again (etm-test-data "pane.new" :key "sh" :kind "shell")))
        (should (eq (plist-get again :created) :false))
        (should (equal (plist-get again :buffer_id) (plist-get first :buffer_id)))))
    (dolist (case '(((:key "sh" :kind "cmd" :cmd "true") . "conflict.kind_mismatch")
                    ((:key "pg" :kind "agent") . "capability.unsupported_kind")
                    ((:key "pg" :kind "page" :page "etm-test-no-such-page")
                     . "capability.unavailable")
                    ((:key "c" :kind "cmd") . "usage.missing_arg")
                    ((:key "x" :kind "shell" :region "middle") . "usage.bad_arg")
                    ((:key "x" :kind "shell" :backend "nope") . "usage.bad_arg")))
      (should (equal (etm-test-error-code (apply #'etm-test-call "pane.new" (car case)))
                     (cdr case))))
    (should (equal (mapcar (lambda (p) (plist-get p :key)) (etm-test-data "pane.ls"))
                   '("sh")))))

(ert-deftest etm-pane-kill-and-not-found ()
  (etm-test-with-clean
    (etm-test-data "pane.new" :key "sh" :kind "shell")
    (should (eq (plist-get (etm-test-data "pane.kill" :addr "global/sh") :killed) t))
    (should (null (etm-test-data "pane.ls")))
    (should (equal (etm-test-error-code (etm-test-call "capture" :addr "global/sh"))
                   "not_found.pane"))
    (should (equal (etm-test-error-code (etm-test-call "capture" :addr "nope/sh"))
                   "not_found.workspace"))))

;;;; Layout

(ert-deftest etm-pane-region-in-a-background-workspace-is-deferred ()
  (etm-test-with-clean
    (etm-test-with-persps '("main" "bg")
      (let* (calls
             (etm-layout-dock-function (lambda (_buf region) (push region calls) nil)))
        (let ((env (etm-test-call "pane.new" :ws "bg" :key "r" :kind "shell"
                                  :region "left")))
          (should (equal (plist-get (car (plist-get env :warnings)) :code)
                         "layout.deferred"))
          (should (null calls)))))))

;;;; Send, capture, wait

(ert-deftest etm-capture-cursor-returns-only-new-text ()
  (etm-test-with-clean
    (let ((file (make-temp-file "etm-cap")))
      (etm-test-data "pane.new" :key "ed" :kind "editor" :path file)
      (with-current-buffer (etm-test-pane-buffer "global/ed") (insert "one\ntwo\n"))
      (let* ((first (etm-test-data "capture" :addr "global/ed"))
             (cursor (plist-get first :cursor)))
        (should (equal (plist-get first :text) "one\ntwo\n"))
        (should (equal (plist-get (etm-test-data "capture" :addr "global/ed" :since cursor)
                                  :text)
                       ""))
        (with-current-buffer (etm-test-pane-buffer "global/ed")
          (goto-char (point-max)) (insert "three\nfour\nfive\n"))
        (should (equal (plist-get (etm-test-data "capture" :addr "global/ed" :since cursor)
                                  :text)
                       "three\nfour\nfive\n"))
        (should (equal (plist-get (etm-test-data "capture" :addr "global/ed" :lines 2) :text)
                       "five\n"))
        (let ((cut (etm-test-data "capture" :addr "global/ed" :max_chars 4)))
          (should (equal (plist-get cut :text) "ive\n"))
          (should (eq (plist-get cut :truncated) t)))
        (with-current-buffer (etm-test-pane-buffer "global/ed") (erase-buffer))
        (let ((env (etm-test-call "capture" :addr "global/ed" :since cursor)))
          (should (equal (plist-get (car (plist-get env :warnings)) :code)
                         "capture.cursor_reset")))))))

(ert-deftest etm-send-refuses-a-pane-without-a-terminal ()
  (etm-test-with-clean
    (etm-test-data "pane.new" :key "ed" :kind "editor" :path (make-temp-file "etm-s"))
    (should (equal (etm-test-error-code (etm-test-call "send" :addr "ed" :text "x"))
                   "pane.not_terminal"))))

(ert-deftest etm-send-then-wait-match-on-a-process-pane ()
  (etm-test-with-clean
    (etm-test-data "pane.new" :key "cat" :kind "cmd" :cmd "cat")
    (let* ((sent (etm-test-data "send" :addr "cat" :text "ping-etm" :enter t))
           (hit (etm-test-data "wait" :addr "cat" :until "match:ping-etm"
                                :since (plist-get sent :cursor) :timeout 5)))
      (should (equal (plist-get hit :match) "ping-etm"))
      (should (string-match-p "ping-etm"
                              (plist-get (etm-test-data "capture" :addr "cat"
                                                         :since (plist-get sent :cursor))
                                         :text))))))

(defconst etm-test-pane--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(ert-deftest etm-wait-match-documented-alternation-example ()
  (etm-test-with-clean
    (etm-test-data "pane.new" :key "alt" :kind "cmd" :cmd "sleep 0.3; echo 2 failed")
    (let ((hit (etm-test-data "wait" :addr "alt" :until "match:passed\\|failed" :timeout 5)))
      (should (equal (plist-get hit :match) "failed")))
    (dolist (f '("../../README.md" "../../docs/etm.texi"))
      (with-temp-buffer
        (insert-file-contents (expand-file-name f etm-test-pane--dir))
        (should (search-forward "match:'passed\\|failed'" nil t))))))

(ert-deftest etm-cmd-pane-honours-path ()
  (etm-test-with-clean
    (let* ((dir (file-name-as-directory (file-truename (make-temp-file "etm-cwd" t))))
           (out (expand-file-name "cwd.txt" dir)))
      (etm-test-data "pane.new" :key "cwd" :kind "cmd" :path dir :cmd "pwd > cwd.txt")
      (etm-test-data "wait" :addr "cwd" :until "exit" :timeout 5)
      (should (equal (string-trim (with-temp-buffer (insert-file-contents out) (buffer-string)))
                     (directory-file-name dir))))))

(ert-deftest etm-wait-exit-reports-status ()
  (etm-test-with-clean
    (etm-test-data "pane.new" :key "job" :kind "cmd" :cmd "echo done; exit 4")
    (let ((done (etm-test-data "wait" :addr "job" :until "exit" :timeout 5)))
      (should (= 4 (plist-get done :exit_status))))
    (should (equal (etm-test-error-code (etm-test-call "wait" :addr "job" :until "soon"))
                   "usage.bad_arg"))))

(ert-deftest etm-wait-polls-are-quiet-until-they-decide ()
  (etm-test-with-clean
    (etm-test-data "pane.new" :key "cat" :kind "cmd" :cmd "cat")
    (let ((poll (etm-test-call "wait" :addr "cat" :until "match:zzz" :timeout 0 :poll t)))
      (should (equal (etm-test-error-code poll) "wait.timeout"))
      (should (eq (plist-get (car (plist-get poll :errors)) :retryable) t))
      (should (plist-get (plist-get poll :data) :cursor))
      (should (null (plist-get poll :events))))
    (let ((last (etm-test-call "wait" :addr "cat" :until "match:zzz" :timeout 0
                                :poll t :final t)))
      (should (plist-get last :events)))
    (let ((idle (etm-test-call "wait" :addr "cat" :until "idle" :idle_ms 0 :timeout 0 :poll t)))
      (should (eq (plist-get idle :ok) t))
      (should (plist-get idle :events)))))

(provide 'test-etm-pane)
;;; test-etm-pane.el ends here

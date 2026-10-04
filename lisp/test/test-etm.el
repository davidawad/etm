;;; test-etm.el --- etm: verb table, envelope, workspaces, trail, extension points -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The dispatcher half of etm: the closed verb table, the envelope,
;; base64 framing, the workspace verbs over a persp-mode stand-in, the
;; event every call leaves, doctor, the eval escape hatch, and every
;; extension point replaced by a configuration's own function.  Pane
;; verbs live in test-etm-pane.el, pages in test-etm-page.el, the real
;; workspace backends in test-etm-backend.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "etm-test-support.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

;;;; The closed table

(ert-deftest etm-verb-table-is-the-closed-vocabulary ()
  (should (equal (mapcar #'car etm-verbs)
                 '("snapshot" "capabilities" "ws.ls" "ws.get" "ws.new" "ws.switch"
                   "ws.rename" "ws.kill" "pane.ls" "pane.new" "pane.kill" "pane.focus"
                   "send" "capture" "wait" "doctor" "events" "eval")))
  (dolist (entry etm-verbs)
    (should (fboundp (nth 1 entry)))
    (should (memq (nth 2 entry) '(read write)))))

(ert-deftest etm-unknown-verb-is-a-usage-error-never-an-eval ()
  (etm-test-with-clean
    (let ((env (etm-test-call "(kill-emacs)")))
      (should (eq (plist-get env :ok) :false))
      (should (equal (etm-test-error-code env) "usage.unknown_verb"))
      (should (equal (plist-get (car (plist-get env :errors)) :hint) "etm capabilities")))))

(ert-deftest etm-envelope-has-every-w7-field ()
  (etm-test-with-clean
    (let ((env (etm-test-call "capabilities")))
      (should (equal (plist-get env :schema) "etm.result/1"))
      (should (eq (plist-get env :ok) t))
      (should (equal (plist-get env :verb) "capabilities"))
      (dolist (k '(:warnings :errors :next))
        (should (null (plist-get env k))))
      (should (string-prefix-p "ev_" (car (plist-get env :events))))
      (should (numberp (plist-get env :elapsed_ms))))))

(ert-deftest etm-bad-request-and-protocol ()
  (etm-test-with-clean
    (should (equal (etm-test-error-code
                    (json-parse-string (etm-rpc-json "{not json")
                                       :object-type 'plist :array-type 'list))
                   "usage.bad_request"))
    (let ((env (json-parse-string (etm-rpc-json "{\"v\":9,\"verb\":\"ws.ls\"}")
                                  :object-type 'plist :array-type 'list)))
      (should (equal (etm-test-error-code env) "usage.protocol")))))

(ert-deftest etm-base64-entry-round-trips-utf8 ()
  "The socket path: base64 UTF-8 JSON in, base64 UTF-8 JSON out."
  (etm-test-with-clean
    (let* ((req (encode-coding-string
                 "{\"v\":1,\"verb\":\"eval\",\"args\":{\"form\":\"(concat \\\"h\\u00e9llo \\\" \\\"\\u2713\\\")\"}}"
                 'utf-8))
           (out (etm-rpc (base64-encode-string req t)))
           (env (json-parse-string (decode-coding-string (base64-decode-string out) 'utf-8)
                                   :object-type 'plist)))
      (should-not (string-match-p "[^A-Za-z0-9+/=]" out))
      (should (equal (plist-get (plist-get env :data) :value) "\"héllo ✓\"")))
    (let ((env (json-parse-string
                (decode-coding-string (base64-decode-string (etm-rpc "!!not-base64")) 'utf-8)
                :object-type 'plist :array-type 'list)))
      (should (equal (etm-test-error-code env) "usage.bad_request")))))

(ert-deftest etm-handler-bug-is-an-envelope-not-a-signal ()
  (etm-test-with-clean
    (cl-letf (((symbol-function 'etm--v-ws-ls) (lambda (_) (error "boom"))))
      (let ((env (etm-test-call "ws.ls")))
        (should (equal (etm-test-error-code env) "internal.error"))
        (should (equal (plist-get (car (plist-get env :errors)) :msg) "boom"))))))

;;;; Addresses and cursors

(ert-deftest etm-addresses-split-on-the-last-slash ()
  (should (equal (etm-parse-addr "client:datics/pm") '("client:datics" . "pm")))
  (should (equal (etm-parse-addr "a/b/eng.2") '("a/b" . "eng.2")))
  (should (equal (etm-parse-addr "pm") '(nil . "pm")))
  (should-error (etm-parse-addr "ws/") :type 'etm-error)
  (should-error (etm-parse-addr "ws/a b") :type 'etm-error))

(ert-deftest etm-cursor-format-round-trips ()
  (should (equal (etm-cursor-parse (etm-cursor-format "ab12" 40)) '("ab12" . 40)))
  (should-error (etm-cursor-parse "c2:x:1") :type 'etm-error))

;;;; Workspaces (over a persp-mode stand-in)

(ert-deftest etm-ws-single-backend-is-one-global-workspace ()
  (etm-test-with-clean
    (should (equal (mapcar (lambda (w) (plist-get w :id)) (etm-test-data "ws.ls"))
                   '("global")))
    (dolist (verb '("ws.new" "ws.switch" "ws.rename" "ws.kill"))
      (let ((env (etm-test-call verb :ws "global" :name "x")))
        (should (equal (etm-test-error-code env) "capability.unavailable"))))))

(ert-deftest etm-ws-auto-backend-follows-what-is-on ()
  (etm-test-with-clean
    (let ((etm-workspace-backend 'auto))
      (should (eq (etm-backend) 'single))
      (etm-test-with-persps '("main")
        (let ((etm-workspace-backend 'auto))
          (should (eq (etm-backend) 'persp-mode)))))
    (let ((etm-workspace-backend 'persp-mode))
      (should (equal (etm-test-error-code (etm-test-call "ws.new" :ws "x"))
                     "capability.unavailable")))))

(ert-deftest etm-ws-new-tags-and-is-idempotent ()
  (etm-test-with-clean
    (etm-test-with-persps '("main")
      (let ((made (etm-test-data "ws.new" :ws "client:x" :subject "client:x")))
        (should (eq (plist-get made :created) t))
        (should (eq (plist-get made :managed) t))
        (should (equal (plist-get made :subject) "client:x"))
        (should (equal (plist-get made :tag) "client:x"))
        (should (null (plist-get made :owner)))
        (should (= 32 (length (plist-get made :id))))
        (let ((again (etm-test-data "ws.new" :ws "client:x")))
          (should (eq (plist-get again :created) :false))
          (should (equal (plist-get again :id) (plist-get made :id))))
        ;; A controller's tags: spec re-tags an existing persp; the owner stays the creator.
        (let ((tagged (etm-test-data "ws.new" :ws "client:x" :spec "b3:1" :owner "a")))
          (should (equal (plist-get tagged :spec) "b3:1"))
          (should (equal (plist-get tagged :owner) "a")))
        (let ((retag (etm-test-data "ws.new" :ws "client:x" :spec "b3:2" :owner "b")))
          (should (equal (plist-get retag :spec) "b3:2"))
          (should (equal (plist-get retag :owner) "a"))))
      (should (equal (mapcar (lambda (w) (plist-get w :name)) (etm-test-data "ws.ls"))
                     '("none" "main" "client:x")))
      (should (equal (etm-test-error-code (etm-test-call "ws.new" :ws "a/b"))
                     "usage.bad_arg")))))

(ert-deftest etm-ws-rename-keeps-identity ()
  (etm-test-with-clean
    (etm-test-with-persps '("main" "old")
      (let* ((id (plist-get (etm-test-data "ws.get" :ws "old") :id))
             (renamed (etm-test-data "ws.rename" :ws "old" :name "new")))
        (should (equal (plist-get renamed :id) id))
        (should (equal (plist-get renamed :old_name) "old"))
        (should (equal (plist-get (etm-test-data "ws.get" :ws id) :name) "new"))
        (should (equal (etm-test-error-code (etm-test-call "ws.get" :ws "old"))
                       "not_found.workspace"))))))

(ert-deftest etm-ws-new-adopt-renames-and-tags-an-untagged-persp ()
  (etm-test-with-clean
    (etm-test-with-persps '("main" "hand")
      (let* ((id (plist-get (etm-test-data "ws.get" :ws "hand") :id))
             (made (etm-test-data "ws.new" :ws "client:x" :subject "client:x"
                                   :owner "me" :adopt "hand")))
        (should (equal (plist-get made :id) id))
        (should (equal (plist-get made :name) "client:x"))
        (should (equal (plist-get made :tag) "client:x"))
        (should (equal (plist-get made :owner) "me"))
        (should (eq (plist-get made :created) :false))
        ;; Re-adopting under the same name is idempotent.
        (should (equal (plist-get (etm-test-data "ws.new" :ws "client:x" :adopt "client:x") :id)
                       id))
        ;; Tagged for another workspace, or taking a name in use: refused.
        (should (equal (etm-test-error-code
                        (etm-test-call "ws.new" :ws "client:y" :adopt "client:x"))
                       "conflict.already_managed"))
        (should (equal (etm-test-error-code
                        (etm-test-call "ws.new" :ws "client:x" :adopt "main"))
                       "conflict.exists"))
        (should (equal (etm-test-error-code
                        (etm-test-call "ws.new" :ws "client:z" :adopt "none"))
                       "usage.bad_target"))))))

(ert-deftest etm-ws-switch-and-kill ()
  (etm-test-with-clean
    (etm-test-with-persps '("main" "b")
      (should (eq (plist-get (etm-test-data "ws.switch" :ws "b") :current) t))
      (should (equal (plist-get (etm-test-data "ws.get") :name) "b"))
      (should (eq (plist-get (etm-test-data "ws.kill" :ws "main") :killed) t))
      (should-not (member "main" (mapcar (lambda (w) (plist-get w :name))
                                         (etm-test-data "ws.ls"))))
      (should (equal (etm-test-error-code (etm-test-call "ws.kill" :ws "none"))
                     "usage.bad_target")))))

;;;; Trail, doctor, eval

(ert-deftest etm-every-call-cites-its-event ()
  (etm-test-with-clean
    (let* ((env (etm-test-call "ws.ls"))
           (id (car (plist-get env :events)))
           (event (etm-test-last-event)))
      (should (equal (plist-get event :id) id))
      (should (eq (plist-get event :subsystem) 'etm))
      (should (eq (plist-get event :level) 'debug))
      (should (string-prefix-p "ws.ls ok" (plist-get event :message))))
    (etm-test-call "nope")
    (should (eq (plist-get (etm-test-last-event) :level) 'info))))

(ert-deftest etm-event-messages-name-the-call-target ()
  (etm-test-with-clean
    (etm-test-call "ws.kill" :ws "client:none")
    (should (string-prefix-p "ws.kill client:none error "
                             (plist-get (etm-test-last-event) :message)))
    (etm-test-call "capture" :addr "client:none/sh")
    (should (string-prefix-p "capture client:none/sh error "
                             (plist-get (etm-test-last-event) :message)))))

(ert-deftest etm-events-since-is-exclusive-and-limited ()
  (etm-test-with-clean
    (let ((mark (car (plist-get (etm-test-call "ws.ls") :events))))
      (etm-test-call "capabilities")
      (etm-test-call "capabilities")
      (let ((data (etm-test-data "events" :since mark :limit 1)))
        (should (= 1 (length (plist-get data :events))))
        (should (= 1 (plist-get data :dropped)))
        (should (string-prefix-p "capabilities ok"
                                 (plist-get (car (plist-get data :events)) :message)))
        (should (equal (plist-get data :next_since)
                       (plist-get (car (plist-get data :events)) :id)))))))

(ert-deftest etm-doctor-flags-a-pane-outside-the-registry ()
  (etm-test-with-clean
    (should (eq (plist-get (etm-test-data "doctor") :healthy) t))
    (etm-test-data "pane.new" :key "notes" :kind "editor"
                    :path (make-temp-file "etm-doc"))
    (clrhash etm--resources)
    (let* ((env (etm-test-call "doctor"))
           (row (cl-find "etm.panes-registered" (plist-get (plist-get env :data) :rows)
                         :key (lambda (r) (plist-get r :check)) :test #'equal)))
      (should (equal (plist-get row :status) "fail"))
      (should (eq (plist-get (plist-get env :data) :healthy) :false))
      (should (equal (plist-get (car (plist-get env :warnings)) :code)
                     "doctor.etm.panes-registered")))))

(ert-deftest etm-eval-is-logged-flagged-and-switchable ()
  (etm-test-with-clean
    (let ((env (etm-test-call "eval" :form "(+ 40 2)")))
      (should (equal (plist-get (plist-get env :data) :value) "42"))
      (should (equal (plist-get (car (plist-get env :warnings)) :code) "eval.escape_hatch"))
      (should (null (plist-get env :next)))
      (should (cl-some (lambda (e) (string-prefix-p "eval escape hatch: (+ 40 2)"
                                                     (plist-get e :message)))
                       (last (etm-event-list) 3))))
    (let ((etm-allow-eval nil))
      (should (equal (etm-test-error-code (etm-test-call "eval" :form "1"))
                     "capability.disabled")))))

(ert-deftest etm-snapshot-fields-and-rev ()
  (etm-test-with-clean
    (let* ((env (etm-test-call "snapshot" :fields ["current" "panes"]))
           (data (plist-get env :data)))
      (should (equal (cl-loop for (k _v) on data by #'cddr collect k) '(:current :panes)))
      (should (string-prefix-p "sha1:" (plist-get env :rev))))
    (let ((full (etm-test-data "snapshot")))
      (dolist (k '(:emacs :workspaces :panes :windows :namespace :events))
        (should (plist-member full k))))))

;;;; Extension points

(ert-deftest etm-resolver-replaces-pane-identity ()
  "A configuration's resolver owns identity; etm's registry stays empty."
  (etm-test-with-clean
    (let* ((rows (make-hash-table :test #'equal))
           (etm-resource-resolver
            (list :peek (lambda (key ws) (gethash (cons (etm-ws-id ws) key) rows))
                  :get (lambda (key create ws)
                         (or (gethash (cons (etm-ws-id ws) key) rows)
                             (puthash (cons (etm-ws-id ws) key) (funcall create) rows)))
                  :buffer-id (lambda (_b) "feed")
                  :owned (lambda (_ws) (hash-table-values rows))
                  :registered-p (lambda (b) (memq b (hash-table-values rows)))
                  :snapshot (lambda () (list :rows (hash-table-count rows))))))
      (let ((made (etm-test-data "pane.new" :key "sh" :kind "cmd" :cmd "cat")))
        (should (equal (plist-get made :buffer_id) "feed"))
        (should (equal (plist-get made :cursor) "c1:feed:1")))
      (should (= 1 (hash-table-count rows)))
      (should (= 0 (hash-table-count etm--resources)))
      (should (equal (plist-get (etm-test-data "snapshot") :namespace) '(:rows 1)))
      (should (equal (mapcar (lambda (p) (plist-get p :key)) (etm-test-data "pane.ls"))
                     '("sh"))))))

(ert-deftest etm-dock-function-places-side-regions ()
  (etm-test-with-clean
    (let* (calls
           (etm-layout-dock-function
            (lambda (buf region)
              (push region calls)
              (display-buffer buf '(display-buffer-use-some-window)))))
      (etm-test-data "pane.new" :key "r" :kind "shell" :region "right")
      (should (equal calls '(right)))
      (let ((env (etm-test-call "pane.new" :key "t" :kind "shell" :region "top")))
        (should (equal (plist-get (car (plist-get env :warnings)) :code)
                       "degraded.region_top"))
        (should (equal calls '(bottom right))))
      (etm-test-data "pane.new" :key "m" :kind "shell" :region "main")
      (should (= 2 (length calls))))))

(ert-deftest etm-default-dock-is-a-side-window ()
  (etm-test-with-clean
    (let* ((made (etm-test-data "pane.new" :key "log" :kind "cmd" :cmd "cat"
                                :region "left"))
           (win (get-buffer-window (etm-test-pane-buffer "global/log"))))
      (should (eq (plist-get made :visible) t))
      (should (eq (window-parameter win 'window-side) 'left))
      (should (equal (window-parameter win 'etm-pane) "log")))))

(ert-deftest etm-event-store-and-sinks-are-replaceable ()
  (etm-test-with-clean
    (let* (store seen
           (etm-event-log-function
            (lambda (level msg)
              (car (push (list :id (format "x%d" (length store)) :ts (float-time)
                               :level level :message msg)
                         store))))
           (etm-event-list-function (lambda () (reverse store)))
           (etm-event-functions (list (lambda (e) (push (plist-get e :id) seen)))))
      (let ((env (etm-test-call "ws.ls")))
        (should (equal (plist-get env :events) '("x0")))
        (should (equal seen '("x0")))
        (should (string-prefix-p "ws.ls ok" (plist-get (car store) :message))))
      (should (equal (mapcar (lambda (e) (plist-get e :id))
                             (plist-get (etm-test-data "events") :events))
                     '("x0")))
      (should (null (etm-event-ring-list))))))

(ert-deftest etm-doctor-and-snapshot-take-extra-rows-and-sections ()
  (etm-test-with-clean
    (let ((etm-doctor-functions
           (list (lambda () (list (list :check "mine.ok" :status 'pass :hint "fine")
                                  (list :check "mine.bad" :status 'fail :hint "broken")))
                 (lambda () (error "Doctor row crashed"))))
          (etm-snapshot-functions
           (list (lambda () (list :mine 42 :current "not this")))))
      (let* ((env (etm-test-call "doctor"))
             (rows (plist-get (plist-get env :data) :rows)))
        (should (equal (plist-get (cl-find "mine.ok" rows :key (lambda (r) (plist-get r :check))
                                           :test #'equal)
                                  :status)
                       "pass"))
        (should (eq (plist-get (plist-get env :data) :healthy) :false))
        (should (member "doctor.mine.bad"
                        (mapcar (lambda (w) (plist-get w :code)) (plist-get env :warnings))))
        (should (cl-find "Doctor row crashed" rows
                         :key (lambda (r) (plist-get r :hint)) :test #'equal)))
      (let ((snap (etm-test-data "snapshot")))
        (should (equal (plist-get snap :mine) 42))
        (should (equal (plist-get snap :current) "global"))))))

(ert-deftest etm-tag-parameters-name-the-stored-tags ()
  (etm-test-with-clean
    (etm-test-with-persps '("main")
      (let ((etm-tag-parameters '((tag . my-ws) (subject . my-subject) (spec . my-spec)
                                  (owner . my-owner) (root . root))))
        (etm-test-data "ws.new" :ws "w" :subject "s" :owner "o" :spec "r")
        (let ((p (car (last etm-test--persps))))
          (should (equal (alist-get 'my-ws (etm-test-persp-params p)) "w"))
          (should (equal (alist-get 'my-subject (etm-test-persp-params p)) "s"))
          (should (equal (alist-get 'my-owner (etm-test-persp-params p)) "o"))
          (should (equal (alist-get 'my-spec (etm-test-persp-params p)) "r"))
          (should-not (alist-get 'etm-ws (etm-test-persp-params p))))
        (should (equal (plist-get (etm-test-data "ws.get" :ws "w") :tag) "w"))))))

(ert-deftest etm-persp-id-parameter-is-shared ()
  (etm-test-with-clean
    (etm-test-with-persps '("main")
      (setf (alist-get 'their-id (etm-test-persp-params (car etm-test--persps))) "abc")
      (let ((etm-persp-id-parameter 'their-id))
        (should (equal (plist-get (etm-test-data "ws.get" :ws "main") :id) "abc"))))))

(provide 'test-etm)
;;; test-etm.el ends here

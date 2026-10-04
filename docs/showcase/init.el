;;; init.el --- plain emacs -Q setup for the etm screenshots  -*- lexical-binding: t -*-

;; Loaded with `emacs -Q -l init.el' by make-screenshots.sh.  Nothing here is
;; personal configuration: a dark built-in theme, one font, the etm package,
;; the workspace backend under test, and a demo page type.  Environment:
;;   ETM_SHOWCASE_LISP     etm's lisp/ directory
;;   ETM_SHOWCASE_ELPA     throwaway package dir holding persp-mode, tabspaces, eat
;;   ETM_SHOWCASE_BACKEND  persp-mode | tab-bar | tabspaces | single
;;   ETM_SHOWCASE_SOCKET   absolute path of the server socket
;;   ETM_SHOWCASE_INFO     directory holding the built etm.info (optional)

;;; Code:

(require 'cl-lib)

(setq native-comp-jit-compilation nil
      native-comp-deferred-compilation nil
      inhibit-startup-screen t
      initial-scratch-message nil
      ring-bell-function #'ignore
      make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      use-short-answers t
      frame-title-format "etm"
      confirm-kill-processes nil)

;; A big, readable, dark frame.
(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode -1)
(blink-cursor-mode -1)
(setq-default cursor-in-non-selected-windows nil)
(load-theme 'modus-vivendi t)
(set-face-attribute 'default nil
                    :family (if (find-font (font-spec :family "JetBrains Mono"))
                                "JetBrains Mono"
                              "DejaVu Sans Mono")
                    :height 130)
(add-to-list 'load-path (getenv "ETM_SHOWCASE_LISP"))
(when-let* ((elpa (getenv "ETM_SHOWCASE_ELPA")))
  (setq package-user-dir elpa
        package-enable-at-startup nil)
  (package-initialize))
(require 'etm)
(require 'eat nil t)

(defvar showcase-backend (or (getenv "ETM_SHOWCASE_BACKEND") "tab-bar"))

;; The workspace backend under test, and nothing else.
(pcase showcase-backend
  ("persp-mode"
   (setq persp-auto-resume-time -1 persp-auto-save-opt 0
         persp-nil-name "main")
   (require 'persp-mode)
   (persp-mode 1))
  ("tabspaces"
   (require 'tabspaces)
   (setq tabspaces-use-filtered-buffers-as-default t
         tabspaces-default-tab "main"
         tabspaces-remove-to-default nil
         tabspaces-include-buffers '("*scratch*"))
   (tab-bar-mode 1)
   (tabspaces-mode 1))
  ("tab-bar"
   (tab-bar-mode 1)
   (tab-bar-rename-tab "main"))
  ("single" nil))
(setq etm-workspace-backend (intern showcase-backend)
      dired-listing-switches "-ogh")
(setq tab-bar-new-tab-choice "*scratch*")

;; The backend and the current workspace in every mode line, so a frame shows
;; which workspace it is without leaning on any backend's own UI.
(defun showcase-ws-label ()
  "Mode line text: the etm backend and the current workspace."
  (condition-case nil
      (let ((b (etm-backend)))
        (propertize (format " [%s: %s] " b (etm-backend-name b (etm-backend-current b)))
                    'face 'bold))
    (error "")))
(add-to-list 'mode-line-misc-info '(:eval (showcase-ws-label)))

;; A demo page type: a small dashboard of synthetic numbers.
(defun showcase-dashboard ()
  "Show a synthetic build dashboard."
  (let ((buf (get-buffer-create "*Demo Dashboard*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Build dashboard\n" 'face '(:height 1.4 :weight bold))
                (propertize "demo data\n\n" 'face 'shadow))
        (dolist (row '(("api" "passing" 128 "2m14s")
                       ("web" "passing" 342 "3m51s")
                       ("worker" "failing" 87 "1m02s")
                       ("docs" "passing" 12 "0m18s")))
          (insert (format "  %-8s " (nth 0 row))
                  (propertize (format "%-8s" (nth 1 row))
                              'face (if (equal (nth 1 row) "passing")
                                        'success 'error))
                  (format " %4d tests\n" (nth 2 row))))
        (insert "\n" (propertize "Queue\n" 'face 'bold)
                "  3 jobs waiting, 2 running\n"))
      (special-mode))
    (pop-to-buffer-same-window buf)))
(add-hook 'dired-mode-hook (lambda () (setq truncate-lines nil)))
(add-to-list 'etm-page-types '("dashboard" . showcase-dashboard))

;; Info: make the etm manual findable with C-h i.
(when-let* ((dir (getenv "ETM_SHOWCASE_INFO")))
  (require 'info)
  (add-to-list 'Info-additional-directory-list dir))

;; Screenshots: the frame as a PNG, via cairo.
(defun showcase-shot (file)
  "Write the selected frame to FILE as a PNG."
  (message nil)
  (force-window-update t)
  (redisplay t)
  (let ((coding-system-for-write 'no-conversion))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert (x-export-frames (selected-frame) 'png))))
  file)

(defun showcase-reset-windows ()
  "One window on *scratch*, no side windows."
  (ignore-errors (window-toggle-side-windows))
  (delete-other-windows)
  (switch-to-buffer "*scratch*"))

;; The exported PNG is the whole frame (tab bar and borders included), 1400x900.
(set-frame-size nil 1400 900 t)
(set-frame-size nil
                (- 1400 (- (frame-outer-width) (frame-text-width)))
                (- 900 (- (frame-outer-height) (frame-text-height))) t)

(when-let* ((sock (getenv "ETM_SHOWCASE_SOCKET")))
  (setq server-name sock))
(server-start)
;;; init.el ends here

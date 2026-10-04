;;; etm-ext.el --- Extension points: identity, layout, events, doctor -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; URL: https://github.com/davidawad/etm
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Everything a configuration may want to replace, each with a default
;; that works in a bare `emacs -Q':
;;
;; - Buffer identity (`etm-resource-resolver').  A pane is the buffer
;;   registered under a resource key in its workspace's row; buffer
;;   names are labels, never identity.  The default is a registry kept
;;   here (workspace id x key -> buffer); a configuration with its own
;;   buffer namespace hands etm its functions instead.
;; - Docking (`etm-layout-dock-function'): how a pane takes a side
;;   region.  Default: a side window.
;; - Events (`etm-event-log-function', `etm-event-list-function',
;;   `etm-event-functions'): every call leaves one event, whose id the
;;   envelope cites.  Default: a ring kept here.  Sinks see every event.
;; - Doctor rows (`etm-doctor-functions') and snapshot sections
;;   (`etm-snapshot-functions').
;; - Tag names (`etm-tag-parameters'): which workspace parameters hold
;;   the tags a controller mounts a workspace with.
;;
;; Page types are registered in etm-page.el (`etm-page-types').

;;; Code:

(require 'cl-lib)
(require 'ring)
(require 'etm-base)
(require 'etm-backend)

;;;; Tags

(defcustom etm-tag-parameters
  '((tag . etm-ws) (subject . etm-subject) (spec . etm-spec)
    (owner . etm-owner) (root . root))
  "Workspace parameters holding each tag, an alist (TAG . PARAMETER).
TAG is one of `tag' (the name a controller mounted the workspace
under), `subject', `spec' (the revision it was rendered from), `owner'
\(the creating session) and `root' (its directory).  Point them at
other parameter names to share tags with an existing setup."
  :type '(alist :key-type symbol :value-type symbol)
  :group 'etm)

(defun etm-tag-parameter (tag)
  "Return the workspace parameter for TAG."
  (or (alist-get tag etm-tag-parameters)
      (intern (format "etm-%s" tag))))

;;;; Buffer identity

(defcustom etm-resource-resolver nil
  "Functions that resolve pane identity, a plist; nil uses etm's own.
Each key may name a function replacing etm's default for that step:

  :peek      (KEY WS)        the live buffer registered as KEY in WS, or nil
  :get       (KEY CREATE WS) that buffer, registering (CREATE) when absent
  :replace   (OLD NEW)       register NEW in OLD's row; return NEW
  :buffer-id (BUFFER)        a stable id of BUFFER as an object
  :owned     (WS)            live buffers owned by WS
  :registered-p (BUFFER)     non-nil when BUFFER is registered anywhere
  :snapshot  ()              a plist describing the whole registry

KEY is a symbol, WS an `etm-ws' (its handle is the backend's
workspace object) and CREATE a function of no arguments returning a
fresh buffer."
  :type '(plist :key-type symbol :value-type function)
  :group 'etm)

(defvar etm--resources (make-hash-table :test #'equal :weakness 'value)
  "The default resource registry: (WORKSPACE-ID . KEY) -> buffer.")

(defvar-local etm--owner nil
  "Id of the workspace whose registry row holds this buffer.")
(put 'etm--owner 'permanent-local t)

(defvar-local etm--buffer-id nil
  "Stable id of this buffer object, assigned on first ask.")
(put 'etm--buffer-id 'permanent-local t)

(defun etm--resolver (op default)
  "The function for resolver step OP, else DEFAULT."
  (or (plist-get etm-resource-resolver op) default))

(defun etm-resource-default-peek (key ws)
  "The live buffer etm registered as KEY in WS, or nil."
  (let ((buf (gethash (cons (etm-ws-id ws) key) etm--resources)))
    (and (buffer-live-p buf) buf)))

(defun etm-resource-default-get (key create ws)
  "KEY's buffer in WS, created by CREATE and registered when absent."
  (or (etm-resource-default-peek key ws)
      (let ((buf (funcall create)))
        (unless (buffer-live-p buf)
          (error "Etm: creating %s returned no live buffer" key))
        (with-current-buffer buf (setq etm--owner (etm-ws-id ws)))
        (puthash (cons (etm-ws-id ws) key) buf etm--resources)
        buf)))

(defun etm-resource-default-row (buffer)
  "The (WORKSPACE-ID . KEY) row BUFFER is registered under, or nil."
  (catch 'found
    (maphash (lambda (k v) (when (eq v buffer) (throw 'found k))) etm--resources)
    nil))

(defun etm-resource-default-replace (old new)
  "Register NEW in OLD's row; return NEW."
  (let ((row (or (etm-resource-default-row old)
                 (error "Etm: %s is not registered" old))))
    (with-current-buffer new (setq etm--owner (car row)))
    (puthash row new etm--resources)
    new))

(defun etm-resource-default-buffer-id (buffer)
  "Stable id of BUFFER as an object."
  (with-current-buffer buffer
    (or etm--buffer-id (setq etm--buffer-id (etm-new-id)))))

(defun etm-resource-default-owned (ws)
  "Live buffers whose registry row belongs to WS."
  (let ((id (etm-ws-id ws)))
    (cl-remove-if-not (lambda (b) (equal (buffer-local-value 'etm--owner b) id))
                      (buffer-list))))

(defun etm-resource-default-snapshot ()
  "Every live registry row."
  (let (rows)
    (maphash (lambda (k v)
               (when (buffer-live-p v)
                 (push (list :ws (car k) :key (symbol-name (cdr k))
                             :buffer (buffer-name v))
                       rows)))
             etm--resources)
    (list :resources (nreverse rows))))

(defun etm-resource-peek (key ws)
  "The live buffer registered as KEY in workspace WS, or nil."
  (funcall (etm--resolver :peek #'etm-resource-default-peek) key ws))

(defun etm-resource-get (key create ws)
  "KEY's buffer in workspace WS, made by CREATE when absent."
  (funcall (etm--resolver :get #'etm-resource-default-get) key create ws))

(defun etm-resource-replace (old new)
  "Register buffer NEW in the row of buffer OLD; return NEW."
  (funcall (etm--resolver :replace #'etm-resource-default-replace) old new))

(defun etm-resource-buffer-id (buffer)
  "A stable id of BUFFER as an object (capture cursors key on it)."
  (funcall (etm--resolver :buffer-id #'etm-resource-default-buffer-id) buffer))

(defun etm-resource-owned (ws)
  "Live buffers owned by workspace WS."
  (funcall (etm--resolver :owned #'etm-resource-default-owned) ws))

(defun etm-resource-registered-p (buffer)
  "Non-nil when BUFFER is registered in the resolver."
  (funcall (etm--resolver :registered-p
                          (lambda (b) (and (etm-resource-default-row b) t)))
           buffer))

(defun etm-resource-snapshot ()
  "A plist describing the resolver's registry."
  (funcall (etm--resolver :snapshot #'etm-resource-default-snapshot)))

;;;; Docking

(defcustom etm-layout-dock-function #'etm-layout-dock-side-window
  "Function that shows a pane buffer in a side region.
Called with BUFFER and REGION (one of the symbols `left', `right',
`bottom'); returns the window it used, or nil."
  :type 'function
  :group 'etm)

(defcustom etm-side-window-size 0.3
  "Width or height of a docked pane's side window, as a frame fraction."
  :type 'number
  :group 'etm)

(defun etm-layout-dock-side-window (buffer region)
  "Show BUFFER in a side window at REGION (`left', `right' or `bottom')."
  (display-buffer-in-side-window
   buffer
   `((side . ,region) (slot . 0)
     (,(if (eq region 'bottom) 'window-height 'window-width)
      . ,etm-side-window-size))))

;;;; Events

(defcustom etm-event-ring-size 200
  "Events etm's own ring keeps (see `etm-event-log-function')."
  :type 'integer
  :group 'etm)

(defcustom etm-event-log-function #'etm-event-ring-log
  "Function that records one event and returns it as a plist.
Called with LEVEL (`debug', `info', `warn' or `error') and MESSAGE.
The plist has at least :id (a string sorting by time), :ts (float
seconds), :level and :message."
  :type 'function
  :group 'etm)

(defcustom etm-event-list-function #'etm-event-ring-list
  "Function of no arguments returning every retained event, oldest first."
  :type 'function
  :group 'etm)

(defcustom etm-event-functions nil
  "Sinks called with every event plist after it is recorded."
  :type 'hook
  :group 'etm)

(defvar etm--event-ring nil "The default event ring, made on first use.")
(defvar etm--event-counter 0 "Events logged this session; feeds ids.")

(defun etm-event-ring-log (level message)
  "Record an event of LEVEL with MESSAGE in etm's ring; return it."
  (unless (and etm--event-ring (= (ring-size etm--event-ring) etm-event-ring-size))
    (setq etm--event-ring (make-ring etm-event-ring-size)))
  (let* ((ts (float-time))
         (event (list :id (format "ev_%x%04x" (floor (* ts 1000))
                                  (% (cl-incf etm--event-counter) #x10000))
                      :ts ts :subsystem 'etm :level level :message message)))
    (ring-insert etm--event-ring event)
    event))

(defun etm-event-ring-list ()
  "Every event in etm's ring, oldest first."
  (and etm--event-ring (reverse (ring-elements etm--event-ring))))

(defun etm-event-log (level format-string &rest args)
  "Record one event at LEVEL, its message from FORMAT-STRING and ARGS.
Returns the event plist; sinks in `etm-event-functions' see it too."
  (let ((event (funcall etm-event-log-function level
                        (apply #'format format-string args))))
    (run-hook-with-args 'etm-event-functions event)
    event))

(defun etm-event-list ()
  "Every retained event, oldest first."
  (funcall etm-event-list-function))

;;;; Doctor rows and snapshot sections

(defcustom etm-doctor-functions nil
  "Functions adding rows to `etm doctor'.
Each is called with no arguments and returns a list of rows, each a
plist (:check NAME :status STATUS :hint TEXT) where STATUS is `pass',
`fail' or `skip' (a symbol or string).  A failing row is a warning on
the envelope and makes the doctor unhealthy."
  :type 'hook
  :group 'etm)

(defcustom etm-snapshot-functions nil
  "Functions adding sections to `etm snapshot'.
Each is called with no arguments and returns a plist merged into the
snapshot (a key etm already uses is left as etm has it)."
  :type 'hook
  :group 'etm)

(provide 'etm-ext)
;;; etm-ext.el ends here

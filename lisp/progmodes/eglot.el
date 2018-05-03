;;; eglot.el --- A client for Language Server Protocol (LSP) servers  -*- lexical-binding: t; -*-

;; Copyright (C) 2017  João Távora

;; Author: João Távora
;; Keywords: extensions

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'project)
(require 'url-parse)
(require 'url-util)
(require 'pcase)
(require 'compile) ; for some faces
(require 'warnings)
(require 'flymake)


;;; User tweakable stuff
(defgroup eglot nil
  "Interaction with Language Server Protocol servers"
  :prefix "eglot-"
  :group 'applications)

(defvar eglot-executables '((rust-mode . ("rls"))
                            (python-mode . ("pyls")))
  "Alist mapping major modes to server executables.")

(defface eglot-mode-line
  '((t (:inherit font-lock-constant-face :weight bold)))
  "Face for package-name in EGLOT's mode line."
  :group 'eglot)


;;; Process management
(defvar eglot--processes-by-project (make-hash-table :test #'equal)
  "Keys are projects.  Values are lists of processes.")

(defvar-local eglot--special-buffer-process nil
  "Current buffer's eglot process.")

(defun eglot--current-process ()
  "The current logical EGLOT process."
  (or eglot--special-buffer-process
      (let* ((cur (project-current))
             (processes
              (and cur
                   (gethash cur eglot--processes-by-project))))
        (cl-find major-mode
                 processes
                 :key #'eglot--major-mode))))

(defun eglot--current-process-or-lose ()
  "Return the current EGLOT process or error."
  (or (eglot--current-process)
      (eglot--error "No current EGLOT process%s"
                    (if (project-current) ""
                      " (Also no current project)"))))

(defmacro eglot--define-process-var
    (var-sym initval &optional doc mode-line-update-p)
  "Define VAR-SYM as a generalized process-local variable.
INITVAL is the default value.  DOC is the documentation.
MODE-LINE-UPDATE-P says to also force a mode line update
after setting it."
  (declare (indent 2))
  `(progn
     (put ',var-sym 'function-documentation ,doc)
     (defun ,var-sym (proc)
       (let* ((plist (process-plist proc))
              (probe (plist-member plist ',var-sym)))
         (if probe
             (cadr probe)
           (let ((def ,initval))
             (process-put proc ',var-sym def)
             def))))
     (gv-define-setter ,var-sym (to-store &optional process)
       (let* ((prop ',var-sym))
         ,(let ((form '(let ((proc (or ,process (eglot--current-process-or-lose))))
                         (process-put proc ',prop ,to-store))))
            (if mode-line-update-p
                `(backquote (prog1 ,form (force-mode-line-update t)))
              `(backquote ,form)))))))

(eglot--define-process-var eglot--short-name nil
  "A short name for the process" t)

(eglot--define-process-var eglot--major-mode nil
  "The major-mode this server is managing.")

(eglot--define-process-var eglot--expected-bytes nil
  "How many bytes declared by server")

(eglot--define-process-var eglot--pending-continuations (make-hash-table)
  "A hash table of request ID to continuation lambdas")

(eglot--define-process-var eglot--events-buffer nil
  "A buffer pretty-printing the EGLOT RPC events")

(eglot--define-process-var eglot--capabilities :unreported
  "Holds list of capabilities that server reported")

(eglot--define-process-var eglot--moribund nil
  "Non-nil if server is about to exit")

(eglot--define-process-var eglot--project nil
  "The project the server belongs to.")

(eglot--define-process-var eglot--spinner `(nil nil t)
  "\"Spinner\" used by some servers.
A list (ID WHAT DONE-P)." t)

(eglot--define-process-var eglot--status `(:unknown nil)
  "Status as declared by the server.
A list (WHAT SERIOUS-P)." t)

(eglot--define-process-var eglot--bootstrap-fn nil
  "Function for returning processes/connetions to LSP servers.
Must be a function of one arg, a name, returning a process
object.")

(defun eglot-make-local-process (name command)
  "Make a local LSP process from COMMAND.
NAME is a name to give the inferior process or connection.
Returns a process object."
  (let* ((readable-name (format "EGLOT server (%s)" name))
         (proc
          (make-process
           :name readable-name
           :buffer (get-buffer-create
                    (format "*%s inferior*" readable-name))
           :command command
           :connection-type 'pipe
           :filter 'eglot--process-filter
           :sentinel 'eglot--process-sentinel
           :stderr (get-buffer-create (format "*%s stderr*"
                                              name)))))
    proc))

(defmacro eglot--obj (&rest what)
  "Make WHAT a suitable argument for `json-encode'."
  ;; FIXME: maybe later actually do something, for now this just fixes
  ;; the indenting of literal plists.
  `(list ,@what))

(defun eglot--project-short-name (project)
  "Give PROJECT a short name."
  (file-name-base
   (directory-file-name
    (car (project-roots project)))))

(defun eglot--all-major-modes ()
  "Return all know major modes."
  (let ((retval))
    (mapatoms (lambda (sym)
                (when (plist-member (symbol-plist sym) 'derived-mode-parent)
                  (push sym retval))))
    retval))

(defun eglot--connect (project managed-major-mode
                               short-name bootstrap-fn &optional success-fn)
  "Make a connection for PROJECT, SHORT-NAME and MANAGED-MAJOR-MODE.
Use BOOTSTRAP-FN to make the actual process object.  Call
SUCCESS-FN with no args if all goes well."
  (let* ((proc (funcall bootstrap-fn short-name))
         (buffer (process-buffer proc)))
    (setf (eglot--bootstrap-fn proc) bootstrap-fn
          (eglot--project proc) project
          (eglot--major-mode proc) managed-major-mode)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (setf (eglot--short-name proc) short-name)
        (push proc
              (gethash (project-current)
                       eglot--processes-by-project))
        (erase-buffer)
        (read-only-mode t)
        (with-current-buffer (eglot-events-buffer proc)
          (let ((inhibit-read-only t))
            (insert
             (format "\n-----------------------------------\n"))))
        (eglot--request
         proc
         :initialize
         (eglot--obj :processId  (emacs-pid)
                     :rootPath  (concat
                                 (expand-file-name (car (project-roots
                                                         (project-current)))))
                     :initializationOptions  []
                     :capabilities
                     (eglot--obj
                      :workspace (eglot--obj)
                      :textDocument (eglot--obj
                                     :publishDiagnostics `(:relatedInformation t))))
         :success-fn
         (cl-function
          (lambda (&key capabilities)
            (setf (eglot--capabilities proc) capabilities)
            (setf (eglot--status proc) nil)
            (when success-fn (funcall success-fn proc))
            (eglot--notify proc :initialized nil))))))))

(defvar eglot--command-history nil
  "History of COMMAND arguments to `eglot'.")

(defun eglot (managed-major-mode command &optional interactive)
  ;; FIXME: Later make this function also connect to TCP servers by
  ;; overloading semantics on COMMAND.
  "Start a Language Server Protocol server.
Server is started with COMMAND and manages buffers of
MANAGED-MAJOR-MODE for the current project.

COMMAND is a list of strings, an executable program and
optionally its arguments.  MANAGED-MAJOR-MODE is an Emacs major
mode.

With a prefix arg, prompt for MANAGED-MAJOR-MODE and COMMAND,
else guess them from current context and `eglot-executables'.

INTERACTIVE is t if called interactively."
  (interactive
   (let* ((managed-major-mode
           (cond
            ((or current-prefix-arg
                 (not buffer-file-name))
             (intern
              (completing-read
               "[eglot] Start a server to manage buffers of what major mode? "
               (mapcar #'symbol-name
                       (eglot--all-major-modes)) nil t
               (symbol-name major-mode) nil
               (symbol-name major-mode) nil)))
            (t major-mode)))
          (guessed-command
           (cdr (assoc managed-major-mode eglot-executables))))
     (list
      managed-major-mode
      (if current-prefix-arg
          (split-string-and-unquote
           (read-shell-command "[eglot] Run program: "
                               (combine-and-quote-strings guessed-command)
                               'eglot-command-history))
        guessed-command)
      t)))
  (let* ((project (project-current))
         (short-name (eglot--project-short-name project)))
    (unless project (eglot--error
                     "Cannot work without a current project!"))
    (let ((current-process (eglot--current-process))
          (command
           (or command
               (eglot--error "Don't know how to start EGLOT for %s buffers"
                             major-mode))))
      (cond
       ((and current-process
             (process-live-p current-process))
        (when (and
               interactive
               (y-or-n-p "[eglot] Live process found, reconnect instead? "))
          (eglot-reconnect current-process interactive)))
       (t
        (eglot--connect
         project
         managed-major-mode
         short-name
         (lambda (name)
           (eglot-make-local-process
            name
            command))
         (lambda (proc)
           (eglot--message "Connected! Process `%s' now managing `%s'\
buffers in project %s."
                           proc
                           managed-major-mode
                           short-name)
           (dolist (buffer (buffer-list))
             (with-current-buffer buffer
               (eglot--maybe-activate-editing-mode proc))))))))))

(defun eglot-reconnect (process &optional interactive)
  "Reconnect to PROCESS.
INTERACTIVE is t if called interactively."
  (interactive (list (eglot--current-process-or-lose) t))
  (when (process-live-p process)
    (eglot-shutdown process 'sync interactive))
  (eglot--connect
   (eglot--project process)
   (eglot--major-mode process)
   (eglot--short-name process)
   (eglot--bootstrap-fn process)
   (lambda (proc)
     (eglot--message "Reconnected!")
     (dolist (buffer (buffer-list))
       (with-current-buffer buffer
         (eglot--maybe-activate-editing-mode proc))))))

(defun eglot--process-sentinel (process change)
  "Called with PROCESS undergoes CHANGE."
  (eglot--debug "(sentinel) Process state changed to %s" change)
  (when (not (process-live-p process))
    ;; Remember to cancel all timers
    ;;
    (maphash (lambda (id triplet)
               (cl-destructuring-bind (_success _error timeout) triplet
                 (eglot--message
                  "(sentinel) Cancelling timer for continuation %s" id)
                 (cancel-timer timeout)))
             (eglot--pending-continuations process))
    (cond ((eglot--moribund process)
           (eglot--message "(sentinel) Moribund process exited with status %s"
                           (process-exit-status process))
           (setf (gethash (eglot--project process) eglot--processes-by-project)
                 (delq process
                       (gethash (eglot--project process) eglot--processes-by-project))))
          (t
           (eglot--warn
            "(sentinel) Reconnecting after process unexpectedly changed to %s."
            change)
           (eglot-reconnect process)))
    (force-mode-line-update t)
    (delete-process process)))

(defun eglot--process-filter (proc string)
  "Called when new data STRING has arrived for PROC."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((inhibit-read-only t)
            (expected-bytes (eglot--expected-bytes proc)))
        ;; Insert the text, advancing the process marker.
        ;;
        (save-excursion
          (goto-char (process-mark proc))
          (insert string)
          (set-marker (process-mark proc) (point)))
        ;; Loop (more than one message might have arrived)
        ;;
        (catch 'done
          (while t
            (cond ((not expected-bytes)
                   ;; Starting a new message
                   ;;
                   (setq expected-bytes
                         (and (search-forward-regexp
                               "\\(?:.*: .*\r\n\\)*Content-Length: \
*\\([[:digit:]]+\\)\r\n\\(?:.*: .*\r\n\\)*\r\n"
                               (+ (point) 100)
                               t)
                              (string-to-number (match-string 1))))
                   (unless expected-bytes
                     (throw 'done :waiting-for-new-message)))
                  (t
                   ;; Attempt to complete a message body
                   ;;
                   (let ((available-bytes (- (position-bytes (process-mark proc))
                                             (position-bytes (point)))))
                     (cond
                      ((>= available-bytes
                           expected-bytes)
                       (let* ((message-end (byte-to-position
                                            (+ (position-bytes (point))
                                               expected-bytes))))
                         (unwind-protect
                             (save-restriction
                               (narrow-to-region (point) message-end)
                               (let* ((json-object-type 'plist)
                                      (json-message (json-read)))
                                 ;; Process content in another buffer,
                                 ;; shielding buffer from tamper
                                 ;;
                                 (with-temp-buffer
                                   (eglot--process-receive proc json-message))))
                           (goto-char message-end)
                           (delete-region (point-min) (point))
                           (setq expected-bytes nil))))
                      (t
                       ;; Message is still incomplete
                       ;;
                       (throw 'done :waiting-for-more-bytes-in-this-message))))))))
        ;; Saved parsing state for next visit to this filter
        ;;
        (setf (eglot--expected-bytes proc) expected-bytes)))))

(defun eglot-events-buffer (process &optional interactive)
  "Display events buffer for current LSP connection PROCESS.
INTERACTIVE is t if called interactively."
  (interactive (list (eglot--current-process-or-lose) t))
  (let* ((probe (eglot--events-buffer process))
         (buffer (or (and (buffer-live-p probe)
                          probe)
                     (let ((buffer (get-buffer-create
                                    (format "*%s events*"
                                            (process-name process)))))
                       (with-current-buffer buffer
                         (buffer-disable-undo)
                         (read-only-mode t)
                         (setf (eglot--events-buffer process) buffer
                               eglot--special-buffer-process process)
                         (eglot-mode))
                       buffer))))
    (when interactive
      (display-buffer buffer))
    buffer))

(defun eglot--log-event (proc type message &optional id error)
  "Log an eglot-related event.
PROC is the current process.  TYPE is an identifier.  MESSAGE is
a JSON-like plist or anything else.  ID is a continuation
identifier.  ERROR is non-nil if this is an error."
  (with-current-buffer (eglot-events-buffer proc)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (let ((msg (format "%s%s%s:\n%s\n"
                         type
                         (if id (format " (id:%s)" id) "")
                         (if error " ERROR" "")
                         (pp-to-string message))))
        (when error
          (setq msg (propertize msg 'face 'error)))
        (insert msg)))))

(defun eglot--process-receive (proc message)
  "Process MESSAGE from PROC."
  (let* ((response-id (plist-get message :id))
         (err (plist-get message :error))
         (continuations (and response-id
                             (gethash response-id
                                      (eglot--pending-continuations proc)))))
    (eglot--log-event proc
                      (cond ((not response-id)
                             'server-notification)
                            ((not continuations)
                             'unexpected-server-reply)
                            (t
                             'server-reply))
                      message
                      response-id
                      err)
    (when err
      (setf (eglot--status proc) '("error" t)))
    (cond ((and response-id
                (not continuations))
           (eglot--warn "Ooops no continuation for id %s" response-id))
          (continuations
           (cancel-timer (cl-third continuations))
           (remhash response-id
                    (eglot--pending-continuations proc))
           (cond (err
                  (apply (cl-second continuations) err))
                 (t
                  (apply (cl-first continuations) (plist-get message :result)))))
          (t
           ;; a server notification or a server request
           (let* ((method (plist-get message :method))
                  (handler-sym (intern (concat "eglot--server-"
                                               method))))
             (if (functionp handler-sym)
                 (apply handler-sym proc (append
                                          (plist-get message :params)
                                          (let ((id (plist-get message :id)))
                                            (if id `(:id ,id)))))
               ;; pyls keeps on sending nil notifs for each notif we
               ;; send it, just ignore these.
               (unless (null method)
                 (eglot--warn "No implemetation for notification %s yet"
                              method))))))))

(defvar eglot--expect-carriage-return nil)

(defun eglot--process-send (id proc message)
  "Send MESSAGE to PROC (ID is optional)."
  (let* ((json (json-encode message))
         (to-send (format "Content-Length: %d\r\n\r\n%s"
                          (string-bytes json)
                          json)))
    (process-send-string proc to-send)
    (eglot--log-event proc (if id
                               'client-request
                             'client-notification)
                      message id nil)))

(defvar eglot--next-request-id 0)

(defun eglot--next-request-id ()
  "Compute the next id for a client request."
  (setq eglot--next-request-id (1+ eglot--next-request-id)))

(defun eglot-forget-pending-continuations (process)
  "Stop waiting for responses from the current LSP PROCESS."
  (interactive (list (eglot--current-process-or-lose)))
  (clrhash (eglot--pending-continuations process)))

(defun eglot-clear-status (process)
  "Clear most recent error message from PROCESS."
  (interactive (list (eglot--current-process-or-lose)))
  (setf (eglot--status process) nil))

(cl-defun eglot--request (process
                          method
                          params
                          &key success-fn error-fn timeout-fn (async-p t))
  "Make a request to PROCESS, expecting a reply."
  (let* ((id (eglot--next-request-id))
         (timeout-fn
          (or timeout-fn
              (lambda ()
                (eglot--warn
                 "(request) Tired of waiting for reply to %s" id)
                (remhash id (eglot--pending-continuations process)))))
         (error-fn
          (or error-fn
              (cl-function
               (lambda (&key code message &allow-other-keys)
                 (setf (eglot--status process) '("error" t))
                 (eglot--warn
                  "(request) Request id=%s errored with code=%s: %s"
                  id code message)))))
         (success-fn
          (or success-fn
              (cl-function
               (lambda (&rest result-body)
                 (eglot--debug
                  "(request) Request id=%s replied to with result=%s: %s"
                  id result-body)))))
         (catch-tag (cl-gensym (format "eglot--tag-%d-" id))))
    (eglot--process-send id
                         process
                         (eglot--obj :jsonrpc "2.0"
                                     :id id
                                     :method method
                                     :params params))
    (catch catch-tag
      (let ((timeout-timer
             (run-with-timer 5 nil
                             (if async-p
                                 timeout-fn
                               (lambda ()
                                 (throw catch-tag (funcall timeout-fn)))))))
        (puthash id
                 (list (if async-p
                           success-fn
                         (lambda (&rest args)
                           (throw catch-tag (apply success-fn args))))
                       (if async-p
                           error-fn
                         (lambda (&rest args)
                           (throw catch-tag (apply error-fn args))))
                       timeout-timer)
                 (eglot--pending-continuations process))
        (unless async-p
          (unwind-protect
              (while t
                (unless (process-live-p process)
                  (cond ((eglot--moribund process)
                         (throw catch-tag (delete-process process)))
                        (t
                         (eglot--error
                          "(request) Proc %s died unexpectedly during request with code %s"
                          process
                          (process-exit-status process)))))
                (accept-process-output nil 0.01))
            (when (memq timeout-timer timer-list)
              (eglot--message
               "(request) Last-change cancelling timer for continuation %s" id)
              (cancel-timer timeout-timer))))))))

(cl-defun eglot--notify (process method params)
  "Notify PROCESS of something, don't expect a reply.e"
  (eglot--process-send nil
                       process
                       (eglot--obj :jsonrpc  "2.0"
                                   :id nil
                                   :method method
                                   :params params)))


;;; Helpers
;;;
(defun eglot--debug (format &rest args)
  "Debug message FORMAT with ARGS."
  (display-warning 'eglot
                   (apply #'format format args)
                   :debug))

(defun eglot--error (format &rest args)
  "Error out with FORMAT with ARGS."
  (error (apply #'format format args)))

(defun eglot--message (format &rest args)
  "Message out with FORMAT with ARGS."
  (message (concat "[eglot] " (apply #'format format args))))

(defun eglot--log (format &rest args)
  "Log out with FORMAT with ARGS."
  (message (concat "[eglot-log] " (apply #'format format args))))

(defun eglot--warn (format &rest args)
  "Warning message with FORMAT and ARGS."
  (apply #'eglot--message (concat "(warning) " format) args)
  (let ((warning-minimum-level :error))
    (display-warning 'eglot
                     (apply #'format format args)
                     :warning)))


;;; Minor modes
;;;
(defvar eglot-mode-map (make-sparse-keymap))

(defvar eglot-editing-mode-map (make-sparse-keymap))

(define-minor-mode eglot-editing-mode
  "Minor mode for source buffers where EGLOT helps you edit."
  nil
  nil
  eglot-mode-map
  (cond
   (eglot-editing-mode
    (eglot-mode 1)
    (add-hook 'after-change-functions 'eglot--after-change nil t)
    (add-hook 'before-change-functions 'eglot--before-change nil t)
    (add-hook 'flymake-diagnostic-functions 'eglot-flymake-backend nil t)
    (add-hook 'kill-buffer-hook 'eglot--signal-textDocument/didClose nil t)
    (add-hook 'before-revert-hook 'eglot--signal-textDocument/didClose nil t)
    (add-hook 'after-revert-hook 'eglot--signal-textDocument/didOpen nil t)
    (add-hook 'before-save-hook 'eglot--signal-textDocument/willSave nil t)
    (add-hook 'after-save-hook 'eglot--signal-textDocument/didSave nil t)
    (flymake-mode 1)
    (unless (eglot--current-process)
      (eglot--warn "No process, start one with `M-x eglot'")))
   (t
    (remove-hook 'flymake-diagnostic-functions 'eglot-flymake-backend t)
    (remove-hook 'after-change-functions 'eglot--after-change t)
    (remove-hook 'before-change-functions 'eglot--before-change t)
    (remove-hook 'kill-buffer-hook 'eglot--signal-textDocument/didClose t)
    (remove-hook 'before-revert-hook 'eglot--signal-textDocument/didClose t)
    (remove-hook 'after-revert-hook 'eglot--signal-textDocument/didOpen t)
    (remove-hook 'before-save-hook 'eglot--signal-textDocument/willSave t)
    (remove-hook 'after-save-hook 'eglot--signal-textDocument/didSave t))))

(define-minor-mode eglot-mode
  "Minor mode for all buffers managed by EGLOT in some way."  nil
  nil eglot-mode-map
  (cond (eglot-mode
         (when (and buffer-file-name
                    (not eglot-editing-mode))
           (eglot-editing-mode 1)))
        (t
         (when eglot-editing-mode
           (eglot-editing-mode -1)))))

(defun eglot--maybe-activate-editing-mode (&optional proc)
  "Maybe activate mode function `eglot-editing-mode'.
If PROC is supplied, do it only if BUFFER is managed by it.  In
that case, also signal textDocument/didOpen."
  (when buffer-file-name
    (let ((cur (eglot--current-process)))
      (when (or (and (null proc) cur)
                (and proc (eq proc cur)))
        (unless eglot-editing-mode
          (eglot-editing-mode 1))
        (eglot--signal-textDocument/didOpen)
        (flymake-start)))))

(add-hook 'find-file-hook 'eglot--maybe-activate-editing-mode)


;;; Mode-line, menu and other sugar
;;;
(defvar eglot-menu)

(easy-menu-define eglot-menu eglot-mode-map "EGLOT"
  `("EGLOT" ))

(defvar eglot--mode-line-format
  `(:eval (eglot--mode-line-format)))

(put 'eglot--mode-line-format 'risky-local-variable t)

(defun eglot--mode-line-format ()
  "Compose the mode-line format spec."
  (pcase-let* ((proc (eglot--current-process))
               (name (and proc
                          (process-live-p proc)
                          (eglot--short-name proc)))
               (pending (and proc
                             (hash-table-count
                              (eglot--pending-continuations proc))))
               (`(,_id ,doing ,done-p)
                (and proc
                     (eglot--spinner proc)))
               (`(,status ,serious-p)
                (and proc
                     (eglot--status proc))))
    (append
     `((:propertize "eglot"
                    face eglot-mode-line
                    keymap ,(let ((map (make-sparse-keymap)))
                              (define-key map [mode-line down-mouse-1]
                                eglot-menu)
                              map)
                    mouse-face mode-line-highlight
                    help-echo "mouse-1: pop-up EGLOT menu"
                    ))
     (when name
       `(":"
         (:propertize
          ,name
          face eglot-mode-line
          keymap ,(let ((map (make-sparse-keymap)))
                    (define-key map [mode-line mouse-1] 'eglot-events-buffer)
                    (define-key map [mode-line mouse-2] 'eglot-shutdown)
                    (define-key map [mode-line mouse-3] 'eglot-reconnect)
                    map)
          mouse-face mode-line-highlight
          help-echo ,(concat "mouse-1: go to events buffer\n"
                             "mouse-2: quit server\n"
                             "mouse-3: reconnect to server"))
         ,@(when serious-p
             `("/"
               (:propertize
                ,status
                help-echo ,(concat "mouse-1: go to events buffer\n"
                                   "mouse-3: clear this status")
                mouse-face mode-line-highlight
                face compilation-mode-line-fail
                keymap ,(let ((map (make-sparse-keymap)))
                          (define-key map [mode-line mouse-1]
                            'eglot-events-buffer)
                          (define-key map [mode-line mouse-3]
                            'eglot-clear-status)
                          map))))
         ,@(when (and doing (not done-p))
             `("/"
               (:propertize
                ,doing
                help-echo ,(concat "mouse-1: go to events buffer")
                mouse-face mode-line-highlight
                face compilation-mode-line-run
                keymap ,(let ((map (make-sparse-keymap)))
                          (define-key map [mode-line mouse-1]
                            'eglot-events-buffer)
                          map))))
         ,@(when (cl-plusp pending)
             `("/"
               (:propertize
                (format "%d" pending)
                help-echo ,(format
                            "%s unanswered requests\n%s"
                            pending
                            (concat "mouse-1: go to events buffer"
                                    "mouse-3: forget pending continuations"))
                mouse-face mode-line-highlight
                face ,(cond ((and pending (cl-plusp pending))
                             'warning)
                            (t
                             'eglot-mode-line))
                keymap ,(let ((map (make-sparse-keymap)))
                          (define-key map [mode-line mouse-1]
                            'eglot-events-buffer)
                          (define-key map [mode-line mouse-3]
                            'eglot-forget-pending-continuations)
                          map)))))))))

(add-to-list 'mode-line-misc-info
             `(eglot-mode
               (" [" eglot--mode-line-format "] ")))


;;; Protocol implementation (Requests, notifications, etc)
;;;
(defun eglot-shutdown (process &optional sync interactive)
  "Politely ask the server PROCESS to quit.
Forcefully quit it if it doesn't respond.
If SYNC, don't leave this function with the server still
running.  INTERACTIVE is t if called interactively."
  (interactive (list (eglot--current-process-or-lose) t t))
  (when interactive
    (eglot--message "(eglot-shutdown) Asking %s politely to terminate"
                    process))
  (let ((brutal (lambda ()
                  (eglot--warn "Brutally deleting existing process %s"
                               process)
                  (setf (eglot--moribund process) t)
                  (delete-process process))))
    (eglot--request
     process
     :shutdown
     nil
     :success-fn (lambda (&rest _anything)
                   (when interactive
                     (eglot--message "Now asking %s politely to exit" process))
                   (setf (eglot--moribund process) t)
                   (eglot--request process
                                   :exit
                                   nil
                                   :success-fn brutal
                                   :async-p (not sync)
                                   :error-fn brutal
                                   :timeout-fn brutal))
     :error-fn brutal
     :async-p (not sync)
     :timeout-fn brutal)))

(cl-defun eglot--server-window/showMessage
    (_process &key type message)
  "Handle notification window/showMessage"
  (eglot--message (propertize "Server reports (type=%s): %s"
                              'face (if (<= type 1) 'error))
                  type message))

(cl-defun eglot--server-window/showMessageRequest
    (process &key id type message actions)
  "Handle server request window/showMessageRequest"
  (let (reply)
    (unwind-protect
        (setq reply
              (completing-read
               (concat
                (format (propertize "[eglot] Server reports (type=%s): %s"
                                    'face (if (<= type 1) 'error))
                        type message)
                "\nChoose an option: ")
               (mapcar (lambda (obj) (plist-get obj :title)) actions)
               nil
               t
               (plist-get (elt actions 0) :title)))
      (eglot--process-send
       id
       process
       (if reply
           (eglot--obj :result (eglot--obj :title reply))
         ;; request cancelled
         (eglot--obj :error -32800))))))

(cl-defun eglot--server-window/logMessage
    (_process &key type message)
  "Handle notification window/logMessage"
  (eglot--log (propertize "Server reports (type=%s): %s"
                          'face (if (<= type 1) 'error))
              type message))

(cl-defun eglot--server-telemetry/event
    (_process &rest any)
  "Handle notification telemetry/event"
  (eglot--log "Server telemetry: %s" any))

(defvar-local eglot--current-flymake-report-fn nil
  "Current flymake report function for this buffer")

(defvar-local eglot--unreported-diagnostics nil
  "Unreported diagnostics for this buffer.")

(cl-defun eglot--server-textDocument/publishDiagnostics
    (_process &key uri diagnostics)
  "Handle notification publishDiagnostics"
  (let* ((obj (url-generic-parse-url uri))
	 (filename (car (url-path-and-query obj)))
         (buffer (find-buffer-visiting filename)))
    (cond
     (buffer
      (with-current-buffer buffer
        (cl-flet ((pos-at
                   (pos-plist)
                   (save-excursion
                     (goto-char (point-min))
                     (forward-line (plist-get pos-plist :line))
                     (forward-char
                      (min (plist-get pos-plist :character)
                           (- (line-end-position)
                              (line-beginning-position))))
                     (point))))
          (cl-loop for diag-spec across diagnostics
                   collect (cl-destructuring-bind (&key range severity _group
                                                        _code _source message)
                               diag-spec
                             (cl-destructuring-bind (&key start end)
                                 range
                               (let* ((begin-pos (pos-at start))
                                      (end-pos (pos-at end)))
                                 (flymake-make-diagnostic
                                  (current-buffer)
                                  begin-pos end-pos
                                  (cond ((<= severity 1)
                                         :error)
                                        ((= severity 2)
                                         :warning)
                                        (t
                                         :note))
                                  message))))
                   into diags
                   finally
                   (if eglot--current-flymake-report-fn
                       (funcall eglot--current-flymake-report-fn
                                diags)
                     (setq eglot--unreported-diagnostics
                           diags))))))
     (t
      (eglot--message "OK so %s isn't visited" filename)))))

(defvar eglot--recent-before-changes nil
  "List of recent changes as collected by `eglot--before-change'.")
(defvar eglot--recent-after-changes nil
  "List of recent changes as collected by `eglot--after-change'.")

(defvar-local eglot--versioned-identifier 0)

(defun eglot--current-buffer-VersionedTextDocumentIdentifier ()
  "Compute VersionedTextDocumentIdentifier object for current buffer."
  (eglot--obj :uri
              (concat "file://"
                      (url-hexify-string
                       (file-truename buffer-file-name)
                       url-path-allowed-chars))
              ;; FIXME: later deal with workspaces
              :version eglot--versioned-identifier))

(defun eglot--current-buffer-TextDocumentItem ()
  "Compute TextDocumentItem object for current buffer."
  (append
   (eglot--current-buffer-VersionedTextDocumentIdentifier)
   (eglot--obj :languageId (cdr (assoc major-mode
                                       '((rust-mode . rust)
                                         (emacs-lisp-mode . emacs-lisp))))
               :text
               (save-restriction
                 (widen)
                 (buffer-substring-no-properties (point-min) (point-max))))))

(defun eglot--pos-to-lsp-position (pos)
  "Convert point POS to LSP position."
  (save-excursion
    (eglot--obj :line
                ;; F!@(#*&#$)CKING OFF-BY-ONE
                (1- (line-number-at-pos pos t))
                :character
                (- (goto-char pos)
                   (line-beginning-position)))))

(defun eglot--before-change (start end)
  "Hook onto `before-change-functions'.
Records START and END, crucially convert them into
LSP (line/char) positions before that information is
lost (because the after-change thingy doesn't know if newlines
were deleted/added)"
  (push (list (eglot--pos-to-lsp-position start)
              (eglot--pos-to-lsp-position end))
        eglot--recent-before-changes))

(defun eglot--after-change (start end pre-change-length)
  "Hook onto `after-change-functions'.
Records START, END and PRE-CHANGE-LENGTH locally."
  (cl-incf eglot--versioned-identifier)
  (push (list start end pre-change-length) eglot--recent-after-changes))

(defun eglot--signal-textDocument/didChange ()
  "Send textDocument/didChange to server."
  (when (and eglot--recent-before-changes
             eglot--recent-after-changes)
    (save-excursion
      (save-restriction
        (widen)
        (if (/= (length eglot--recent-before-changes)
                (length eglot--recent-after-changes))
            (eglot--notify
             (eglot--current-process-or-lose)
             :textDocument/didChange
             (eglot--obj
              :textDocument (eglot--current-buffer-VersionedTextDocumentIdentifier)
              :contentChanges
              (vector
               (eglot--obj
                :text (buffer-substring-no-properties (point-min) (point-max))))))
          (let ((combined (cl-mapcar 'append
                                     eglot--recent-before-changes
                                     eglot--recent-after-changes)))
            (eglot--notify
             (eglot--current-process-or-lose)
             :textDocument/didChange
             (eglot--obj
              :textDocument (eglot--current-buffer-VersionedTextDocumentIdentifier)
              :contentChanges
              (apply
               #'vector
               (mapcar (pcase-lambda (`(,before-start-position
                                        ,before-end-position
                                        ,after-start
                                        ,after-end
                                        ,len))
                         (eglot--obj
                          :range
                          (eglot--obj
                           :start before-start-position
                           :end before-end-position)
                          :rangeLength len
                          :text (buffer-substring-no-properties after-start after-end)))
                       (reverse combined))))))))))
  (setq eglot--recent-before-changes nil
        eglot--recent-after-changes nil))

(defvar-local eglot--buffer-open-count 0)
(defun eglot--signal-textDocument/didOpen ()
  "Send textDocument/didOpen to server."
  (cl-incf eglot--buffer-open-count)
  (when (> eglot--buffer-open-count 1)
    (error "Too many textDocument/didOpen notifs for %s" (current-buffer)))
  (eglot--notify (eglot--current-process-or-lose)
                 :textDocument/didOpen
                 (eglot--obj :textDocument
                             (eglot--current-buffer-TextDocumentItem))))

(defun eglot--signal-textDocument/didClose ()
  "Send textDocument/didClose to server."
  (cl-decf eglot--buffer-open-count)
  (when (< eglot--buffer-open-count 0)
    (error "Too many textDocument/didClose notifs for %s" (current-buffer)))
  (eglot--notify (eglot--current-process-or-lose)
                 :textDocument/didClose
                 (eglot--obj :textDocument
                             (eglot--current-buffer-TextDocumentItem))))

(defun eglot--signal-textDocument/willSave ()
  "Send textDocument/willSave to server."
  (eglot--notify
   (eglot--current-process-or-lose)
   :textDocument/willSave
   (eglot--obj
    :reason 1 ; Manual, emacs laughs in the face of auto-save muahahahaha
    :textDocument (eglot--current-buffer-TextDocumentItem))))

(defun eglot--signal-textDocument/didSave ()
  "Send textDocument/didSave to server."
  (eglot--notify
   (eglot--current-process-or-lose)
   :textDocument/didSave
   (eglot--obj
    ;; TODO: Handle TextDocumentSaveRegistrationOptions to control this.
    :text (buffer-substring-no-properties (point-min) (point-max))
    :textDocument (eglot--current-buffer-TextDocumentItem))))

(defun eglot-flymake-backend (report-fn &rest _more)
  "An EGLOT Flymake backend.
Calls REPORT-FN maybe if server publishes diagnostics in time."
  ;; Maybe call immediately if anything unreported (this will clear
  ;; any pending diags)
  (when eglot--unreported-diagnostics
    (funcall report-fn eglot--unreported-diagnostics)
    (setq eglot--unreported-diagnostics nil))
  ;; Setup so maybe it's called later, too.
  (setq eglot--current-flymake-report-fn report-fn)
  ;; Take this opportunity to signal a didChange that might eventually
  ;; make the server report new diagnostics.
  (eglot--signal-textDocument/didChange))


;;; Rust-specific
;;;
(cl-defun eglot--server-window/progress
    (process &key id done title &allow-other-keys)
  "Handle notification window/progress"
  (setf (eglot--spinner process) (list id title done)))

(provide 'eglot)
;;; eglot.el ends here

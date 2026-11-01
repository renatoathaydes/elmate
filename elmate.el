;;; elmate.el --- AI chat inside Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1") (markdown-mode "2.6"))

;;; Commentary:
;; A small OpenAI-compatible streaming chat buffer with Markdown rendering.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'json)
(require 'markdown-mode)
(require 'project)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-parse)

(defgroup elmate nil "AI chat inside Emacs." :group 'tools)

(defcustom elmate-api-url "https://api.openai.com/v1/chat/completions"
  "OpenAI-compatible chat completions endpoint."
  :type 'string)
(defcustom elmate-model "gpt-4o-mini" "Model used by Elmate." :type 'string)
(defcustom elmate-system-prompt "You are a helpful assistant."
  "System prompt sent at the start of each chat." :type 'string)
(defcustom elmate-include-agents-md t
  "Whether to include the current project's AGENTS.md when present."
  :type 'boolean)
(defcustom elmate-save-chats nil
  "When non-nil, save conversations locally and offer them when opening a chat."
  :type 'boolean)
(defcustom elmate-chat-directory
  (expand-file-name "elmate/chats/" user-emacs-directory)
  "Directory used for opt-in saved conversations."
  :type 'directory)

(defvar-local elmate--history nil)
(defvar-local elmate--busy nil)
(defvar-local elmate--prompt-marker nil)
(defvar-local elmate--reply-marker nil)
(defvar-local elmate--indicator-start nil)
(defvar-local elmate--indicator-end nil)
(defvar-local elmate--indicator-timer nil)
(defvar-local elmate--indicator-frame 0)
(defvar-local elmate--project-root nil)
(defvar-local elmate--chat-id nil)
(defvar-local elmate--system-context nil)
(defvar-local elmate--retry-count nil)
(defvar-local elmate--request-buffer nil)
(defvar-local elmate--event-marker nil)
(defvar-local elmate--event-data nil)
(defvar-local elmate--streaming nil)
(defvar-local elmate--chat-buffer nil)
(defconst elmate--buffer-name "*Elmate Chat*")
(defconst elmate--warnings-buffer "*Warnings* Elmate")

(defun elmate--project-root ()
  "Return the project root, falling back to `default-directory'."
  (or (when-let* ((project (project-current nil))) (project-root project))
      (locate-dominating-file default-directory "AGENTS.md")
      default-directory))

(defun elmate--context-messages ()
  "Build initial system context for the current project."
  (let ((agents (and elmate-include-agents-md
                     (expand-file-name "AGENTS.md" elmate--project-root))))
    (concat elmate-system-prompt
            (if (and agents (file-readable-p agents))
                (format "\n\nProject guidance from AGENTS.md:\n%s"
                        (with-temp-buffer
                          (insert-file-contents agents)
                          (buffer-string)))
              ""))))

(defun elmate--completion-url (url)
  "Return URL with the chat-completions path appended when missing."
  (if (string-match
       "\\`\\(https?://[^/?#]+\\)\\([^?#]*\\)\\([?#].*\\)?\\'"
       url)
      (let* ((origin (match-string 1 url))
             (path (match-string 2 url))
             (suffix (or (match-string 3 url) ""))
             (trimmed-path (string-trim-right path "/")))
        (if (string-suffix-p "/chat/completions" trimmed-path)
            url
          (concat origin trimmed-path "/chat/completions" suffix)))
    (user-error "Invalid API URL: %s" url)))

(defun elmate--auth-token ()
  "Look up an API key via Emacs `auth-source' for the configured endpoint."
  (let* ((host (url-host (url-generic-parse-url elmate-api-url)))
         (entry (car (auth-source-search :host host :user "apikey"
                                         :require '(:secret) :max 1)))
         (secret (plist-get entry :secret)))
    (when (functionp secret) (setq secret (funcall secret)))
    (unless (and (stringp secret) (not (string-empty-p secret)))
      (user-error "No API key found in auth-source for host %s (user apikey)" host))
    secret))

(defun elmate--project-key (root)
  "Return a stable filesystem-safe key for ROOT."
  (secure-hash 'sha256 (file-truename root)))

(defun elmate--saved-file (root)
  "Return the persistence file for ROOT."
  (expand-file-name (concat (elmate--project-key root) ".json") elmate-chat-directory))

(defun elmate--load-saved (root)
  "Load saved chat sessions for ROOT."
  (let ((file (elmate--saved-file root)))
    (when (file-readable-p file)
      (condition-case err
          (let ((json-object-type 'alist)
                (json-array-type 'list)
                (json-key-type 'symbol))
            (with-temp-buffer
              (insert-file-contents file)
              (json-read)))
        (error (display-warning 'elmate (format "Cannot read saved chats: %s" err)) nil)))))

(defun elmate--save ()
  "Persist the current chat if persistence is enabled."
  (when (and elmate-save-chats elmate--project-root elmate--chat-id)
    (make-directory elmate-chat-directory t)
    (let* ((file (elmate--saved-file elmate--project-root))
           (sessions (or (elmate--load-saved elmate--project-root) nil))
           (session `((id . ,elmate--chat-id)
                      (updated . ,(format-time-string "%FT%T%z"))
                      (history . ,(vconcat elmate--history))))
           (sessions (cons session
                           (cl-remove-if (lambda (item)
                                           (equal (alist-get 'id item) elmate--chat-id))
                                         sessions))))
      (with-temp-file file
        (let ((json-encoding-pretty-print t))
          (insert (json-encode sessions)))))))

(defun elmate--restore (session)
  "Restore SESSION history into the current chat buffer."
  (setq elmate--chat-id (alist-get 'id session)
        elmate--history (or (alist-get 'history session) nil))
  (elmate--render-history))

(defun elmate--insert-prompt ()
  "Insert an editable prompt line and set its marker."
  (insert (propertize "> " 'read-only t 'rear-nonsticky '(read-only)))
  (setq elmate--prompt-marker (copy-marker (point) nil)))

(defun elmate--render-history ()
  "Render current history in the chat buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Elmate — OpenAI-compatible chat\n\n" 'face 'bold 'read-only t))
    (setq elmate--reply-marker nil)
    (dolist (turn elmate--history)
      (let ((role (alist-get 'role turn))
            (content (alist-get 'content turn)))
        (unless (equal role "system")
          (insert (propertize (if (equal role "user") "You\n" "Assistant\n")
                              'face (if (equal role "user") 'font-lock-keyword-face 'bold)
                              'read-only t))
          (insert (propertize (concat (or content "") "\n\n") 'read-only t))
          (when (equal role "assistant")
            (setq elmate--reply-marker
                  (copy-marker (- (point) (length content) 2) nil))))))
    (elmate--insert-prompt)
    (setq buffer-read-only nil)
    (goto-char (point-max))
    (font-lock-ensure)))

(defun elmate--new-chat (root)
  "Initialize a clean chat for ROOT."
  (setq elmate--project-root root
        elmate--chat-id (format "%s-%s" (format-time-string "%Y%m%dT%H%M%S")
                                 (substring (secure-hash 'sha1 (format "%s" (float-time))) 0 8))
        elmate--system-context (elmate--context-messages)
        elmate--history nil
        elmate--busy nil)
  (elmate--render-history))

(defun elmate--choose-session (root)
  "Offer saved sessions for ROOT; return selected session or nil."
  (when elmate-save-chats
    (let* ((sessions (elmate--load-saved root))
           (choices (mapcar (lambda (session)
                              (cons (format "%s — %s turns"
                                            (alist-get 'updated session)
                                            (length (alist-get 'history session)))
                                    session))
                            sessions)))
      (when choices
        (let ((choice (completing-read "Resume saved chat (or empty for new): "
                                       (cons "" (mapcar #'car choices)) nil t)))
          (cdr (assoc choice choices)))))))

(defvar elmate-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'elmate-send)
    (define-key map (kbd "C-c C-k") #'elmate-clear)
    map))

(define-derived-mode elmate-chat-mode text-mode "Elmate"
  "Major mode for Elmate chat.\n\nC-c C-c sends the prompt; C-c C-k starts a new chat."
  (setq-local buffer-read-only nil)
  (setq-local truncate-lines nil)
  (setq-local elmate--history nil)
  (setq-local elmate--busy nil)
  (use-local-map elmate-chat-mode-map)
  (markdown-mode))

;;;###autoload
(defun elmate-chat ()
  "Open the Elmate chat for the current project."
  (interactive)
  (let* ((root (file-name-as-directory (expand-file-name (elmate--project-root))))
         (buffer (get-buffer-create
                  (format "%s<%s-%s>" elmate--buffer-name
                          (file-name-nondirectory (directory-file-name root))
                          (substring (elmate--project-key root) 0 8)))))
    (pop-to-buffer buffer)
    (unless (derived-mode-p 'elmate-chat-mode)
      (elmate-chat-mode)
      (setq-local elmate--project-root root)
      (let ((session (elmate--choose-session root)))
        (if session
            (progn
              (setq-local elmate--system-context (elmate--context-messages))
              (elmate--restore session))
          (elmate--new-chat root))))))

(defun elmate--append-before-prompt (text &optional face)
  "Insert TEXT immediately before the prompt, optionally using FACE."
  (let ((inhibit-read-only t))
    (goto-char elmate--prompt-marker)
    (insert (propertize text 'read-only t 'face face))
    (set-marker elmate--prompt-marker (point))
    (goto-char (point-max))))

(defun elmate-send ()
  "Send the text after the prompt to the configured model."
  (interactive)
  (unless (derived-mode-p 'elmate-chat-mode)
    (user-error "Not in an Elmate chat buffer"))
  (when elmate--busy (user-error "A response is already in progress"))
  (let ((prompt (string-trim
                 (buffer-substring-no-properties elmate--prompt-marker (point-max)))))
    (unless (string-empty-p prompt)
      (setq elmate--history
            (append elmate--history (list `((role . "user") (content . ,prompt)))))
      (let ((inhibit-read-only t))
        (goto-char elmate--prompt-marker)
        (delete-region elmate--prompt-marker (point-max))
        (insert (propertize (concat "You\n" prompt "\n\n") 'read-only t))
        (insert (propertize "Assistant\n" 'face 'bold 'read-only t))
        (setq elmate--reply-marker (copy-marker (point) nil))
        (insert (propertize "\n" 'read-only t))
        (elmate--insert-prompt))
      (setq elmate--busy t elmate--retry-count 0
            buffer-read-only t)
      (elmate--start-indicator)
      (elmate--save)
      (elmate--request))
    (goto-char (point-max))))

(defun elmate-clear ()
  "Start a new empty chat in this buffer."
  (interactive)
  (when elmate--busy (user-error "Cannot clear a chat while a response is in progress"))
  (elmate--save)
  (elmate--new-chat elmate--project-root))

(defun elmate--restore-prompt-state ()
  "Re-enable editing after a request finishes or fails."
  (elmate--stop-indicator)
  (setq elmate--busy nil)
  (setq buffer-read-only nil))

(defun elmate--request ()
  "Start the asynchronous streaming chat request."
  (let* ((messages (append (list `((role . "system") (content . ,elmate--system-context)))
                           elmate--history))
         (payload `((model . ,elmate-model)
                    (messages . ,(vconcat messages))
                    (stream . t)))
         (url-request-method "POST")
         (url-request-extra-headers
          `(("Content-Type" . "application/json")
            ("Authorization" . ,(concat "Bearer " (elmate--auth-token)))
            ("Accept" . "text/event-stream")))
         (url-request-data (encode-coding-string (json-encode payload) 'utf-8))
         (url-show-status nil)
         (chat (current-buffer)))
    (condition-case err
        (let ((request-buffer
               (url-retrieve (elmate--completion-url elmate-api-url)
                             #'elmate--request-finished (list chat) t t)))
          (when (buffer-live-p request-buffer)
            (setq elmate--request-buffer request-buffer)
            (with-current-buffer request-buffer
              (setq-local elmate--chat-buffer chat)
              (setq-local elmate--streaming t)
              (setq-local elmate--event-marker nil)
              (setq-local elmate--event-data "")
              (add-hook 'after-change-functions #'elmate--request-buffer-changed nil t))))
      (error (elmate--request-failed (error-message-string err))))))

(defun elmate--request-buffer-changed (&rest _ignored)
  "Parse newly decoded SSE text as URL retrieval receives it."
  (when (and elmate--streaming (boundp 'url-http-end-of-headers)
             (markerp url-http-end-of-headers))
    (unless elmate--event-marker
      (setq elmate--event-marker (copy-marker url-http-end-of-headers)))
    (save-excursion
      (goto-char elmate--event-marker)
      (while (search-forward "\n" nil t)
        (let ((line (string-trim-right
                     (buffer-substring-no-properties (marker-position elmate--event-marker)
                                                     (1- (point))) "\r")))
          (set-marker elmate--event-marker (point))
          (cond
           ((string-empty-p line) (elmate--dispatch-event))
           ((string-prefix-p "data:" line)
            (setq elmate--event-data
                  (concat elmate--event-data
                          (if (string-empty-p elmate--event-data) "" "\n")
                          (string-trim-left (substring line 5)))))))))))

(defun elmate--dispatch-event ()
  "Dispatch the accumulated server-sent event."
  (unless (string-empty-p elmate--event-data)
    (unless (equal elmate--event-data "[DONE]")
      (condition-case err
          (let* ((object (json-parse-string elmate--event-data :object-type 'alist
                                            :array-type 'list))
                 (choice (car (alist-get 'choices object)))
                 (delta (alist-get 'delta choice))
                 (text (alist-get 'content delta)))
            (when (stringp text) (elmate--append-delta text)))
        (error
         (let ((chat elmate--chat-buffer))
           (when (buffer-live-p chat)
             (with-current-buffer chat
               (elmate--request-failed (format "Invalid streaming response: %s" err))))))))
    (setq elmate--event-data "")))

(defun elmate--start-indicator ()
  "Show animated working feedback before the assistant reply."
  (elmate--stop-indicator)
  (let ((inhibit-read-only t)
        (position (marker-position elmate--reply-marker)))
    (setq elmate--indicator-frame 1
          elmate--indicator-start (copy-marker position nil)
          elmate--indicator-end (copy-marker position t))
    (goto-char position)
    (insert (propertize "Thinking." 'face 'shadow 'read-only t))
    (set-marker elmate--indicator-end (point))
    (set-marker elmate--reply-marker (point))
    (setq elmate--indicator-timer
          (run-at-time 0.45 0.45 #'elmate--animate-indicator (current-buffer)))))

(defun elmate--animate-indicator (buffer)
  "Advance the animated indicator in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and elmate--busy (markerp elmate--indicator-start)
                 (markerp elmate--indicator-end))
        (let* ((dots (1+ (% elmate--indicator-frame 3)))
               (text (concat "Thinking" (make-string dots ?.)))
               (inhibit-read-only t)
               (start (marker-position elmate--indicator-start)))
          (delete-region start elmate--indicator-end)
          (goto-char start)
          (insert (propertize text 'face 'shadow 'read-only t))
          (set-marker elmate--indicator-end (point))
          (set-marker elmate--reply-marker (point))
          (setq elmate--indicator-frame (1+ elmate--indicator-frame)))))))

(defun elmate--stop-indicator ()
  "Cancel animation and remove its pending text, if present."
  (when (timerp elmate--indicator-timer)
    (cancel-timer elmate--indicator-timer))
  (setq elmate--indicator-timer nil)
  (when (and (markerp elmate--indicator-start)
             (marker-position elmate--indicator-start)
             (markerp elmate--indicator-end)
             (marker-position elmate--indicator-end))
    (let ((inhibit-read-only t)
          (position (marker-position elmate--indicator-start)))
      (delete-region position elmate--indicator-end)
      (when (markerp elmate--reply-marker)
        (set-marker elmate--reply-marker position))))
  (when (markerp elmate--indicator-start) (set-marker elmate--indicator-start nil))
  (when (markerp elmate--indicator-end) (set-marker elmate--indicator-end nil))
  (setq elmate--indicator-start nil elmate--indicator-end nil))

(defun elmate--append-delta (text)
  "Append streamed TEXT to the assistant reply."
  (let ((chat elmate--chat-buffer))
    (when (buffer-live-p chat)
      (with-current-buffer chat
        (elmate--stop-indicator)
        (let ((inhibit-read-only t)
              (end (marker-position elmate--reply-marker)))
          (goto-char end)
          (insert (propertize text 'read-only t))
          (set-marker elmate--reply-marker (+ end (length text)))
          (goto-char (point-max))
          (font-lock-ensure))))))

(defun elmate--request-finished (status chat)
  "Handle completed URL retrieval with STATUS for CHAT."
  (let* ((request-buffer (current-buffer))
         (http-status (buffer-local-value 'url-http-response-status request-buffer))
         (body (with-current-buffer request-buffer
                 (when (and (boundp 'url-http-end-of-headers)
                            (markerp url-http-end-of-headers))
                   (buffer-substring-no-properties url-http-end-of-headers (point-max))))))
    (unwind-protect
        (cond
         ((and (integerp http-status)
               (not (and (>= http-status 200) (< http-status 300))))
          (when (buffer-live-p chat)
            (with-current-buffer chat
              (elmate--request-failed
               (format "HTTP %s: %s" http-status
                       (string-trim
                        (substring (or body "") 0 (min 500 (length (or body ""))))))))))
         ((plist-get status :error)
          (when (buffer-live-p chat)
            (with-current-buffer chat
              (elmate--request-failed (format "%s" (plist-get status :error))))))
         (t
          (with-current-buffer request-buffer (elmate--request-buffer-changed))
          (when (buffer-live-p chat)
            (with-current-buffer chat
              (elmate--stop-indicator)
              (let* ((prompt-start (- (marker-position elmate--prompt-marker) 2))
                     (answer (buffer-substring-no-properties elmate--reply-marker prompt-start)))
                (when elmate--reply-marker
                  (put-text-property (marker-position elmate--reply-marker)
                                     prompt-start 'read-only t))
                (setq elmate--history
                      (append elmate--history
                              (list `((role . "assistant")
                                      (content . ,(string-trim answer))))))
                (elmate--restore-prompt-state)
                (elmate--save))))))
      (when (buffer-live-p request-buffer) (kill-buffer request-buffer)))))

(defun elmate--request-failed (message)
  "Log MESSAGE and retry once; on a second failure show it in chat."
  (setq elmate--busy t)
  (if (< (or elmate--retry-count 0) 1)
      (progn
        (let ((inhibit-read-only t)
              (prompt-start (- (marker-position elmate--prompt-marker) 2)))
          (elmate--stop-indicator)
          (delete-region elmate--reply-marker prompt-start)
          (set-marker elmate--reply-marker (marker-position elmate--reply-marker)))
        (setq elmate--retry-count (1+ elmate--retry-count))
        (with-current-buffer (get-buffer-create elmate--warnings-buffer)
          (goto-char (point-max))
          (insert (format-time-string "%FT%T%z ") "Elmate: " message "\n"))
        (display-buffer elmate--warnings-buffer)
        (elmate--start-indicator)
        (elmate--request))
    (elmate--append-before-prompt (format "\n[Elmate error: %s]\n" message) 'error)
    (elmate--restore-prompt-state)
    (elmate--save)
    (message "Elmate request failed after retry: %s" message)))

(provide 'elmate)
;;; elmate.el ends here

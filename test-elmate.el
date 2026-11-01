;;; test-elmate.el --- Tests for Elmate -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'elmate)

(ert-deftest elmate-chat-buffer-has-editable-prompt ()
  (with-temp-buffer
    (elmate-chat-mode)
    (should (eq major-mode 'elmate-chat-mode))
    (should (derived-mode-p 'markdown-mode))
    (should (eq (key-binding (kbd "C-c C-c")) #'elmate-send))
    (setq major-mode 'elmate-chat-mode
          elmate--project-root default-directory)
    (elmate--new-chat default-directory)
    (goto-char (point-max))
    (should (eq (key-binding (kbd "x")) #'self-insert-command))
    (should (eq (key-binding (kbd "q")) #'self-insert-command))
    (dolist (ch (string-to-list "hello"))
      (let ((last-command-event ch)
            (cmd (key-binding (vector ch))))
        (should (commandp cmd))
        (call-interactively cmd)))
    (should (equal (buffer-substring-no-properties elmate--prompt-marker (point-max))
                   "hello"))
    (should-not buffer-read-only)
    (should-not (get-text-property (marker-position elmate--prompt-marker) 'read-only))
    (goto-char (point-max))
    (let ((last-command-event ?x))
      (call-interactively #'self-insert-command))
    (should (equal (buffer-substring-no-properties elmate--prompt-marker (point-max))
                   "hellox"))))

(ert-deftest elmate-send-locks-buffer-during-request ()
  (with-temp-buffer
    (elmate-chat-mode)
    (setq major-mode 'elmate-chat-mode
          elmate--project-root default-directory)
    (elmate--new-chat default-directory)
    (goto-char (point-max))
    (insert "test")
    (cl-letf (((symbol-function 'elmate--request) (lambda nil nil)))
      (elmate-send))
    (should elmate--busy)
    (should buffer-read-only)
    (elmate--restore-prompt-state)
    (should-not elmate--busy)
    (should-not buffer-read-only)
    (let ((last-command-event ?x))
      (call-interactively #'self-insert-command))
    (should (string-match-p "> x" (buffer-string)))))

(ert-deftest elmate-prompt-stays-editable-after-font-lock ()
  "Markdown font-lock must not make text typed after the prompt read-only."
  (with-temp-buffer
    (elmate-chat-mode)
    (setq major-mode 'elmate-chat-mode
          elmate--project-root default-directory)
    (elmate--new-chat default-directory)
    (font-lock-ensure)
    (goto-char (point-max))
    (dolist (ch (string-to-list "abc"))
      (let ((last-command-event ch))
        (call-interactively #'self-insert-command)))
    (should (equal (buffer-substring-no-properties elmate--prompt-marker (point-max))
                   "abc"))))

(ert-deftest elmate-prompt-editable-after-send-and-response ()
  "The fresh prompt after a send is editable, and the old transcript is not."
  (with-temp-buffer
    (elmate-chat-mode)
    (setq major-mode 'elmate-chat-mode
          elmate--project-root default-directory)
    (elmate--new-chat default-directory)
    (goto-char (point-max))
    (insert "first")
    (cl-letf (((symbol-function 'elmate--request) (lambda nil nil)))
      (elmate-send))
    (elmate--restore-prompt-state)
    (font-lock-ensure)
    (goto-char (point-max))
    (let ((last-command-event ?x))
      (call-interactively #'self-insert-command))
    (should (equal (buffer-substring-no-properties elmate--prompt-marker (point-max))
                   "x"))
    (should-error (progn (goto-char (+ (point-min) 3))
                         (let ((last-command-event ?z))
                           (call-interactively #'self-insert-command)))
                  :type 'text-read-only)))

(ert-deftest elmate-completion-url-appends-route-to-base-url ()
  (should (equal (elmate--completion-url "https://router.requesty.ai/v1")
                 "https://router.requesty.ai/v1/chat/completions")))

(ert-deftest elmate-completion-url-preserves-full-endpoint-and-query ()
  (should (equal (elmate--completion-url
                  "https://api.example/v1/chat/completions?key=value")
                 "https://api.example/v1/chat/completions?key=value"))
  (should (equal (elmate--completion-url "https://api.example/v1/?key=value")
                 "https://api.example/v1/chat/completions?key=value")))

(ert-deftest elmate-context-includes-agents-when-present ()
  (let* ((root (make-temp-file "elmate-context" t))
         (elmate-system-prompt "base")
         (elmate-include-agents-md t))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "AGENTS.md" root) (insert "use tests"))
          (let ((elmate--project-root root))
            (should (string-match-p "use tests" (elmate--context-messages)))))
      (delete-directory root t))))

(ert-deftest elmate-sse-stream-parses-delta-and-done ()
  (let ((chat (generate-new-buffer " *elmate-chat-test*"))
        (request (generate-new-buffer " *elmate-stream-test*")))
    (unwind-protect
        (progn
          (with-current-buffer chat
            (elmate-chat-mode)
            (setq-local elmate--project-root default-directory)
            (elmate--new-chat default-directory)
            (let ((inhibit-read-only t))
              (goto-char elmate--prompt-marker)
              (insert "\n> ")
              (setq elmate--reply-marker (copy-marker (point-min) nil))))
          (with-current-buffer request
            (setq-local elmate--chat-buffer chat)
            (setq-local elmate--event-data "")
            (elmate--dispatch-event))
          (with-current-buffer request
            (setq-local elmate--event-data
                        "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}")
            (elmate--dispatch-event)
            (should (with-current-buffer chat
                      (string-match-p "hello" (buffer-string)))))
          (with-current-buffer request
            (setq-local elmate--event-data "[DONE]")
            (elmate--dispatch-event)
            (should (equal elmate--event-data "")))
      (when (buffer-live-p chat) (kill-buffer chat))
      (when (buffer-live-p request) (kill-buffer request))))))

(ert-deftest elmate-working-indicator-animates-and-cleans-up-on-streaming ()
  (let ((chat (generate-new-buffer " *elmate-indicator-test*"))
        (request (generate-new-buffer " *elmate-indicator-request-test*")))
    (unwind-protect
        (progn
          (with-current-buffer chat
            (insert "Assistant\n")
            (setq-local elmate--reply-marker (copy-marker (point) nil)
                        elmate--busy t)
            (elmate--start-indicator)
            (should (timerp elmate--indicator-timer))
            (should (string-match-p "Thinking\\." (buffer-string)))
            (elmate--animate-indicator chat)
            (should (string-match-p "Thinking\\.\\." (buffer-string))))
          (with-current-buffer request
            (setq-local elmate--chat-buffer chat)
            (with-current-buffer chat
              (setq-local elmate--busy t))
            (elmate--append-delta "hello"))
          (with-current-buffer chat
            (should-not elmate--indicator-timer)
            (should-not (string-match-p "Thinking" (buffer-string)))
            (should (string-match-p "hello" (buffer-string)))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (elmate--stop-indicator))
        (kill-buffer chat))
      (when (buffer-live-p request) (kill-buffer request)))))

(ert-deftest elmate-working-indicator-is-removed-on-request-termination ()
  (with-temp-buffer
    (insert "Assistant\n")
    (setq-local elmate--reply-marker (copy-marker (point) nil)
                elmate--busy t)
    (elmate--start-indicator)
    (elmate--restore-prompt-state)
    (should-not elmate--busy)
    (should-not elmate--indicator-timer)
    (should-not (string-match-p "Thinking" (buffer-string)))))

(ert-deftest elmate-session-round-trip-json-shape ()
  (let* ((root (make-temp-file "elmate-project" t))
         (elmate-chat-directory (make-temp-file "elmate-store" t))
         (elmate-save-chats t)
         (chat (generate-new-buffer " *elmate-save-test*")))
    (unwind-protect
        (with-current-buffer chat
          (elmate-chat-mode)
          (setq-local elmate--project-root root
                      elmate--chat-id "session-1"
                      elmate--history '(((role . "user") (content . "question"))))
          (elmate--save)
          (let ((saved (elmate--load-saved root)))
            (should (equal (alist-get 'id (car saved)) "session-1"))
            (should (equal (alist-get 'content
                                      (car (alist-get 'history (car saved))))
                           "question"))))
      (when (buffer-live-p chat) (kill-buffer chat))
      (delete-directory root t)
      (delete-directory elmate-chat-directory t))))

(ert-deftest elmate-http-error-includes-response-body ()
  (let ((chat (generate-new-buffer " *elmate-chat-error-test*"))
        (request (generate-new-buffer " *elmate-http-error-test*"))
        captured)
    (unwind-protect
        (progn
          (with-current-buffer chat
            (elmate-chat-mode))
          (with-current-buffer request
            (insert "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n")
            (setq-local url-http-response-status 400)
            (setq-local url-http-end-of-headers (copy-marker (point)))
            (insert "{\"error\":{\"message\":\"Invalid model ID\"}}")
            (cl-letf (((symbol-function 'elmate--request-failed)
                       (lambda (msg) (setq captured msg))))
              (elmate--request-finished '(:error (error http 400)) chat)))
          (should (equal captured
                         "HTTP 400: {\"error\":{\"message\":\"Invalid model ID\"}}")))
      (when (buffer-live-p chat) (kill-buffer chat))
      (when (buffer-live-p request) (kill-buffer request)))))

(provide 'test-elmate)
;;; test-elmate.el ends here

;;; test-elmate.el --- Tests for Elmate -*- lexical-binding: t; -*-

(require 'ert)
(require 'elmate)

(ert-deftest elmate-chat-buffer-has-editable-prompt ()
  (with-temp-buffer
    (elmate-chat-mode)
    (setq-local elmate--project-root default-directory)
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
                   "hello"))))

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

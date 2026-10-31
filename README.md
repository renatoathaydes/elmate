# Elmate

A small Emacs chat mode for OpenAI-compatible chat completions.

## Install

Put `elmate.el` on your `load-path` and add:

```elisp
(require 'elmate)
(global-set-key (kbd "C-c e") #'elmate-chat)
```

Run `M-x elmate-chat` in a project to open its chat buffer. Type at the bottom and press `C-c C-c` to send. Press `C-c C-k` to clear the current conversation. Responses stream into the buffer.

## Configure

```elisp
(setq elmate-api-url "https://api.openai.com/v1/chat/completions"
      elmate-model "gpt-4o-mini"
      elmate-system-prompt "You are a helpful assistant.")
```

Set `elmate-api-url` to either an OpenAI-compatible API base URL (for example, `https://router.requesty.ai/v1`) or a full chat completions URL. Elmate appends `/chat/completions` when it is not already present. Store credentials in Emacs `auth-source`, for example in `~/.authinfo.gpg`:

```text
machine api.openai.com login apikey password YOUR_API_KEY
```

For a custom host, replace `api.openai.com` (and set `elmate-model` to a model ID accepted by that provider, such as `"openai/gpt-4o-mini"` for routers like Requesty). Set `elmate-include-agents-md` to nil to disable loading the project's `AGENTS.md` as context.

## Optional local persistence

Set `elmate-save-chats` to non-nil to persist conversation histories under `elmate-chat-directory` (default: `elmate/chats/` under `user-emacs-directory`). The data is grouped by project root; opening a new chat buffer offers saved sessions to resume. Saved chat files contain prompts and model replies, so consider their sensitivity. Persistence is off by default.

## Development

Run tests with:

```sh
emacs -Q --batch -L . -l test-elmate.el -f ert-run-tests-batch-and-exit
```

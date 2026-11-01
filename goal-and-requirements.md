---
id: elmate-goal
type: goal-and-requirements
title: Emacs AI Assistance Mode
status: active
tags: [product]
---

# Emacs AI Assistance Mode

Keep AI assistance available inside Emacs without interrupting editing.

## Overview

A small Emacs mode for personal AI assistance. Its initial experience is a chat buffer: the user enters prompts at the bottom and sees streamed model replies above. The initial provider is the OpenAI chat API, with a configurable API URL and model.

## Problem

Getting AI help currently means leaving Emacs or using a separate chat, interrupting editing work.

## Capabilities

- Open a chat buffer with the current project's `AGENTS.md` file as initial context when present, plus a small configurable system prompt.
- Send prompts with earlier turns from the same buffer as conversation context and display model responses progressively as they arrive.
- Show animated “Thinking…” feedback beneath the assistant label while a response is pending, including before the first streamed token; remove it when the response starts or the request ends.
- Configure the API URL and model. Store the API key using an environment variable or a standard Emacs secret source rather than ordinary customization settings.
- Keep conversations in the buffer by default; local persistence is opt-in. When opening a project chat buffer, offer to resume a locally stored chat or start a new one.
- On an API error, report the first failure in the warnings buffer and retry once automatically; if the retry also fails, show an error in the chat buffer and stop.

## Non-Goals

- Inline prompts on arbitrary files and other deeply integrated editor features are outside the initial scope.
- Agent tools that perform actions inside Emacs are outside the initial scope.
- Persistent conversation storage is not enabled by default.

## Tech Notes

- Platform: Emacs.
- Initial API: OpenAI-compatible chat completions; `elmate-api-url` accepts either a provider base URL (such as `https://router.requesty.ai/v1`) or the full `/chat/completions` endpoint.
- The `llm` Emacs package (https://github.com/ahyatt/llm) may be used where helpful as a lower-level helper; its other providers are not part of the initial user-facing scope.

## Alternatives Considered

- [`llm`](https://github.com/ahyatt/llm) — a lower-level Emacs library for interacting with LLMs; useful as a helper, but not itself the focused chat-buffer mode described here.

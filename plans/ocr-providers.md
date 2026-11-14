# OCR providers — wire contracts, security, queue

## 1. Adapters

| Preset | Kind | Endpoint | Image format |
|---|---|---|---|
| OpenAI | `openAI` | `{base}/responses` | `input_image` with data URL (+ `detail`) |
| Anthropic | `anthropic` | `{base}/messages` | base64 `source` block; `x-api-key` + `anthropic-version: 2023-06-01` |
| DeepInfra | `openAICompatible` | `https://api.deepinfra.com/v1/openai/chat/completions` | `image_url` data URL |
| Z.ai | `openAICompatible` | `https://api.z.ai/api/paas/v4/chat/completions` | `image_url` data URL |
| Custom | `openAICompatible` | user-configured base | same as above |

Model IDs are always editable. The Suggested menu lists known vision
models only; DeepSeek text models are deliberately excluded — DeepInfra's
general vision support does not establish image capability for a
user-chosen DeepSeek id. The synthetic probe decides capability for the
exact profile+model.

References (rechecked at implementation):
- OpenAI images/vision: https://developers.openai.com/api/docs/guides/images-vision
- Anthropic vision: https://platform.claude.com/docs/en/build-with-claude/vision
  and https://platform.claude.com/docs/en/api/messages
- DeepInfra: https://docs.deepinfra.com/chat/overview and
  https://docs.deepinfra.com/chat/vision (base
  `https://api.deepinfra.com/v1/openai`)
- Z.ai: https://docs.z.ai/api-reference/llm/chat-completion and
  https://docs.z.ai/guides/vlm/glm-4.5v

## 2. Request discipline

- Nonstreaming, one page per request, no tools/functions ever sent.
- The OCR prompt is fixed and versioned (`PromptVersion`); jobs record the
  version they were enqueued with.
- Page content is transcription input in the user message — never
  instructions — and only locally rendered PNG bytes are sent; the app
  never fetches provider-supplied remote image URLs.
- Strict response parsing with size limits; empty/malformed/echo-error
  responses are failures, never "successful empty OCR". The prompt asks
  for `[unreadable]` markers instead of invented content.

## 3. Endpoint & credential security

- HTTPS everywhere; plain HTTP only for loopback hosts.
- URLs with userinfo or credential-like query parameters are rejected.
- Redirects may not cross origins or leave HTTPS; the key is never
  forwarded to another host. Enforced in BOTH the runner and the
  URLSession transport (defense in depth), and the transport strips
  server-injected headers on redirect.
- No global ATS weakening.
- API keys live only in the Keychain (`dev.booxbridge.app.providerkey`
  service, keyed by profile id). Keys are redacted from every error/log
  path (`Redaction`); tests assert secrets never reach the catalog
  database, job error text, or UserDefaults.
- Changing a key/endpoint does not silently reuse an old secret for a new
  host: each profile stores its own key, and editing base URL requires
  re-entering the key.

## 4. Capability probing

`probeImageCapability` sends one tiny synthetic 1×1 PNG with the prompt
"Reply with the single word OK." — never a page from the user's notes.
Outcomes: verified (2xx + parsable), rejected-auth (401/403),
rejected-image (400/404/415/422), rejected-endpoint (policy), or network
failure. Results are per exact profile+model and shown in Settings.

## 5. Durable queue

- Jobs are rows in the catalog with identity (revision, page, profile,
  model, prompt version) — duplicate enqueues are no-ops.
- States: queued → running → succeeded | failed | cancelled. Launch
  recovery marks interrupted `running` jobs as failed with "interrupted by
  app restart" — paid work is never silently restarted.
- Concurrency 1. Retry classification (`RetryPolicy`): 429 honors
  Retry-After (capped); 408/5xx exponential backoff (base 2s, cap 120s);
  permanent 4xx fails immediately; attempts bounded (default 4).
- Late-response isolation: the runner checks that the job's revision is
  still the document's current revision BEFORE sending and again BEFORE
  committing — a stale result is discarded and the job fails with an
  explicit reason.
- OCR output lands in `raw_transcription`; `effective_text` is only filled
  when the page has never been edited, so user edits always survive
  re-OCR. FTS reindexes transactionally after every change.

## 6. Cost/privacy disclosure

The consent sheet names provider, model, and page count and states that
requests may bill and pages leave the Mac. Cancelling notes that an
in-flight request may already have been billed.

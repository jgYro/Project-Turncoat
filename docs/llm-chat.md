# LLM chat and source inspection

Project Turncoat adds a **Chat** tab for an OpenAI-compatible model server and
an expandable JSON inspector for graph source properties. Chat can include an
explicitly selected graph record, paper, or patent with extracted PDF text.

## Behavior

- **Ask in chat** on a graph node opens Chat with that node attached. The record
  is loaded from the local SQLite dataset and can be inspected before sending.
- Expandable JSON objects and arrays show value types, item counts, and original
  Chinese text. Copy JSON preserves the entire original value.
- The model receives the conversation and attachment when **Send message** or
  **AI Analysis** is pressed. Chat has no search tools and does not change graph records.
- Replies are model output. Source text remains intact; translations or inferred
  explanations are separate from the original record.
- Chat history stays in this browser tab's session storage. New chat clears it.
  Graph data remains in SQLite. This phase does not persist chat in SQLite.
- **AI Analysis** on arXiv and patent search results or in the document reader starts a separate review conversation
  and submits a prepared prompt automatically, with available PDF text. The review
  covers evidence scope, a summary, named people and organizations, key details,
  limitations, and suggested follow-up questions. Original names are preserved.
  Missing PDFs or extraction failures produce an explicitly labeled metadata-only
  review. Inference failures retain the question for a manual retry.
  A tab-local, single-use intent ties automatic submission to the button click;
  loading or refreshing a chat URL does not issue another analysis. Existing
  manual conversations remain separate. Browser session storage must be available.
- The interface shows the configured endpoint/model, pending requests, usage
  when supplied, and actionable connection errors. Replies arrive as completed
  messages; token streaming is not part of this initial API.
- While waiting, an assistant card shows the actual preparation/request stage
  and elapsed time. It does not estimate completion percentages. User questions
  use warm, right-aligned bubbles; AI replies use cyan, left-aligned cards.
  Automatic review instructions can be expanded from a compact request card.
- AI replies render Markdown headings, emphasis, lists, quotes, tables, links,
  and code blocks. Copy reply keeps the original Markdown; code blocks have
  their own copy action. Existing session history uses the same renderer.

## Connection

Default model: `granite4.1:8b` (the Ollama ID for IBM's 4.1 instruction model).
Default OpenAI-compatible base URL: `http://127.0.0.1:11434/v1`.
The app is an inference client; it does not install or run model weights.

For Ollama, run `ollama pull granite4.1:8b` and start `ollama serve` if it is not
already running. Start Project Turncoat normally and use **Check connection**.
The application never silently substitutes a different model.

For vLLM or another server, set its OpenAI-compatible base URL and exact served
model ID before starting Project Turncoat. For example:

```sh
export TURNCOAT_LLM_BASE_URL=http://127.0.0.1:8000/v1
export TURNCOAT_LLM_MODEL=ibm-granite/granite-4.1-8b
./bin/turncoat serve
```

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `TURNCOAT_LLM_BASE_URL` | `http://127.0.0.1:11434/v1` | Base URL; `/chat/completions` or `/models` is appended |
| `TURNCOAT_LLM_MODEL` | `granite4.1:8b` | Exact model ID served by the endpoint |
| `TURNCOAT_LLM_API_KEY` | empty | Optional server-side Bearer credential |
| `TURNCOAT_LLM_TIMEOUT_MS` | `120000` | Whole request timeout, at most 600000 ms |
| `TURNCOAT_LLM_MAX_TOKENS` | `2048` | Output token cap, 1..8192 |
| `TURNCOAT_LLM_CONCURRENCY` | `2` | Concurrent inference/model-list requests, 1..4 |

Configuration is loaded at startup. Restart after changes. Use HTTPS for remote
servers. Base URLs cannot contain embedded credentials, queries, or fragments.
Keys are never returned in configuration or reflected from upstream errors.
The public configuration shows the endpoint so users can see where their text
will go. There are no automatic retries. Opening or refreshing a chat URL alone
does not trigger inference; automatic reviews require the AI Analysis button.

The client uses `messages`, `model`, `max_tokens`, `temperature: 0.2`, and
`stream: false`. It reads `choices[0].message.content`, `finish_reason`, and
optional `usage`. Compatibility here means this Chat Completions subset; models
requiring different parameters or non-text output need an adapter change.

## Document reader and PDF context

Search-result titles, patent records, and PDF buttons open `/document` in the app.
The source record is retrieved through the existing paced Google Patents/arXiv
clients. When opened from a saved graph node, its metadata is reused without an
upstream lookup. Saved search snippets are explicitly labeled as potentially
incomplete. Document identifiers and dataset membership must match that node.
Google patent web pages can restrict framing; **Record** uses their
parsed public metadata. **PDF** embeds the source PDF in the browser's PDF viewer
through a restricted same-origin PDF endpoint. **Original source/PDF** remain
available for browsers without embedded PDF support.

Only validated arXiv/publication IDs are accepted, never arbitrary user URLs.
PDF retrieval accepts HTTPS PDF URLs from arxiv.org, export.arxiv.org, and
patentimages.storage.googleapis.com, rechecking up to three redirects. It limits
files to 16 MB, downloads to 30 seconds, and PDF operations to one at a time with
three seconds between downloads. A bounded 16-document process cache uses a
temporary directory. It is not a permanent document archive; a restart requires
retrieval again. Graph records and their raw properties remain in SQLite.

**Extracted text** runs Poppler `pdftotext` using process arguments, without a
shell, with a 20-second extraction timeout. It reads up to the first 40 pages,
then takes at most 32000 UTF-8 bytes without splitting characters. It preserves
the extracted text and labels the limits. It does not OCR scanned pages, describe
figures, or infer anything from the PDF viewer's pixels.

Choose **AI Analysis** to submit a document review immediately, or choose
**Ask about this document**, then **Include extracted PDF text** before
the first message to attach this extract. The checkbox locks once a conversation
begins; New chat allows changing the context. Metadata stays available if PDF
download or extraction fails. Such failures are shown and never replaced with
fabricated document text.

## API

JSON POST requests require the `X-Turncoat-Token` meta value from `/chat`,
`/document`, or `/graph`. It changes when the server restarts. No caller can
override the server's model, key, endpoint, or system instructions.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/llm/config` | Public endpoint, model, and limits; no key |
| POST | `/api/llm/check` | Check `/models` and whether the configured model is listed |
| POST | `/api/llm/context` | Preview one graph or document context reference |
| POST | `/api/llm/chat` | Complete the supplied conversation with optional context |
| POST | `/api/documents/record` | Retrieve document metadata |
| POST | `/api/documents/prepare-pdf` | Download/cache a supported PDF for the viewer |
| GET | `/api/documents/pdf?source=…&id=…` | Serve a previously prepared PDF inline (no network retrieval) |
| POST | `/api/documents/text` | Retrieve/extract a bounded PDF text sample |
| GET | `/docs/llm-chat.md` | This guide as plain text |

Chat request with a graph attachment:

```json
{
  "messages": [{"role": "user", "content": "Explain this record."}],
  "context": {"dataset": "inv-example", "node": "inv-example:patent:example"}
}
```

For a document, context is `{"source":"patents","id":"US20230050445A1",
"includePdf":true}` or `{"source":"arxiv","id":"1706.03762v7"}`. Omit context
or set it to null for general chat. Document endpoints use the same source/id
object. Add `dataset` and `node` to reuse a saved graph record. Graph attachments
are loaded only from their specified SQLite dataset.

Each request accepts 1..24 alternating user/assistant messages, beginning and
ending with user text; at most 16000 UTF-8 bytes per message and 64000 bytes total.
JSON request bodies are limited to 128000 bytes; context to 48000 bytes. Oversized
records are rejected rather than silently losing fields. The assistant receives
a fixed system instruction identifying source JSON as untrusted data. It has no
tools and cannot write back to the graph. Markdown is tokenized by a locally
bundled markdown-it 15.0.1 and rendered into allowlisted DOM elements. Raw HTML
remains text. Links accept HTTP(S) or mailto URLs; supported document links open
the in-app reader. Images appear as links instead of loading remote content.
JSON values and code remain text nodes; model-generated HTML is never inserted.

Success returns `message`, `model`, `finishReason`, and `usage`. Errors use the
existing `{"error":{"status":…, "message":…}}` shape. 400/413 indicate invalid
or oversized input, 403 a stale/absent form token, 404 a missing record, 429 a busy
model or PDF operation, 502 an upstream/schema error, 503 an unavailable server
or extractor, and 504 a timeout. The UI retains the unsent question on errors.

## Validation

`nimble testLlm` covers model configuration, source preservation, dataset isolation,
message bounds, HTTP schema/authentication, failures, timeout recovery, concurrency,
and PDF extraction/context against synthetic local fixtures. PDF extraction
checks run when `pdftotext` is installed. `nimble testGraphHttp` exercises the
combined HappyX routes and write-token boundaries. Normal tests require no paid
API, external provider request, or model download. Browser checks cover the JSON
tree, chat history, mobile layouts, reader tabs, and source-to-chat navigation.
`tests/browser/test_ai_analysis.js` is a Playwright page function for the running
app on port 5010. It intercepts all APIs and verifies automatic patent/paper
reviews, PDF fallback, manual retry, separate history, and duplicate prevention.
`tests/browser/test_chat_presentation.js` covers loading stages and cleanup,
distinct message roles, Markdown and code copying, session history, small screens,
and hostile HTML/URL/image input with synthetic responses.

## References

- [IBM Granite 4.1 8B model card and serving example](https://huggingface.co/ibm-granite/granite-4.1-8b)
- [OpenAI Chat Completions request format](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)

The OpenAI-compatible wire format lets a Granite server handle the request.
Selecting Granite does not route requests to OpenAI's hosted model service.

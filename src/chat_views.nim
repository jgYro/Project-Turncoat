import happyx
import views

proc workspaceHead(token, script: string): TagRef =
  buildHtml:
    tMeta(name = "turncoat-token", content = attr(token))
    tLink(rel = "stylesheet", href = "/assets/json-tree.css")
    tLink(rel = "stylesheet", href = "/assets/chat.css")
    tLink(rel = "stylesheet", href = "/assets/markdown.css")
    tScript(src = "/assets/json-tree.js", "defer" = "")
    tScript(src = "/assets/pdf-context.js", "defer" = "")
    if script == "/assets/chat.js":
      tScript(src = "/assets/markdown-it.min.js", "defer" = "")
      tScript(src = "/assets/chat-markdown.js", "defer" = "")
    tScript(src = attr(script), "defer" = "")

proc renderChatPage*(token: string): TagRef =
  let content = buildHtml:
    {siteHeader("chat")}
    tMain(class = "chat-workspace", id = "results"):
      tAside(class = "chat-sidebar"):
        tP(class = "eyebrow"): "INFERENCE / 01"
        tH1: "Ask. Inspect. Understand."
        tP(class = "chat-intro"): "Read the evidence with Granite. Keep the original in view."
        tSection(class = "connection-panel"):
          tH2: "Model connection"
          tP(id = "model-name", class = "model-name"): "Loading configuration…"
          tP(id = "model-endpoint", class = "endpoint")
          tButton(id = "check-connection", "type" = "button"): "Check connection"
          tP(id = "connection-status", role = "status"): "Connection has not been checked."
          tA(href = "/chat/guide"): "Setup & API guide ↗"
        tSection(class = "context-panel"):
          tDiv(class = "section-heading"):
            tH2: "Attached context"
            tA(id = "remove-context", href = "/chat", hidden = ""): "Detach"
          tP(id = "context-title"): "No record attached"
          tP(id = "context-note", class = "muted"): "Use Ask in chat from the graph or a document to add source context."
          tA(id = "context-document", hidden = ""): "Read document →"
          tLabel(class = "pdf-option", id = "pdf-option", hidden = ""):
            tInput(id = "include-pdf", "type" = "checkbox")
            " Include extracted PDF text"
          tP(id = "pdf-context-status", class = "muted", role = "status")
          tButton(id = "retry-pdf-context", "type" = "button", hidden = ""): "Retry PDF context"
          tDiv(id = "context-tree")
      tSection(class = "conversation", "aria-label" = "LLM chat"):
        tHeader(class = "conversation-header"):
          tDiv:
            tP(class = "eyebrow"): "RESEARCH CONVERSATION"
            tH2(id = "conversation-title"): "Follow a question."
          tButton(id = "new-chat", "type" = "button"): "New chat +"
        tP(id = "analysis-status", class = "analysis-status", role = "status", hidden = "")
        tDiv(id = "messages", role = "log", "aria-label" = "Conversation", "aria-live" = "polite"):
          tDiv(id = "chat-welcome", class = "chat-welcome"):
            tSpan(class = "chat-sigil", "aria-hidden" = "true"): "✳"
            tH3: "Turn source material into understanding."
            tP: "Ask about a record, compare what it says, or translate a passage while keeping the original."
            tDiv(class = "suggestions"):
              tButton("type" = "button", "data-prompt" = "Summarize the attached record and cite the fields you used."): "Summarize this record"
              tButton("type" = "button", "data-prompt" = "Explain the Chinese names and terms in this record. Preserve each original beside any translation and mark uncertain transliterations."): "Explain original text"
              tButton("type" = "button", "data-prompt" = "What does this record establish, and what information is missing?"): "Find the missing evidence"
        tDiv(class = "chat-compose"):
          tP(id = "chat-status", role = "status"): "Ready for your question."
          tForm(id = "chat-form"):
            tLabel(class = "sr-only", "for" = "chat-input"): "Message"
            tTextarea(id = "chat-input", rows = "3", maxlength = "16000", placeholder = "Ask about the evidence…", required = "")
            tButton(id = "send-message", class = "primary-button", "type" = "submit"): "Send message ↗"
          tP(class = "chat-footnote"): "Only this conversation and its attachment are sent to the displayed endpoint. Replies are model output; source records stay unchanged."
          tP(class = "chat-footnote"): "Saved in this browser tab for this session. Ctrl/Cmd + Enter to send."
    tNoscript: "Enable JavaScript to use chat."
  pageDocument("Chat", "Ask Granite about source records in Project Turncoat.", content, workspaceHead(token, "/assets/chat.js"))

proc renderDocumentPage*(token: string): TagRef =
  let content = buildHtml:
    {siteHeader("document")}
    tMain(class = "document-workspace", id = "results"):
      tHeader(class = "document-header"):
        tDiv:
          tP(class = "eyebrow"): "DOCUMENT READER"
          tH1(id = "document-title"): "Opening source…"
          tP(id = "document-byline", class = "muted")
        tDiv(class = "document-actions"):
          tButton(id = "document-analysis", class = "primary-button", "type" = "button", hidden = "", title = "Automatically review this record and available PDF text in Chat"): "AI Analysis ✳"
          tA(id = "document-chat", hidden = ""): "Ask about this document ↗"
      tDiv(class = "document-toolbar"):
        tDiv(class = "reader-tabs", role = "tablist", "aria-label" = "Document views"):
          tButton(id = "tab-record", "type" = "button", role = "tab", "aria-selected" = "true", "aria-controls" = "view-record"): "Record"
          tButton(id = "tab-pdf", "type" = "button", role = "tab", "aria-selected" = "false", "aria-controls" = "view-pdf"): "PDF"
          tButton(id = "tab-text", "type" = "button", role = "tab", "aria-selected" = "false", "aria-controls" = "view-text"): "Extracted text"
        tA(id = "document-source", target = "_blank", rel = "noopener noreferrer", hidden = ""): "Original source ↗"
      tP(id = "document-status", role = "status"): "Loading public metadata…"
      tSection(id = "view-record", class = "reader-record", role = "tabpanel", "aria-labelledby" = "tab-record"):
        tArticle:
          tP(class = "eyebrow"): "ABSTRACT / SOURCE TEXT"
          tP(id = "document-abstract", class = "document-abstract")
          tP(class = "muted"): "This reading view contains source metadata. Open PDF for the full document."
        tAside:
          tH2: "Source record"
          tDiv(id = "document-tree")
      tSection(id = "view-pdf", role = "tabpanel", "aria-labelledby" = "tab-pdf", hidden = ""):
        tP(class = "muted"): "Use the PDF toolbar to search, zoom, or navigate pages. If your browser cannot display it, open the original PDF."
        tA(id = "pdf-original", target = "_blank", rel = "noopener noreferrer", hidden = ""): "Original PDF ↗"
        tDiv(id = "pdf-container")
      tSection(id = "view-text", role = "tabpanel", "aria-labelledby" = "tab-text", hidden = ""):
        tDiv(class = "section-heading"):
          tH2: "Text available to chat"
          tButton(id = "load-pdf-text", "type" = "button", disabled = ""): "Preparing PDF context…"
        tP(id = "text-scope", class = "muted"): "Reads up to the first 40 pages and 32000 UTF-8 bytes. Docling OCR handles scanned pages when available; figures are not interpreted."
        tPre(id = "document-text", class = "document-text")
    tNoscript: "Enable JavaScript to use the document reader."
  pageDocument("Document", "Read a patent or paper and ask questions without leaving Project Turncoat.", content, workspaceHead(token, "/assets/document.js"))

proc renderChatGuide*(): TagRef =
  let content = buildHtml:
    {siteHeader("chat-guide")}
    tMain(class = "wrap guide-page", id = "results"):
      tP(class = "eyebrow"): "CHAT / SETUP & USAGE"
      tH1: "Connect a model. Read the evidence."
      tP: "Project Turncoat uses OpenAI-compatible Chat Completions. By default it connects to Ollama at http://127.0.0.1:11434/v1 with granite4.1:8b. The model runs in your inference server."
      tH2: "Local Ollama"
      tPre: "ollama pull granite4.1:8b\nollama serve\n./bin/turncoat serve"
      tP: "If Ollama is already running, start only Project Turncoat. Use Check connection in Chat to verify the served model."
      tH2: "Another OpenAI-compatible server"
      tPre: "export TURNCOAT_LLM_BASE_URL=http://127.0.0.1:8000/v1\nexport TURNCOAT_LLM_MODEL=ibm-granite/granite-4.1-8b\n# Set TURNCOAT_LLM_API_KEY in the server environment if required.\n./bin/turncoat serve"
      tP: "Use the model ID reported by your server's /v1/models endpoint. Credentials stay on the Nim server. Restart Project Turncoat after changing configuration."
      tH2: "Read and ask"
      tP: "Choose AI Analysis in the document reader for an automatic review in a separate chat. It includes available PDF text, summarizes the document, identifies named people and organizations, and highlights missing evidence. If the PDF is unavailable, the review explicitly uses metadata only. Refreshing does not submit another review."
      tOl:
        tLi: "Open a patent or paper. Its record, PDF, and extracted text stay inside the app."
        tLi: "Choose Ask about this document, or Ask in chat on a graph node. Inspect the attached JSON tree."
        tLi: "Document PDF context prepares automatically and is included by default. Send your question when ready, or choose metadata only before the first message."
      tP: "Extraction uses embedded PDF text, with local Docling OCR for scanned pages. It reads up to 40 pages and 32000 UTF-8 bytes. OCR may misread text; figures are not interpreted. Chat answers do not modify source data or launch searches."
      tH2: "History and request limits"
      tP: "Conversations are saved in this browser tab's session storage. New chat clears them. Each request allows up to 24 alternating messages, 16000 bytes per message, 64000 bytes of conversation, and 48000 bytes of attached context. The default output limit is 2048 tokens, timeout 120 seconds, and concurrency two."
      tP:
        tA(href = "/docs/llm-chat.md"): "Complete API documentation ↓"
        " · "
        tA(href = "/chat"): "Open chat →"
  let styles = buildHtml:
    tLink(rel = "stylesheet", href = "/assets/chat.css")
  pageDocument("Chat guide", "Configure inference and document context.", content, styles)

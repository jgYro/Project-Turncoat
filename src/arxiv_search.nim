import std/[asyncdispatch, asynchttpserver, httpcore, os, strutils, json, tables, uri]
import happyx
import arxiv, arxiv_client, views
import patents, patents_client, patent_views
import institutions, institution_views
import config, investigations
import storage/sqlite
import api/service
import llm/service as llmService
import documents, chat_views

const
  css = staticRead("../public/style.css")
  themeCss = staticRead("../public/theme.css")
  fontAssets = [
    ("IBMPlexSans-Regular.woff2", staticRead("../public/fonts/IBMPlexSans-Regular.woff2")),
    ("IBMPlexSans-Medium.woff2", staticRead("../public/fonts/IBMPlexSans-Medium.woff2")),
    ("IBMPlexSans-SemiBold.woff2", staticRead("../public/fonts/IBMPlexSans-SemiBold.woff2")),
    ("IBMPlexMono-Regular.woff2", staticRead("../public/fonts/IBMPlexMono-Regular.woff2"))]
  script = staticRead("../public/app.js")
  favicon = staticRead("../public/favicon.svg")
  graphPage = staticRead("web/static/index.html")
  graphCss = staticRead("web/static/app.css")
  graphScript = staticRead("web/static/graph.js")
  d3 = staticRead("web/static/vendor/d3.v7.min.js")
  jsonTreeScript = staticRead("../public/json-tree.js")
  jsonTreeCss = staticRead("../public/json-tree.css")
  chatScript = staticRead("../public/chat.js")
  markdownLibrary = staticRead("../public/vendor/markdown-it-15.0.1.min.js")
  chatMarkdown = staticRead("../public/chat-markdown.js")
  chatCss = staticRead("../public/chat.css")
  documentScript = staticRead("../public/document.js")
  chatGuide = staticRead("../docs/llm-chat.md")

proc responseHeaders(contentType: string): HttpHeaders =
  newHttpHeaders({"Content-Type": contentType,
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "strict-origin-when-cross-origin",
    "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"})

proc serveProject*(config: AppConfig) =
  let store = openStore(config.dbPath, config.fts)
  defer: store.close()
  let client = newArxivClient(getEnv("ARXIV_API_URL", "https://export.arxiv.org/api/query"))
  let patentClient = newPatentsClient(getEnv("PATENTS_ORIGIN", "https://patents.google.com"))
  let institutionStore = newInstitutionStore(getEnv("INSTITUTIONS_FILE", "data/institutions.json"))
  let institutionToken = newInstitutionFormToken()
  let llm = newLlmClient(loadLlmConfig())
  let documentClient = newDocumentClient(client, patentClient)
  defer: documentClient.close()
  var investigationLimits = defaultInvestigationLimits()
  investigationLimits.maxNodes = min(investigationLimits.maxNodes, config.limits.maxNodes)
  investigationLimits.maxEdges = min(investigationLimits.maxEdges, config.limits.maxEdges)
  let investigations = newInvestigationManager(store, patentClient, client, investigationLimits)
  echo "Project Turncoat: http://" & config.host & ":" & $config.port
  var server = newServer(config.host, config.port)
  server.routes:

    get "/chat":
      let headers = responseHeaders("text/html; charset=utf-8")
      headers["Cache-Control"] = "no-store"
      req.answer($renderChatPage(institutionToken), Http200, headers)

    get "/chat/guide":
      req.answer($renderChatGuide(), Http200, responseHeaders("text/html; charset=utf-8"))

    get "/document":
      let headers = responseHeaders("text/html; charset=utf-8")
      headers["Cache-Control"] = "no-store"
      req.answer($renderDocumentPage(institutionToken), Http200, headers)

    get "/docs/llm-chat.md":
      req.answer(chatGuide, Http200, responseHeaders("text/plain; charset=utf-8"))

    get "/assets/json-tree.js":
      req.answer(jsonTreeScript, Http200, responseHeaders("text/javascript; charset=utf-8"))
    get "/assets/json-tree.css":
      req.answer(jsonTreeCss, Http200, responseHeaders("text/css; charset=utf-8"))
    get "/assets/chat.js":
      req.answer(chatScript, Http200, responseHeaders("text/javascript; charset=utf-8"))
    get "/assets/markdown-it.min.js":
      req.answer(markdownLibrary, Http200, responseHeaders("text/javascript; charset=utf-8"))
    get "/assets/chat-markdown.js":
      req.answer(chatMarkdown, Http200, responseHeaders("text/javascript; charset=utf-8"))
    get "/assets/chat.css":
      req.answer(chatCss, Http200, responseHeaders("text/css; charset=utf-8"))
    get "/assets/document.js":
      req.answer(documentScript, Http200, responseHeaders("text/javascript; charset=utf-8"))

    get "/api/llm/config":
      req.answer($llm.config.publicConfig(), Http200, responseHeaders("application/json; charset=utf-8"))

    post "/api/llm/{action}":
      var data: JsonNode
      try:
        if req.headers.getOrDefault("X-Turncoat-Token") != institutionToken:
          raise apiError("Refresh the chat page before sending a request.", 403)
        if req.body.len > MaxChatRequestBytes: raise apiError("Chat request is too large.", 413)
        let body = parseJson(req.body)
        case action
        of "chat": data = await llm.chat(documentClient, store, body)
        of "check": data = await llm.checkConnection()
        of "context": data = await documentClient.resolveContext(store, body)
        else: raise apiError("Unknown chat operation.", 404)
      except ApiError as error:
        statusCode = error.status; data = errorResponse(error.status, error.publicMessage).body
      except ValueError as error:
        statusCode = 400; data = errorResponse(400, error.publicMessage).body
      except CatchableError:
        statusCode = 500; data = errorResponse(500, "Chat could not complete this request.").body
      for name, value in responseHeaders("application/json; charset=utf-8"): outHeaders[name] = value
      outHeaders["Cache-Control"] = "no-store"
      return data

    post "/api/documents/{action}":
      var data: JsonNode
      try:
        if req.headers.getOrDefault("X-Turncoat-Token") != institutionToken:
          raise apiError("Refresh the document page before loading a source.", 403)
        if req.body.len > 2048: raise apiError("Document request is too large.", 413)
        let body = parseJson(req.body)
        if body.kind != JObject or body{"source"} == nil or body{"source"}.kind != JString or
            body{"id"} == nil or body{"id"}.kind != JString:
          raise newException(ValueError, "Document requests require source and id strings.")
        let source = body["source"].getStr; let id = body["id"].getStr
        case action
        of "record": data = await documentClient.resolveMetadata(store, body)
        of "text":
          discard await documentClient.resolveMetadata(store, body)
          data = await documentClient.pdfText(source, id)
        of "prepare-pdf":
          discard await documentClient.resolveMetadata(store, body)
          discard await documentClient.pdfFile(source, id)
          data = %*{"ready": true}
        else: raise apiError("Unknown document operation.", 404)
      except ApiError as error:
        statusCode = error.status; data = errorResponse(error.status, error.publicMessage).body
      except ValueError as error:
        statusCode = 400; data = errorResponse(400, error.publicMessage).body
      except CatchableError:
        statusCode = 500; data = errorResponse(500, "Could not load this document.").body
      for name, value in responseHeaders("application/json; charset=utf-8"): outHeaders[name] = value
      outHeaders["Cache-Control"] = "no-store"
      return data

    get "/api/documents/pdf":
      try:
        var params = initTable[string, string]()
        for name, value in decodeQuery(req.url.query):
          if name notin ["source", "id"] or name in params:
            raise newException(ValueError, "Invalid document parameters.")
          params[name] = value
        let path = documentClient.cachedPdfFile(params.getOrDefault("source"), params.getOrDefault("id"))
        let headers = responseHeaders("application/pdf")
        # The PDF viewer is same-origin, isolated from the app by a sandbox CSP.
        headers["Content-Security-Policy"] = "sandbox; frame-ancestors 'self'"
        headers["Content-Disposition"] = "inline; filename=\"document.pdf\""
        headers["Cache-Control"] = "private, max-age=3600"
        req.answer(readFile(path), Http200, headers)
      except ApiError as error:
        req.answer($errorResponse(error.status, error.publicMessage).body, HttpCode(error.status), responseHeaders("application/json; charset=utf-8"))
      except ValueError as error:
        req.answer($errorResponse(400, error.publicMessage).body, Http400, responseHeaders("application/json; charset=utf-8"))
      except CatchableError:
        req.answer($errorResponse(500, "Could not load the PDF.").body, Http500, responseHeaders("application/json; charset=utf-8"))

    get "/assets/theme.css":
      req.answer(themeCss, Http200, responseHeaders("text/css; charset=utf-8"))

    get "/assets/fonts/{filename}":
      var found = false
      for (name, body) in fontAssets:
        if name == filename:
          req.answer(body, Http200, responseHeaders("font/woff2"))
          found = true
          break
      if not found:
        req.answer("Font not found", Http404, responseHeaders("text/plain; charset=utf-8"))

    get "/graph":
      let headers = responseHeaders("text/html; charset=utf-8")
      headers["Cache-Control"] = "no-store"
      req.answer(graphPage.replace("__TURNCOAT_TOKEN__", institutionToken), Http200, headers)

    get "/assets/app.css":
      req.answer(graphCss, Http200, responseHeaders("text/css; charset=utf-8"))

    get "/assets/graph.js":
      req.answer(graphScript, Http200, responseHeaders("text/javascript; charset=utf-8"))

    get "/assets/d3.v7.min.js":
      req.answer(d3, Http200, responseHeaders("text/javascript; charset=utf-8"))

    post "/api/investigations":
      var data: JsonNode
      try:
        if req.headers.getOrDefault("X-Turncoat-Token") != institutionToken:
          raise apiError("Refresh the graph page before starting an investigation.", 403)
        if req.body.len > 4096: raise newException(ValueError, "Request body is too large.")
        let body = parseJson(req.body)
        let id = investigations.startInvestigation(body{"publication"}.getStr)
        data = %*{"id": id, "url": "/graph?investigation=" & id}
        statusCode = 202
      except ApiError as error:
        statusCode = error.status
        data = errorResponse(error.status, error.publicMessage).body
      except ValueError as error:
        statusCode = 400
        data = errorResponse(400, error.publicMessage).body
      for name, value in responseHeaders("application/json; charset=utf-8"):
        outHeaders[name] = value
      outHeaders["Cache-Control"] = "no-store"
      return data

    get "/api/investigations":
      outHeaders["Content-Type"] = "application/json; charset=utf-8"
      outHeaders["Cache-Control"] = "no-store"
      return %*{"investigations": investigations.listInvestigations()}

    get "/api/investigations/{id}":
      var data: JsonNode
      try:
        data = investigations.investigationSnapshot(id)
      except ApiError as error:
        statusCode = error.status
        data = errorResponse(error.status, error.publicMessage).body
      except ValueError as error:
        statusCode = 400
        data = errorResponse(400, error.publicMessage).body
      outHeaders["Content-Type"] = "application/json; charset=utf-8"
      outHeaders["Cache-Control"] = "no-store"
      return data

    post "/api/investigations/{id}/{action}":
      var data: JsonNode
      try:
        if req.headers.getOrDefault("X-Turncoat-Token") != institutionToken:
          raise apiError("Refresh the graph page before changing an investigation.", 403)
        if req.body.len > 4096: raise newException(ValueError, "Request body is too large.")
        if action == "expand":
          let body = parseJson(req.body)
          investigations.expandInvestigation(id, body{"node"}.getStr, body{"spelling"}.getStr)
        elif action == "cancel": investigations.cancelInvestigation(id)
        else: raise apiError("Unknown investigation action.", 404)
        data = %*{"id": id}
        statusCode = 202
      except ApiError as error:
        statusCode = error.status
        data = errorResponse(error.status, error.publicMessage).body
      except ValueError as error:
        statusCode = 400
        data = errorResponse(400, error.publicMessage).body
      outHeaders["Content-Type"] = "application/json; charset=utf-8"
      outHeaders["Cache-Control"] = "no-store"
      return data

    get "/institutions":
      for name, value in responseHeaders("text/html; charset=utf-8"):
        outHeaders[name] = value
      outHeaders["Cache-Control"] = "no-store"
      return renderInstitutionsPage(institutionStore.allInstitutions(), institutionToken)

    post "/institutions":
      var message = ""
      var fields = initTable[string, string]()
      try:
        fields = institutionFormFields(req.body, institutionToken)
        institutionStore.addInstitution(fields.getOrDefault("name"),
          fields.getOrDefault("originalName"), fields.getOrDefault("assignee"))
      except ApiError as error:
        message = error.msg
        statusCode = error.status
      except ValueError as error:
        message = error.msg
        statusCode = 400
      except IOError, OSError:
        message = "Could not save the institution. Check that the app's data folder is writable."
        statusCode = 500
      for name, value in responseHeaders("text/html; charset=utf-8"):
        outHeaders[name] = value
      outHeaders["Cache-Control"] = "no-store"
      if message.len == 0:
        statusCode = 303
        outHeaders["Location"] = "/institutions#results"
        return ""
      return renderInstitutionsPage(institutionStore.allInstitutions(), institutionToken, message, fields)

    post "/institutions/remove":
      var message = ""
      try:
        let fields = institutionFormFields(req.body, institutionToken)
        institutionStore.removeInstitution(fields.getOrDefault("id"))
      except ApiError as error:
        message = error.msg
        statusCode = error.status
      except ValueError as error:
        message = error.msg
        statusCode = 400
      except IOError, OSError:
        message = "Could not save the institution list. Check that the app's data folder is writable."
        statusCode = 500
      for name, value in responseHeaders("text/html; charset=utf-8"):
        outHeaders[name] = value
      outHeaders["Cache-Control"] = "no-store"
      if message.len == 0:
        statusCode = 303
        outHeaders["Location"] = "/institutions#results"
        return ""
      return renderInstitutionsPage(institutionStore.allInstitutions(), institutionToken, message)

    get "/":
      var options = defaultOptions()
      var data = SearchResult()
      var message = ""
      try:
        options = optionsFromQuery(req.url.query)
        options.validate()
        if options.hasSearch:
          data = await client.search(options)
      except ValueError as error:
        message = error.msg
        statusCode = 400
      except ApiError as error:
        message = error.msg
        statusCode = error.status
      for name, value in responseHeaders("text/html; charset=utf-8"):
        outHeaders[name] = value
      return renderPage(options, data, message)

    get "/patents":
      var options = defaultPatentOptions()
      var data: JsonNode
      var message = ""
      try:
        options = patentOptionsFromQuery(req.url.query)
        options.validate()
        if options.hasSearch: data = await patentClient.search(options)
      except ValueError as error:
        message = error.msg
        statusCode = 400
      except ApiError as error:
        message = error.msg
        statusCode = error.status
      for name, value in responseHeaders("text/html; charset=utf-8"):
        outHeaders[name] = value
      return renderPatentPage(options, data, message)

    get "/api/patents/search":
      var data: JsonNode
      try:
        data = await patentClient.search(patentOptionsFromQuery(req.url.query))
      except ValueError as error:
        statusCode = 400
        data = patentErrorJson(400, error.msg)
      except ApiError as error:
        statusCode = error.status
        data = patentErrorJson(error.status, error.msg)
      for name, value in responseHeaders("application/json; charset=utf-8"):
        outHeaders[name] = value
      return data

    get "/api/patents/{publication}":
      var data: JsonNode
      try:
        data = await patentClient.lookup(publication)
      except ValueError as error:
        statusCode = 400
        data = patentErrorJson(400, error.msg)
      except ApiError as error:
        statusCode = error.status
        data = patentErrorJson(error.status, error.msg)
      for name, value in responseHeaders("application/json; charset=utf-8"):
        outHeaders[name] = value
      return data

    get "/assets/style.css":
      req.answer(css, Http200, responseHeaders("text/css; charset=utf-8"))

    get "/assets/app.js":
      req.answer(script, Http200, responseHeaders("text/javascript; charset=utf-8"))

    get "/favicon.svg":
      req.answer(favicon, Http200, responseHeaders("image/svg+xml"))

    get "/health":
      req.answer("ok", Http200, responseHeaders("text/plain; charset=utf-8"))

    get "/api/{rest:path}":
      let response = handlePathRequest(store, config, req.url.path, req.url.query)
      req.answer($response.body, HttpCode(response.status), responseHeaders("application/json; charset=utf-8"))

    notfound:
      req.answer($errorResponse(404, "Route not found").body, Http404,
        responseHeaders("application/json; charset=utf-8"))
  waitFor server.instance.serve(Port(config.port), handleRequest, config.host)

when isMainModule:
  serveProject(parseCommandLine(commandLineParams()).config)

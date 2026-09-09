import std/[asyncdispatch, httpcore, os, strutils, json, tables]
import happyx
import arxiv, arxiv_client, views
import patents, patents_client, patent_views
import institutions, institution_views

const
  css = staticRead("../public/style.css")
  script = staticRead("../public/app.js")
  favicon = staticRead("../public/favicon.svg")

proc responseHeaders(contentType: string): HttpHeaders =
  newHttpHeaders({"Content-Type": contentType,
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "strict-origin-when-cross-origin",
    "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"})

when isMainModule:
  let port = parseInt(getEnv("PORT", "5000"))
  if port < 1 or port > 65535: quit("PORT must be between 1 and 65535.")
  serve getEnv("HOST", "127.0.0.1"), port:
    var client = newArxivClient(getEnv("ARXIV_API_URL", "https://export.arxiv.org/api/query"))
    var patentClient = newPatentsClient(getEnv("PATENTS_ORIGIN", "https://patents.google.com"))
    var institutionStore = newInstitutionStore(getEnv("INSTITUTIONS_FILE", "data/institutions.json"))
    var institutionToken = newInstitutionFormToken()

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

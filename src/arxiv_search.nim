import std/[asyncdispatch, httpcore, os, strutils]
import happyx
import arxiv, arxiv_client, views

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

    get "/assets/style.css":
      req.answer(css, Http200, responseHeaders("text/css; charset=utf-8"))

    get "/assets/app.js":
      req.answer(script, Http200, responseHeaders("text/javascript; charset=utf-8"))

    get "/favicon.svg":
      req.answer(favicon, Http200, responseHeaders("image/svg+xml"))

    get "/health":
      req.answer("ok", Http200, responseHeaders("text/plain; charset=utf-8"))

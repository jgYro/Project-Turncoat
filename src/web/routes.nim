import std/[httpcore, asyncdispatch, asynchttpserver]
import happyx
import ../config
import ../storage/sqlite
import ../api/service

const
  page = staticRead("static/index.html")
  stylesheet = staticRead("static/app.css")
  script = staticRead("static/graph.js")
  d3 = staticRead("static/vendor/d3.v7.min.js")

proc headers(contentType: string): HttpHeaders =
  newHttpHeaders({"Content-Type": contentType, "X-Content-Type-Options": "nosniff",
    "Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"})

proc serveApp*(config: AppConfig) =
  let store = openStore(config.dbPath, config.fts)
  defer: store.close()
  echo "Graph explorer: http://" & config.host & ":" & $config.port
  var server = newServer(config.host, config.port)
  server.routes:
    get "/":
      req.answer(page, Http200, headers("text/html; charset=utf-8"))
    get "/assets/app.css":
      req.answer(stylesheet, Http200, headers("text/css; charset=utf-8"))
    get "/assets/graph.js":
      req.answer(script, Http200, headers("text/javascript; charset=utf-8"))
    get "/assets/d3.v7.min.js":
      req.answer(d3, Http200, headers("text/javascript; charset=utf-8"))
    get "/api/{rest:path}":
      let response = handlePathRequest(store, config, req.url.path, req.url.query)
      req.answer($response.body, HttpCode(response.status), headers("application/json; charset=utf-8"))
    notfound:
      req.answer($errorResponse(404, "Route not found").body, Http404, headers("application/json; charset=utf-8"))
  # HappyX's start template catches startup failures and returns success.
  # Run its standard server directly so the CLI reports failures and exits 1.
  waitFor server.instance.serve(Port(config.port), handleRequest, config.host)

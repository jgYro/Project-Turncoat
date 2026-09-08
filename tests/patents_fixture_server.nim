## Local browser-test provider. Never used by the app unless PATENTS_ORIGIN is set.
import std/[asyncdispatch, asynchttpserver, httpcore, json, net, strutils, uri]

const
  searchFixture = staticRead("fixtures/patents.json")
  detailFixture = staticRead("fixtures/patent.html")

proc handler(req: Request) {.async, gcsafe.} =
  if req.url.path == "/patent/US1234567B1/en":
    await req.respond(Http200, detailFixture)
    return
  if req.url.path != "/xhr/query":
    await req.respond(Http404, "Synthetic fixture publication not found")
    return
  var expression = ""
  var page = 0
  for key, inner in decodeQuery(req.url.query):
    if key != "url": continue
    for name, value in decodeQuery(inner):
      if name == "q": expression = value
      elif name == "page": page = parseInt(value)
  if expression == "busy":
    await req.respond(Http429, "Synthetic rate limit")
    return
  let data = parseJson(searchFixture)
  data["results"]["num_page"] = %page
  if expression == "empty":
    data["results"]["total_num_results"] = %0
    data["results"]["total_num_pages"] = %0
    data["results"]["cluster"] = %*[{}]
  await req.respond(Http200, $data, newHttpHeaders({"Content-Type": "application/json"}))

when isMainModule:
  echo "Synthetic Google Patents fixture provider: http://127.0.0.1:5011"
  echo "Use PATENTS_ORIGIN=http://127.0.0.1:5011 on a separate app instance."
  waitFor newAsyncHttpServer().serve(Port(5011), handler, address = "127.0.0.1")

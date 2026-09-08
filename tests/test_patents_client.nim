import std/[asyncdispatch, asynchttpserver, httpcore, net, json, uri, strutils, times, unittest]
import api_errors, patents, patents_client

const
  fixture = staticRead("fixtures/patents.json")
  detail = staticRead("fixtures/patent.html")
var calls = 0
var starts {.threadvar.}: seq[float]

proc handler(req: Request) {.async, gcsafe.} =
  inc calls
  starts.add(epochTime())
  let query = decodeUrl(req.url.query)
  if "slow" in query: await sleepAsync(100)
  if req.url.path == "/patent/US1234567B1/en":
    await req.respond(Http200, detail)
  elif req.url.path.startsWith("/patent/"):
    await req.respond(Http404, "Not found")
  elif "busy" in query:
    await req.respond(Http429, "Rate limited")
  elif "forbidden" in query:
    await req.respond(Http403, "Forbidden")
  elif "malformed" in query:
    await req.respond(Http200, "<html>Challenge</html>")
  elif "redirect" in query:
    await req.respond(Http302, "Redirect", newHttpHeaders({"Location": "/consent"}))
  elif "oversized" in query:
    await req.respond(Http200, "too large", newHttpHeaders({"Content-Length": "6000000"}))
  else:
    await req.respond(Http200, fixture)

proc runChecks() {.async.} =
  let server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  let origin = "http://127.0.0.1:" & $server.getPort()
  proc acceptRequests() {.async.} =
    while true:
      try: await server.acceptRequest(handler)
      except OSError: break
  asyncCheck acceptRequests()
  let client = newPatentsClient(origin, intervalMs = 40, timeoutMs = 2000)
  var options = patentOptionsFromQuery("q=neural")
  check (await client.search(options))["total"].getInt() == 23
  discard await client.search(options)
  check calls == 1
  options.query = "sensor"
  let one = client.search(options)
  let two = client.search(options)
  discard await one
  discard await two
  check calls == 2
  check starts[1] - starts[0] >= 0.035
  check (await client.lookup("us1234567b1"))["inventors"].len == 2
  discard await client.lookup("US1234567B1")
  check calls == 3
  try:
    discard await client.lookup("US9999999B1")
    check false
  except ApiError as error: check error.status == 404
  for (query, status) in [("busy", 503), ("forbidden", 503), ("malformed", 502),
      ("redirect", 502), ("oversized", 502)]:
    options.query = query
    let before = calls
    try:
      discard await client.search(options)
      check false
    except ApiError as error: check error.status == status
    check calls == before + 1 # Redirects and failures are never retried.
  options.query = "recovered"
  check (await client.search(options))["total"].getInt() == 23
  let impatient = newPatentsClient(origin, intervalMs = 0, timeoutMs = 15)
  options.query = "slow"
  try:
    discard await impatient.search(options)
    check false
  except ApiError as error: check error.status == 504
  options.query = "recovered-again"
  check (await impatient.search(options))["total"].getInt() == 23
  # A full queue rejects additional requests, but identical queued searches coalesce.
  let bounded = newPatentsClient(origin, intervalMs = 0, timeoutMs = 2000)
  options.query = "slow-queue"
  var queued: seq[Future[JsonNode]]
  for i in 0..<8: queued.add(bounded.search(options))
  try:
    discard await bounded.search(options)
    check false
  except ApiError as error: check error.status == 503
  for future in queued: discard await future
  await sleepAsync(150)
  server.close()

suite "HTTP integration with a local Google Patents fixture server":
  test "caching, pacing, coalescing, lookup, failures, timeout, queue limit, and recovery":
    waitFor runChecks()

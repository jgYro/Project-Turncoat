import std/[asyncdispatch, asynchttpserver, httpcore, net, strutils, times, unittest]
import arxiv, arxiv_client

const fixture = staticRead("fixtures/results.xml")
var calls = 0
var starts {.threadvar.}: seq[float]

proc handler(req: Request) {.async, gcsafe.} =
  inc calls
  starts.add(epochTime())
  if "slow" in req.url.query:
    await sleepAsync(100)
  if "busy" in req.url.query:
    await req.respond(Http503, "Unavailable")
  elif "malformed" in req.url.query:
    await req.respond(Http200, "not an Atom feed")
  elif "badquery" in req.url.query:
    await req.respond(Http400, """<feed><entry><title>Error</title><id>http://arxiv.org/api/errors#bad</id><summary>Bad syntax</summary></entry></feed>""")
  else:
    await req.respond(Http200, fixture)

proc runChecks() {.async.} =
  let server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  let port = server.getPort()
  proc acceptRequests() {.async.} =
    while true:
      try: await server.acceptRequest(handler)
      except OSError: break
  asyncCheck acceptRequests()
  let client = newArxivClient("http://127.0.0.1:" & $port & "/api/query", intervalMs = 40, timeoutMs = 2000)
  var options = defaultOptions()
  options.query = "electron"
  let first = await client.search(options)
  check first.total == 21
  check calls == 1
  discard await client.search(options)
  check calls == 1
  options.query = "proton"
  let one = client.search(options)
  let two = client.search(options)
  discard await one
  discard await two
  check calls == 2
  check starts[1] - starts[0] >= 0.035
  options.query = "busy"
  try:
    discard await client.search(options)
    check false
  except ApiError as error:
    check error.status == 503
  options.query = "malformed"
  try:
    discard await client.search(options)
    check false
  except ApiError: discard
  options.query = "badquery"
  try:
    discard await client.search(options)
    check false
  except ApiError as error:
    check error.status == 422
  options.query = "recovered"
  check (await client.search(options)).total == 21
  let impatient = newArxivClient("http://127.0.0.1:" & $port & "/api/query", intervalMs = 0, timeoutMs = 15)
  options.query = "slow"
  try:
    discard await impatient.search(options)
    check false
  except ApiError as error:
    check error.status == 504
  # The queue must be released after a timeout too.
  options.query = "recovered-again"
  check (await impatient.search(options)).total == 21
  await sleepAsync(150)
  server.close()

suite "HTTP integration with a local arXiv fixture server":
  test "caching, concurrent coalescing, pacing, errors, timeout, and recovery":
    waitFor runChecks()

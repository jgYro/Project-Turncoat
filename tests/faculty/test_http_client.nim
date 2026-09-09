import std/[unittest, asyncdispatch, asynchttpserver, httpcore, net, strutils, times]
import faculty/http_client
import api_errors

var calls = 0
var retryCalls = 0
var agents {.threadvar.}: seq[string]
var starts {.threadvar.}: seq[float]

proc handler(req: Request) {.async, gcsafe.} =
  inc calls
  agents.add(req.headers.getOrDefault("User-Agent"))
  starts.add(epochTime())
  case req.url.path
  of "/retry":
    inc retryCalls
    if retryCalls == 1: await req.respond(Http500, "Temporary server error")
    else: await req.respond(Http200, "恢复")
  of "/slow":
    await sleepAsync(100)
    await req.respond(Http200, "Slow")
  of "/blocked": await req.respond(Http403, "Restricted")
  of "/challenge": await req.respond(Http200, "<script>$_ts=window['$_ts'];</script>")
  of "/redirect": await req.respond(Http302, "", newHttpHeaders({"Location": "/login"}))
  of "/big": await req.respond(Http200, repeat('x', 2048))
  of "/missing": await req.respond(Http404, "Missing")
  else: await req.respond(Http200, "高超声速飞行器")

proc checks() {.async.} =
  let server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  let origin = "http://127.0.0.1:" & $server.getPort()
  proc accept() {.async.} =
    while true:
      try: await server.acceptRequest(handler)
      except OSError: break
  asyncCheck accept()
  let hosts = ["127.0.0.1"]
  let client = newFacultyClient(userAgent = "FacultyTest/1.0", intervalMs = 40, maxRetries = 1)
  check (await client.fetchProfileHtml(origin & "/retry", hosts)) == "恢复"
  check retryCalls == 2
  check starts[1] - starts[0] >= 0.035
  check agents[0] == "FacultyTest/1.0"
  let first = client.fetchProfileHtml(origin & "/one", hosts)
  let second = client.fetchProfileHtml(origin & "/two", hosts)
  check (await first) == "高超声速飞行器"
  discard await second
  check starts[^1] - starts[^2] >= 0.035
  for (path, status) in [("/redirect", 502), ("/missing", 404)]:
    let before = calls
    try:
      discard await client.fetchProfileHtml(origin & path, hosts)
      check false
    except ApiError as error: check error.status == status
    check calls == before + 1
  let small = newFacultyClient(intervalMs = 0, maxRetries = 0, maxBytes = 100)
  try:
    discard await small.fetchProfileHtml(origin & "/big", hosts)
    check false
  except ApiError: discard
  let impatient = newFacultyClient(intervalMs = 0, maxRetries = 0, timeoutMs = 10)
  try:
    discard await impatient.fetchProfileHtml(origin & "/slow", hosts)
    check false
  except ApiError as error: check error.status == 504
  check (await impatient.fetchProfileHtml(origin & "/recovered", hosts)) == "高超声速飞行器"
  for path in ["/blocked", "/challenge"]:
    let limited = newFacultyClient(intervalMs = 0, maxRetries = 2)
    let before = calls
    for attempt in 0..1:
      try:
        discard await limited.fetchProfileHtml(origin & path, hosts)
        check false
      except ApiError as error: check error.status == 503
    check calls == before + 1
  try:
    discard await client.fetchProfileHtml("https://evil.test/", hosts)
    check false
  except ValueError: discard
  await sleepAsync(150)
  server.close()

proc concurrencyChecks() {.async.} =
  var active = 0
  var peak = 0
  let transport: FacultyTransport = proc(url, body: string): Future[FacultyHttpResponse] {.async, gcsafe.} =
    inc active
    peak = max(peak, active)
    await sleepAsync(25)
    dec active
    return FacultyHttpResponse(status: 200, body: "ok")
  let client = newFacultyClient(intervalMs = 0, maxRetries = 0, maxConcurrency = 2, maxPending = 3, transport = transport)
  let hosts = ["one.test", "two.test", "three.test"]
  var requests: seq[Future[string]]
  for host in hosts: requests.add(client.fetchProfileHtml("https://" & host & "/", hosts))
  try:
    discard await client.fetchProfileHtml("https://one.test/full", hosts)
    check false
  except ApiError as error: check error.status == 503
  for request in requests: discard await request
  check peak == 2

suite "Faculty HTTP integration (loopback only)":
  test "UTF-8, User-Agent, retries, pacing, timeout, recovery, size, and access restrictions": waitFor checks()
  test "global concurrency and pending queue limits": waitFor concurrencyChecks()

## Same AsyncHttpClient/queue conventions as arxiv_client and patents_client.
import std/[asyncdispatch, asyncstreams, httpclient, httpcore, tables, times, monotimes, uri, strutils]
import ../api_errors

type
  FacultyHttpResponse* = object
    status*: int
    body*, location*: string
  FacultyTransport* = proc(url, body: string): Future[FacultyHttpResponse] {.closure, gcsafe.}
  HostQueue = ref object
    tail: Future[void]
    nextRequest: MonoTime
    blockedUntil: float
  FacultyClient* = ref object
    userAgent*: string
    timeoutMs*, intervalMs*, maxRetries*, maxConcurrency*, maxPending*, maxBytes*: int
    hosts: Table[string, HostQueue]
    active, pending: int
    transport: FacultyTransport

proc newFacultyClient*(userAgent = "ResearchExplorer/0.1 (public faculty metadata; Nim)";
    timeoutMs = 20000; intervalMs = 3000; maxRetries = 1; maxConcurrency = 3;
    maxPending = 32; maxBytes = 8_000_000; transport: FacultyTransport = nil): FacultyClient =
  if timeoutMs < 1 or intervalMs < 0 or maxRetries notin 0..2 or maxConcurrency < 1 or
      maxConcurrency > 8 or maxPending < maxConcurrency or maxBytes < 1:
    raise newException(ValueError, "Invalid faculty HTTP limits; retries must be 0–2 and concurrency 1–8.")
  FacultyClient(userAgent: userAgent, timeoutMs: timeoutMs, intervalMs: intervalMs,
    maxRetries: maxRetries, maxConcurrency: maxConcurrency, maxPending: maxPending,
    maxBytes: maxBytes, transport: transport, hosts: initTable[string, HostQueue]())

var sharedClient: FacultyClient

proc facultyClient*(client: FacultyClient = nil): FacultyClient =
  if client != nil: return client
  if sharedClient == nil: sharedClient = newFacultyClient()
  sharedClient

proc fetchBody(http: AsyncHttpClient; url, body: string; maxBytes: int): Future[FacultyHttpResponse] {.async.} =
  let response = if body.len > 0: await http.post(url, body) else: await http.get(url)
  result.status = int(response.code)
  result.location = response.headers.getOrDefault("Location")
  if response.contentLength > maxBytes: raise apiError("Faculty response exceeds the configured size limit.")
  while true:
    let (available, chunk) = await response.bodyStream.read()
    if not available: break
    if result.body.len + chunk.len > maxBytes: raise apiError("Faculty response exceeds the configured size limit.")
    result.body.add(chunk)

proc requestOnce(client: FacultyClient; url, body: string): Future[FacultyHttpResponse] {.async.} =
  if client.transport != nil: return await client.transport(url, body)
  let http = newAsyncHttpClient(userAgent = client.userAgent, maxRedirects = 0)
  http.headers = newHttpHeaders({"Accept": "text/html,application/json", "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"})
  try:
    let response = http.fetchBody(url, body, client.maxBytes)
    if not await withTimeout(response, client.timeoutMs):
      raise apiError("The faculty website request timed out.", 504)
    return await response
  finally: http.close()

proc fetchProfileHtml*(client: FacultyClient; url: string; hosts: openArray[string];
    body = ""): Future[string] =
  ## Copy openArray before entering an async closure. Each institution supplies its hosts.
  let allowed = @hosts
  proc run(): Future[string] {.async.} =
    let uri = parseUri(url)
    if uri.scheme notin ["http", "https"] or uri.hostname.toLowerAscii() notin allowed or
        uri.username.len > 0 or uri.password.len > 0 or
        (uri.port.len > 0 and uri.hostname notin ["127.0.0.1", "localhost", "::1"]):
      raise newException(ValueError, "Faculty URL must belong to a supported public institution host.")
    let host = uri.hostname.toLowerAscii()
    if not client.hosts.hasKey(host): client.hosts[host] = HostQueue()
    let queue = client.hosts[host]
    if queue.blockedUntil > epochTime(): raise apiError("Faculty host is cooling down after an access restriction.", 503)
    if client.pending >= client.maxPending: raise apiError("Faculty request queue is full.", 503)
    let previous = queue.tail
    let finished = newFuture[void]("faculty.queue")
    queue.tail = finished
    inc client.pending
    try:
      if previous != nil: await previous
      if queue.blockedUntil > epochTime(): raise apiError("Faculty host is cooling down after an access restriction.", 503)
      for attempt in 0..client.maxRetries:
        let delay = (queue.nextRequest - getMonoTime()).inMilliseconds
        if delay > 0: await sleepAsync(int(delay))
        while client.active >= client.maxConcurrency: await sleepAsync(10)
        inc client.active
        var response: FacultyHttpResponse
        try:
          response = await client.requestOnce(url, body)
        except CatchableError as error:
          if attempt == client.maxRetries:
            if error of ApiError: raise
            raise apiError("Could not connect to the faculty website.")
          continue
        finally:
          dec client.active
          queue.nextRequest = getMonoTime() + initDuration(milliseconds = client.intervalMs)
        let lowerBody = response.body.toLowerAscii()
        if response.status in [401, 403, 429] or "$_ts=" in response.body or
            "window._cf_chl_opt" in lowerBody or "g-recaptcha" in lowerBody or
            "h-captcha" in lowerBody or "verify you are human" in lowerBody or "安全验证" in response.body:
          queue.blockedUntil = epochTime() + 300
          raise apiError("The faculty website restricted access; no bypass or retry was attempted.", 503)
        if response.status in [500, 502, 503, 504] and attempt < client.maxRetries: continue
        if response.status != 200:
          # Redirects may lead to login/challenge pages; return an explicit failure.
          raise apiError("Faculty website returned HTTP " & $response.status & ".",
            if response.status == 404: 404 else: 502)
        if response.body.len > client.maxBytes: raise apiError("Faculty response exceeds the configured size limit.")
        return response.body
    finally:
      dec client.pending
      finished.complete()
  run()

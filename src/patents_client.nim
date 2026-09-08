## The website endpoint is undocumented. Keep transport and parsing isolated.
import std/[asyncdispatch, asyncstreams, httpclient, httpcore, json, tables, times, monotimes, strutils]
import api_errors, patents

type
  PatentCacheEntry = object
    fetched: float
    data: JsonNode
  PatentsClient* = ref object
    origin: string
    intervalMs, timeoutMs: int
    cache: OrderedTable[string, PatentCacheEntry]
    tail: Future[void]
    nextRequest: MonoTime
    pending: int

proc newPatentsClient*(origin = "https://patents.google.com";
    intervalMs = 3000; timeoutMs = 20000): PatentsClient =
  PatentsClient(origin: origin.strip(trailing = true, leading = false, chars = {'/'}),
    intervalMs: intervalMs, timeoutMs: timeoutMs,
    cache: initOrderedTable[string, PatentCacheEntry]())

proc fetchBody(http: AsyncHttpClient; url: string): Future[(int, string)] {.async.} =
  let response = await http.get(url)
  if response.contentLength > 5_000_000:
    raise apiError("The Google Patents response exceeded the size limit.")
  var body = ""
  while true:
    let (available, chunk) = await response.bodyStream.read()
    if not available: break
    if body.len + chunk.len > 5_000_000:
      raise apiError("The Google Patents response exceeded the size limit.")
    body.add(chunk)
  return (int(response.code), body)

proc load(client: PatentsClient; path: string;
    parseResponse: proc(body: string): JsonNode {.closure, gcsafe.}): Future[JsonNode] {.async.} =
  if path in client.cache and epochTime() - client.cache[path].fetched < 86400:
    return client.cache[path].data
  if client.pending >= 8:
    raise apiError("Patent search is busy. Please try again shortly.", 503)
  let previous = client.tail
  let finished = newFuture[void]("patents.queue")
  client.tail = finished
  inc client.pending
  try:
    if previous != nil: await previous
    if path in client.cache and epochTime() - client.cache[path].fetched < 86400:
      return client.cache[path].data
    let delay = (client.nextRequest - getMonoTime()).inMilliseconds
    if delay > 0: await sleepAsync(int(delay))
    # Do not follow redirects to consent pages or attempt challenge bypasses.
    let http = newAsyncHttpClient(userAgent = "ResearchExplorer/0.1 (Nim HappyX; interactive patent search)",
      maxRedirects = 0)
    http.headers = newHttpHeaders({"Accept-Language": "en"})
    try:
      let response = http.fetchBody(client.origin & path)
      if not await withTimeout(response, client.timeoutMs):
        raise apiError("Google Patents is taking longer than expected. Please try again shortly.", 504)
      let (status, body) = await response
      case status
      of 200: discard
      of 404: raise apiError("That patent publication was not found on Google Patents.", 404)
      of 403, 429, 503:
        raise apiError("Google Patents is temporarily unavailable or limiting requests. Please try again later.", 503)
      else: raise apiError("Google Patents could not complete this request.")
      result = parseResponse(body)
      if client.cache.len >= 128:
        var oldest = ""
        for key in client.cache.keys:
          oldest = key
          break
        client.cache.del(oldest)
      client.cache[path] = PatentCacheEntry(fetched: epochTime(), data: result)
    except ApiError: raise
    except CatchableError:
      raise apiError("Could not connect to Google Patents. Please try again shortly.")
    finally:
      http.close()
      client.nextRequest = getMonoTime() + initDuration(milliseconds = client.intervalMs)
  finally:
    dec client.pending
    finished.complete()

proc search*(client: PatentsClient; options: PatentOptions): Future[JsonNode] =
  let path = options.patentApiPath()
  client.load(path, proc(body: string): JsonNode = parsePatentSearch(body, options))

proc lookup*(client: PatentsClient; publication: string): Future[JsonNode] =
  let id = publicationId(publication)
  client.load("/patent/" & id & "/en", proc(body: string): JsonNode = parsePatentDetail(body, id))

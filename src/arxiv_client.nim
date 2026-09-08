## One async request at a time, with a bounded daily cache and a paced queue.
import std/[asyncdispatch, httpclient, tables, times, monotimes]
import arxiv

type
  CacheEntry = object
    fetched: float
    data: SearchResult
  ArxivClient* = ref object
    endpoint: string
    intervalMs, timeoutMs: int
    cache: OrderedTable[string, CacheEntry]
    tail: Future[void]
    nextRequest: MonoTime
    pending: int

proc newArxivClient*(endpoint = "https://export.arxiv.org/api/query";
    intervalMs = 3000; timeoutMs = 20000): ArxivClient =
  ArxivClient(endpoint: endpoint, intervalMs: intervalMs, timeoutMs: timeoutMs,
    cache: initOrderedTable[string, CacheEntry]())

proc fetchBody(client: AsyncHttpClient; url: string): Future[(int, string)] {.async.} =
  let response = await client.get(url)
  let body = await response.body
  return (int(response.code), body)

proc search*(client: ArxivClient; options: SearchOptions): Future[SearchResult] {.async.} =
  let key = options.apiQuery()
  if key in client.cache and epochTime() - client.cache[key].fetched < 86400:
    return client.cache[key].data
  if client.pending >= 8:
    raise apiError("Search is busy right now. Please try again in a moment.", 503)
  let previous = client.tail
  let finished = newFuture[void]("arxiv.queue")
  client.tail = finished
  inc client.pending
  try:
    if previous != nil: await previous
    # A preceding identical request may have populated the cache while we waited.
    if key in client.cache and epochTime() - client.cache[key].fetched < 86400:
      return client.cache[key].data
    let delay = (client.nextRequest - getMonoTime()).inMilliseconds
    if delay > 0: await sleepAsync(int(delay))
    let http = newAsyncHttpClient(userAgent = "ArxivExplorer/0.1 (Nim HappyX; interactive search)")
    try:
      let pending = http.fetchBody(client.endpoint & "?" & key)
      if not await withTimeout(pending, client.timeoutMs):
        raise apiError("arXiv is taking longer than expected. Please try again shortly.", 504)
      let (status, body) = await pending
      if status == 429 or status == 503:
        raise apiError("arXiv is busy right now. Please wait a moment and try again.", 503)
      if status >= 400:
        # arXiv describes query errors inside Atom responses, including HTTP 400.
        if status == 400: discard parseFeed(body)
        raise apiError("We could not reach arXiv successfully. Please try again shortly.")
      if body.len > 5_000_000:
        raise apiError("The response from arXiv was too large. Try a smaller page size.")
      result = parseFeed(body)
      if client.cache.len >= 128:
        var oldest = ""
        for cacheKey in client.cache.keys:
          oldest = cacheKey
          break
        client.cache.del(oldest)
      client.cache[key] = CacheEntry(fetched: epochTime(), data: result)
    except ApiError:
      raise
    except CatchableError:
      raise apiError("We could not connect to arXiv. Check your connection and try again.")
    finally:
      http.close()
      client.nextRequest = getMonoTime() + initDuration(milliseconds = client.intervalMs)
  finally:
    dec client.pending
    finished.complete()

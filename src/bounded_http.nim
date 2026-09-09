## Consume HTTP bodies incrementally, rejecting excessive data before buffering it.
import std/[asyncdispatch, asyncstreams, httpclient]
import api_errors

proc readBoundedBody*(response: AsyncResponse; limit: int; message: string): Future[string] {.async.} =
  if response.contentLength > limit: raise apiError(message, 413)
  while true:
    let (hasChunk, chunk) = await response.bodyStream.read()
    if not hasChunk: break
    if chunk.len > limit - result.len: raise apiError(message, 413)
    result.add(chunk)

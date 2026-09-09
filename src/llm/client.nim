## Async OpenAI-compatible Chat Completions transport; no provider SDK required.
import std/[asyncdispatch, httpclient, httpcore, json, strutils, monotimes, times]
import config
import ../api_errors
import ../bounded_http
export config, api_errors

type LlmClient* = ref object
  config*: LlmConfig
  active: int

proc newLlmClient*(config: LlmConfig): LlmClient =
  config.validate()
  LlmClient(config: config)

proc exchange(http: AsyncHttpClient; url, body: string; verb: HttpMethod): Future[(int, string)] {.async.} =
  let response = await http.request(url, httpMethod = verb, body = body)
  if response.code.int notin 200..299: return (response.code.int, "")
  let text = await response.readBoundedBody(MaxLlmResponseBytes, "The model server returned too much data. Lower the output limit.")
  return (int(response.code), text)

proc request(client: LlmClient; path: string; body = ""; verb = HttpGet; waitForSlot = false): Future[JsonNode] {.async.} =
  if waitForSlot:
    let deadline = getMonoTime() + initDuration(milliseconds=client.config.timeoutMs*2)
    while client.active >= client.config.maxConcurrent:
      if getMonoTime()>=deadline: raise apiError("Timed out waiting for a model slot. Retry this job.",504)
      await sleepAsync(100)
  if client.active >= client.config.maxConcurrent:
    raise apiError("The model is handling other requests. Try again when one finishes.", 429)
  inc client.active
  let http = newAsyncHttpClient(userAgent = "ProjectTurncoat/0.1 (Nim; OpenAI-compatible chat)", maxRedirects = 0)
  http.headers = newHttpHeaders({"Accept": "application/json", "Content-Type": "application/json"})
  if client.config.apiKey.len > 0:
    http.headers["Authorization"] = "Bearer " & client.config.apiKey
  try:
    let pending = exchange(http, client.config.baseUrl.strip(leading = false, chars = {'/'}) & path, body, verb)
    if not await withTimeout(pending, client.config.timeoutMs):
      raise apiError("The model request timed out. Check the model server or increase TURNCOAT_LLM_TIMEOUT_MS.", 504)
    let (status, text) = await pending
    if status in [401, 403]:
      raise apiError("The model server rejected authentication. Check TURNCOAT_LLM_API_KEY.", 502)
    if status == 429:
      raise apiError("The model server is rate limiting requests. Try again later.", 429)
    if status == 404:
      raise apiError("The model or endpoint was not found. Check the base URL and served model ID in the chat setup guide.", 502)
    if status < 200 or status >= 300:
      raise apiError("The model server could not complete the request (HTTP " & $status & "). Check its logs and configuration.", 502)
    try: result = parseJson(text)
    except ValueError: raise apiError("The model server returned invalid JSON.", 502)
    if result.kind != JObject or result.hasKey("error"):
      raise apiError("The model server returned an unexpected response. Check its logs.", 502)
  except ApiError: raise
  except CatchableError:
    raise apiError("Cannot connect to the model server. Start an OpenAI-compatible server and check TURNCOAT_LLM_BASE_URL.", 503)
  finally:
    http.close()
    dec client.active

proc complete*(client: LlmClient; messages: JsonNode; waitForSlot = false): Future[JsonNode] {.async.} =
  let body = %*{"model": client.config.model, "messages": messages,
    "stream": false, "max_tokens": client.config.maxTokens, "temperature": 0.2}
  let data = await client.request("/chat/completions", $body, HttpPost, waitForSlot)
  let choices = data{"choices"}
  if choices == nil or choices.kind != JArray or choices.len == 0:
    raise apiError("The model server returned no assistant message.", 502)
  let content = choices[0]{"message", "content"}
  if content == nil or content.kind != JString or content.getStr.strip.len == 0:
    raise apiError("The model returned an empty or unsupported reply. Check that the served model supports text chat.", 502)
  return %*{"message": {"role": "assistant", "content": content.getStr},
    "model": data{"model"}.getStr(client.config.model),
    "finishReason": choices[0]{"finish_reason"}.getStr,
    "usage": (if data.hasKey("usage"): data["usage"] else: newJNull())}

proc checkConnection*(client: LlmClient): Future[JsonNode] {.async.} =
  let data = await client.request("/models")
  let models = data{"data"}
  if models == nil or models.kind != JArray:
    raise apiError("The model server did not return an OpenAI-compatible model list.", 502)
  var available = false
  var ids = newJArray()
  for model in models:
    let id = model{"id"}.getStr
    if id == client.config.model: available = true
    if id.len > 0 and ids.len < 100: ids.add(%id)
  return %*{"reachable": true, "modelAvailable": available, "models": ids}

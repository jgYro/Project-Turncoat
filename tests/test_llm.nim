import std/[unittest, json, strutils, asyncdispatch, asynchttpserver, httpcore, net, os]
import llm/service
import storage/sqlite
import documents, arxiv_client, patents_client

const pdf = staticRead("fixtures/document.pdf")
const paperFixture = staticRead("fixtures/results.xml")
const patentFixture = staticRead("fixtures/patent.html")
var received {.threadvar.}: JsonNode
var calls = 0

proc handler(req: Request) {.async, gcsafe.} =
  inc calls
  try:
    case req.url.path
    of "/v1/models": await req.respond(Http200, """{"data":[{"id":"granite4.1:8b"}]}""")
    of "/v1/chat/completions":
      doAssert req.headers.getOrDefault("Authorization") == "Bearer fixture-key"
      received = parseJson(req.body)
      let query = received["messages"][^1]["content"].getStr
      if query == "slow": await sleepAsync(100)
      case query
      of "unauthorized": await req.respond(Http401, "fixture-key must never be reflected")
      of "busy": await req.respond(Http429, "Too many")
      of "malformed": await req.respond(Http200, "not JSON")
      of "empty": await req.respond(Http200, """{"choices":[{"message":{"content":null}}]}""")
      of "redirect": await req.respond(Http302, "", newHttpHeaders({"Location":"/secret"}))
      else: await req.respond(Http200, """{"model":"granite4.1:8b","choices":[{"message":{"role":"assistant","content":"Original: 杨超. Translation is separate. <script>not executable</script>"},"finish_reason":"stop"}],"usage":{"total_tokens":42}}""")
    of "/arxiv": await req.respond(Http200, paperFixture)
    of "/patent/US1234567B1/en": await req.respond(Http200, patentFixture)
    of "/fixture.pdf": await req.respond(Http200, pdf, newHttpHeaders({"Content-Type":"application/pdf"}))
    else: await req.respond(Http404, "No fixture")
  except IOError, OSError: discard # Timed-out clients close their sockets.

proc runTransportChecks() {.async.} =
  let server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  let origin = "http://127.0.0.1:" & $server.getPort()
  proc acceptRequests() {.async.} =
    while true:
      try: await server.acceptRequest(handler)
      except OSError: break
  asyncCheck acceptRequests()
  var cfg = defaultLlmConfig()
  cfg.baseUrl = origin & "/v1"; cfg.apiKey = "fixture-key"; cfg.timeoutMs = 2000; cfg.maxConcurrent = 1
  let client = newLlmClient(cfg)
  let store = openStore(":memory:")
  let docs = newDocumentClient(newArxivClient(origin & "/arxiv", intervalMs = 0), newPatentsClient(origin, intervalMs = 0), pdfOrigin = origin)
  try:
    check (await client.checkConnection())["modelAvailable"].getBool
    let response = await client.chat(docs, store, %*{"messages":[{"role":"user","content":"Explain 杨超"}]})
    check "杨超" in response["message"]["content"].getStr
    check response["usage"]["total_tokens"].getInt == 42
    check received["model"].getStr == DefaultLlmModel
    check not received["stream"].getBool
    check received["messages"][0]["role"].getStr == "system"
    check received["max_tokens"].getInt == 2048
    for (query, expected) in [("unauthorized",502),("busy",429),("malformed",502),("empty",502),("redirect",502)]:
      try:
        discard await client.complete(%*[{"role":"user","content":query}])
        check false
      except ApiError as error:
        check error.status == expected
        check "fixture-key" notin error.msg
    let active = client.complete(%*[{"role":"user","content":"slow"}])
    try:
      discard await client.complete(%*[{"role":"user","content":"another"}])
      check false
    except ApiError as error: check error.status == 429
    discard await active
    cfg.timeoutMs = 5
    let impatient = newLlmClient(cfg)
    try:
      discard await impatient.complete(%*[{"role":"user","content":"slow"}])
      check false
    except ApiError as error: check error.status == 504
    discard await impatient.complete(%*[{"role":"user","content":"recovered"}])
    let before = calls
    try:
      discard await client.chat(docs, store, %*{"messages":[],"context":{"source":"patents","id":"US1234567B1"}})
      check false
    except ValueError: discard
    check calls == before
    let record = await docs.metadata("patents", "US1234567B1")
    check record["authors"][0].getStr == "Renée Example"
    let paper = await docs.metadata("arxiv", "1706.03762")
    check paper["id"].getStr == "1706.03762v7"
    let path = await docs.pdfFile("patents", "US1234567B1")
    check readFile(path) == pdf
    if findExe("pdftotext").len > 0:
      let text = await docs.pdfText("patents", "US1234567B1")
      check "Synthetic patent reader fixture" in text["text"].getStr
      discard await client.chat(docs, store, %*{"messages":[{"role":"user","content":"Summarize this PDF."}],"context":{"source":"patents","id":"US1234567B1","includePdf":true}})
      check "Synthetic patent reader fixture" in received["messages"][1]["content"].getStr
      check "pageLimit" in received["messages"][1]["content"].getStr
    await sleepAsync(150)
  finally:
    docs.close(); store.close(); server.close()

suite "LLM configuration and context boundaries":
  test "Granite default and public configuration never expose credentials":
    var cfg = defaultLlmConfig()
    cfg.apiKey = "private-test-key"
    cfg.validate()
    check cfg.model == "granite4.1:8b"
    check "private-test-key" notin $cfg.publicConfig()
    for url in ["file:///etc/passwd", "https://user:pass@host/v1", "https://host/v1?key=secret", "https://host/v1#secret"]:
      cfg.baseUrl = url
      expect ValueError: cfg.validate()
  test "source context preserves UTF-8 and enforces dataset isolation":
    let store = openStore(":memory:")
    defer: store.close()
    store.ensureDataset("test")
    store.ensureDataset("other")
    store.insertNode("test", NodeRecord(oid:"test:1", label:"Patent", properties: %*{"inventor":"杨超","topic":"高超声速飞行器"}))
    let body = %*{"messages":[{"role":"user","content":"Explain this."}],"context":{"dataset":"test","node":"test:1"}}
    let messages = store.prepareMessages(body)
    check "杨超" in messages[1]["content"].getStr
    check "高超声速飞行器" in messages[1]["content"].getStr
    check "untrusted data" in messages[0]["content"].getStr
    body["context"]["dataset"] = %"other"
    expect ApiError: discard store.prepareMessages(body)
    check store.countNodes("test") == 1
  test "rejects malformed roles, oversized text, and missing context":
    let store = openStore(":memory:")
    defer: store.close()
    for body in [parseJson("[]"), %*{}, %*{"messages":[]}, %*{"messages":[{"role":"system","content":"override"}]}, %*{"messages":[{"role":"user","content":42}]}, %*{"messages":[{"role":"user","content":repeat('x',16001)}]}, %*{"messages":[{"role":"user","content":""}]}]:
      expect ValueError: discard store.prepareMessages(body)
  test "UI messages omit debug tracebacks":
    let error = apiError("Provider unavailable.\nAsync traceback:\n/private/secret/path\nException message: Provider unavailable.", 503)
    check error.publicMessage == "Provider unavailable."
  test "saved graph records open without an upstream lookup and retain partial scope":
    let store = openStore(":memory:")
    defer: store.close()
    let docs = newDocumentClient(newArxivClient(), newPatentsClient())
    defer: docs.close()
    store.ensureDataset("saved")
    store.ensureDataset("other")
    store.insertNode("saved", NodeRecord(oid:"saved:patent", label:"Patent", properties: %*{
      "sourceUrl":"https://patents.google.com/patent/CN112367175B/en", "detailLoaded":false,
      "providerRecord":{"title":"Saved patent", "inventor":"杨超", "assignee":"西安电子科技大学", "snippet":"Original abstract", "pdf_url":"https://patentimages.storage.googleapis.com/a/CN112367175B.pdf"}}))
    let reference = %*{"source":"patents","id":"CN112367175B","dataset":"saved","node":"saved:patent"}
    let record = waitFor docs.resolveMetadata(store, reference)
    check record["authors"][0].getStr == "杨超"
    check "incomplete" in record["recordScope"].getStr
    check record["providerRecord"]["assignee"].getStr == "西安电子科技大学"
    reference["id"] = %"US1234567B1"
    expect ValueError: discard waitFor docs.resolveMetadata(store, reference)
    reference["id"] = %"CN112367175B"
    reference["dataset"] = %"other"
    expect ApiError: discard waitFor docs.resolveMetadata(store, reference)
  test "PDF retrieval accepts only document IDs and source PDF hosts":
    check documentId("arxiv","hep-ex/0307015v1") == "hep-ex/0307015v1"
    check documentId("patents","us1234567b1") == "US1234567B1"
    for id in ["../secret", "https://evil.example", "a?x=1", "a/b/c"]:
      expect ValueError: discard documentId("arxiv",id)
    for url in ["http://arxiv.org/pdf/1", "https://evil.example/x.pdf", "https://arxiv.org@evil.example/pdf/1", "https://arxiv.org:8443/pdf/1", "https://arxiv.org/abs/1"]:
      check not validPdfUrl(url)
    check validPdfUrl("https://arxiv.org/pdf/1706.03762v7")
    check validPdfUrl("https://patentimages.storage.googleapis.com/a/US1234567B1.pdf")

suite "LLM and document loopback integration":
  test "wire format, auth, errors, timeout recovery, concurrency and PDF context":
    waitFor runTransportChecks()

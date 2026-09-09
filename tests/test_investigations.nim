## Local HTTP + real SQLite, no live provider requests.
import std/[asyncdispatch, asynchttpserver, httpcore, net, json, strutils, uri,
  unittest, os, tempfiles]
import investigations, arxiv_client, patents_client, api_errors
import storage/[sqlite, driver]

const
  detail = staticRead("fixtures/patent.html")
  search = staticRead("fixtures/patents.json")
  papers = staticRead("fixtures/results.xml")
var requests {.threadvar.}: seq[string]
var mode {.threadvar.}: string

proc handler(req: Request) {.async, gcsafe.} =
  requests.add(req.url.path & "?" & decodeUrl(decodeUrl(req.url.query)))
  await sleepAsync(8)
  if req.url.path.startsWith("/patent/"):
    let id = req.url.path.split('/')[2]
    var html = detail.replace("US1234567B1", id)
    if mode == "missing":
      html = html.replace("scheme=\"inventor\"", "scheme=\"unknown\"")
    elif mode == "chinese":
      html = html.replace("Renée Example", "张三")
    elif mode == "duplicate":
      html = html.replace("Alex Example", "Renée Example")
    elif id != "US1234567B1":
      html = html.replace("Alex Example", "New Inventor")
    await req.respond(Http200, html)
  elif req.url.path == "/arxiv":
    await req.respond(Http200, papers)
  elif req.url.path == "/xhr/query":
    if mode == "failure": await req.respond(Http429, "Provider rate limited")
    else: await req.respond(Http200, search)
  else:
    await req.respond(Http404, "Unexpected endpoint")

proc nodeOf(snapshot: JsonNode; label: string; key = ""; value = ""): JsonNode =
  for node in snapshot["nodes"]:
    if node["label"].getStr == label and (key.len == 0 or node["properties"]{key}.getStr == value): return node
  raise newException(ValueError, "Missing test node: " & label & " " & value)

proc runChecks() {.async.} =
  let server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  let origin = "http://127.0.0.1:" & $server.getPort()
  proc acceptRequests() {.async.} =
    while true:
      try: await server.acceptRequest(handler)
      except OSError: break
  asyncCheck acceptRequests()
  defer: server.close()
  let directory = createTempDir("turncoat-tests-", "")
  defer: removeDir(directory)
  let path = directory / "app.db"
  var store = openStore(path)
  proc manager(limits = defaultInvestigationLimits()): InvestigationManager =
    newInvestigationManager(store, newPatentsClient(origin, intervalMs=0),
      newArxivClient(origin & "/arxiv", intervalMs=0), limits)

  block:
    let app = manager()
    let id = app.startInvestigation("US1234567B1")
    let initial = app.investigationSnapshot(id)
    check initial["nodes"].len == 2
    check initial["job"]["state"].getStr == "running"
    try:
      discard app.startInvestigation("US1234567B1")
      check false
    except ApiError as error: check error.status == 409
    await app.task
    var snapshot = app.investigationSnapshot(id)
    if snapshot["job"]["state"].getStr != "completed": echo snapshot["job"]["events"]
    check snapshot["job"]["state"].getStr == "completed"
    check snapshot["job"]["requests"].getInt == 5 # lookup + 2 names x 2 providers
    check requests.len == 5
    check requests[0].startsWith("/patent/US1234567B1/en")
    check requests.join("\n").contains("inventor=Renée Example")
    check requests.join("\n").contains("au:\"Renée Example\"")
    check not requests.join("\n").contains("Research & Development")
    let seed = snapshot.nodeOf("Patent", "publicationNumber", "US1234567B1")
    check seed["properties"]["detailLoaded"].getBool
    check seed["properties"]["providerRecord"]["title"].getStr == "Synthetic device & sensor"
    check seed["properties"]["providerRecord"]["raw_metadata"].len > 0
    var mentions, queries, candidates = 0
    for node in snapshot["nodes"]:
      if node["label"].getStr == "Name mention":
        inc mentions
        check not node["properties"]["identityResolved"].getBool
      if node["label"].getStr == "Name search": inc queries
    for link in snapshot["links"]:
      if link["label"].getStr == "name_search_hit":
        inc candidates
        check not link["properties"]["identityResolved"].getBool
    check mentions == 2 # coauthors expand only when their paper is selected
    check queries == 4
    check candidates == 8
    # Repeated expansion reuses durable completed queries, including after restart.
    store.close()
    store = openStore(path)
    let reopened = manager()
    reopened.expandInvestigation(id, seed["id"].getStr)
    await reopened.task
    check requests.len == 5
    check reopened.investigationSnapshot(id)["job"]["requests"].getInt == 5
    # A discovered patent yields a new source-scoped mention even with the same name.
    let other = snapshot.nodeOf("Patent", "publicationNumber", "WO2020123456A1")
    reopened.expandInvestigation(id, other["id"].getStr)
    await reopened.task
    snapshot = reopened.investigationSnapshot(id)
    check snapshot["job"]["requests"].getInt == 8 # detail + two searches for New Inventor
    var renee = 0
    for node in snapshot["nodes"]:
      if node["label"].getStr == "Name mention" and node["properties"]["name"].getStr == "Renée Example": inc renee
    check renee == 2
    let person = snapshot.nodeOf("Name mention", "name", "New Inventor")
    reopened.expandInvestigation(id, person["id"].getStr, "Known Latin Spelling")
    await reopened.task
    snapshot = reopened.investigationSnapshot(id)
    check snapshot.nodeOf("Name mention", "name", "New Inventor")["properties"]["originalName"].getStr == "New Inventor"
    check snapshot.nodeOf("Name search", "queryName", "Known Latin Spelling")["properties"]["matchBasis"].getStr == "name_only"
    let paper = snapshot.nodeOf("Paper", "arxivId", "1706.03762v7")
    reopened.expandInvestigation(id, paper["id"].getStr)
    await reopened.task
    snapshot = reopened.investigationSnapshot(id)
    check snapshot.nodeOf("Name mention", "name", "Ashish Vaswani")["properties"]["role"].getStr == "author"
    check requests.join("\n").contains("au:\"Ashish Vaswani\"")

  block:
    mode = "failure"
    let app = manager()
    let id = app.startInvestigation("US1234567B1")
    await app.task
    let snapshot = app.investigationSnapshot(id)
    check snapshot["job"]["state"].getStr == "partial"
    check snapshot.nodeOf("Paper")["properties"]["source"].getStr == "arXiv"
    check snapshot["job"]["failures"].getInt == 2
    mode = "normal"
    app.expandInvestigation(id, snapshot["job"]["seed"].getStr)
    await app.task
    check app.investigationSnapshot(id)["job"]["state"].getStr == "completed"

  block:
    let app = manager()
    let id = app.startInvestigation("US1234567B1")
    app.cancelInvestigation(id)
    let before = requests.len
    await app.task
    check requests.len == before
    check app.investigationSnapshot(id)["job"]["state"].getStr == "cancelled"

  block:
    var limits = defaultInvestigationLimits()
    limits.maxRequests = 2
    let app = manager(limits)
    let id = app.startInvestigation("US1234567B1")
    await app.task
    check app.investigationSnapshot(id)["job"]["state"].getStr == "limited"
    check app.investigationSnapshot(id)["job"]["requests"].getInt == 2

  block:
    var limits = defaultInvestigationLimits()
    limits.maxNames = 1
    let app = manager(limits)
    let id = app.startInvestigation("US1234567B1")
    await app.task
    check app.investigationSnapshot(id)["job"]["requests"].getInt == 3

  block:
    var limits = defaultInvestigationLimits()
    limits.maxNodes = 2
    let app = manager(limits)
    let id = app.startInvestigation("US1234567B1")
    await app.task
    let snapshot = app.investigationSnapshot(id)
    check snapshot["nodes"].len == 2
    check snapshot["job"]["state"].getStr == "failed"
    check not snapshot.nodeOf("Patent")["properties"]["detailLoaded"].getBool

  block:
    let app = manager()
    let initial = requests.len
    let id = app.startInvestigation("US1234567B1")
    while requests.len < initial + 3: await sleepAsync(1)
    app.cancelInvestigation(id)
    let before = requests.len
    let nodeCount = app.investigationSnapshot(id)["nodes"].len
    await app.task
    check requests.len == before
    check app.investigationSnapshot(id)["nodes"].len == nodeCount
    check app.investigationSnapshot(id)["job"]["state"].getStr == "cancelled"

  for scenario in ["missing", "chinese", "duplicate"]:
    mode = scenario
    let app = manager()
    let id = app.startInvestigation("US1234567B1")
    await app.task
    let snapshot = app.investigationSnapshot(id)
    check snapshot["job"]["state"].getStr == "completed"
    case scenario
    of "missing": check snapshot["job"]["requests"].getInt == 1
    of "duplicate": check snapshot["job"]["requests"].getInt == 3
    of "chinese":
      check snapshot.nodeOf("Name mention", "name", "张三")["properties"]["originalName"].getStr == "张三"
      check "inventor=张三" in requests.join("\n")
    else: discard
    # Simulate interrupted state on disk without triggering new HTTP on recovery.
    store.db.execute("UPDATE nodes SET properties=json_set(properties,'$.state','running') WHERE oid=?", @[id & ":investigation"])
    let recovered = manager()
    check recovered.investigationSnapshot(id)["job"]["state"].getStr == "interrupted"
    check recovered.listInvestigations().len > 0
  mode = "normal"
  store.close()

suite "Bounded provider investigations and durable evidence":
  test "incremental graph, exact name queries, recursion, deduplication, UTF-8, persistence, failures and stop":
    waitFor runChecks()

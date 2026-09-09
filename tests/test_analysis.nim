import std/[unittest, json, strutils, unicode, os, tempfiles, asyncdispatch, asynchttpserver, httpcore, net]
import analysis/service
import api_errors
import storage/[sqlite, driver]
import documents, arxiv_client, patents_client, llm/client

var calls = 0
var malformedReply = false
var received {.threadvar.}: JsonNode
const patentPage = staticRead("fixtures/patent.html")
const pdfFile = staticRead("fixtures/document.pdf")
proc fixture(req: Request) {.async, gcsafe.} =
  inc calls
  case req.url.path
  of "/patent/US1234567B1/en": await req.respond(Http200,patentPage)
  of "/fixture.pdf": await req.respond(Http200,pdfFile,newHttpHeaders({"Content-Type":"application/pdf"}))
  of "/v1/chat/completions":
    received=parseJson(req.body)
    let response = if malformedReply: "unstructured model reply" else: $(%*{"direct":[],"indirect":[{"finding":"Fixture observation","field":"pdf","quote":"Synthetic patent reader fixture","relevance":"Synthetic review for transport validation.","caveat":"This test makes no real applicability claim."}],"limitations":"Bounded fixture PDF extract."})
    await req.respond(Http200,$(%*{"model":"fixture-model","choices":[{"message":{"content":response},"finish_reason":"stop"}]}))
  else: await req.respond(Http404,"No fixture")

proc runIntegration() {.async.} =
  let server = newAsyncHttpServer()
  server.listen(Port(0),"127.0.0.1")
  let origin = "http://127.0.0.1:" & $server.getPort()
  proc acceptRequests() {.async.} =
    while true:
      try: await server.acceptRequest(fixture)
      except OSError: break
  asyncCheck acceptRequests()
  var config = defaultLlmConfig()
  config.baseUrl = origin & "/v1"; config.timeoutMs=2000
  let llm = newLlmClient(config)
  let docs = newDocumentClient(newArxivClient(origin & "/arxiv",intervalMs=0),newPatentsClient(origin,intervalMs=0),pdfOrigin=origin)
  let store = openStore(":memory:")
  try:
    store.ensureDataset("saved")
    let metadata = await docs.metadata("patents","US1234567B1")
    store.insertNode("saved",NodeRecord(oid:"patent",label:"Patent",properties: %*{"publicationNumber":"US1234567B1","sourceUrl":metadata["sourceUrl"],"title":metadata["title"],"detailLoaded":true,"providerRecord":metadata["providerRecord"]}))
    let body = %*{"dataset":"saved","node":"patent","query":"fixture","includePdf":false}
    let before = calls
    let data = await drilldown(store,docs,llm,"document",body)
    check data["history"]["total"].getInt == 0
    let scan = await drilldown(store,docs,llm,"scan",body)
    check not scan["evidence"]["pdfIncluded"].getBool
    check calls == before
    check store.loadReport("saved","patent",scan["id"].getStr) == scan
    expect ValueError: discard await drilldown(store,docs,llm,"review",%*{"dataset":"saved","node":"patent","preset":"invalid"})
    expect ApiError: discard await drilldown(store,docs,llm,"scan",%*{"dataset":"other","node":"patent"})
    check calls == before
    if findExe("pdftotext").len > 0:
      body["includePdf"] = %true
      let pdfScan = await drilldown(store,docs,llm,"scan",body)
      check pdfScan["evidence"]["pdfIncluded"].getBool
      check pdfScan["result"]["hits"].len > 0
      body["preset"] = %"dual-use"
      let review = await drilldown(store,docs,llm,"review",body)
      check review["result"]["indirect"].len == 1
      check review["model"].getStr == "fixture-model"
      check "bounded extract" in received["messages"][0]["content"].getStr
      check "Synthetic patent reader fixture" in received["messages"][1]["content"].getStr
      malformedReply = true
      let malformed = await drilldown(store,docs,llm,"review",body)
      check malformed["result"]["formatError"].getStr.len > 0
      check store.loadReport("saved","patent",malformed["id"].getStr)["rawResponse"].getStr == "unstructured model reply"
    else: echo "PDF/AI fixture integration skipped: pdftotext unavailable."
  finally:
    docs.close();store.close();server.close()

suite "Deterministic evidence screening":
  test "expanded vocabulary and public arXiv example preserve contextual distinctions":
    let scan = scanKeywords(%*{"title":"EMI electromagnetic interference radar reflection ballistic target advesary adversarial LLM AI model red-team vulnerabilities"})
    var ids: seq[string]
    for tag in scan["tags"]:
      ids.add(tag["id"].getStr)
      check tag["bucket"].getStr != "direct"
      if tag["id"].getStr in ["reflection","ballistics","target","adversary","model"]: check tag["bucket"].getStr == "context"
    for id in ["emi","radar","reflection","ballistics","target","adversary","llm","ai","model","red-team","vulnerability"]: check id in ids
    let example = keywordExample()
    check example["scan"]["tags"].len == 5
    check example["scan"]["version"].getStr == "turncoat-keywords-v2"
    check scanKeywords(%*{"title":"premier modeless retarget delimit"})["tags"].len == 0
  test "boundaries, case, Chinese source text and byte offsets":
    let fields = %*{"title":"Carbon fiber for civilian aircraft", "abstract":"杨超提出碳纤维。MISSILE test; missileproof is different. Not for military use."}
    let scan = scanKeywords(fields)
    check scan["tags"].len == 3
    var chinese = false
    var missile = 0
    for hit in scan["hits"]:
      let source = fields[hit["field"].getStr].getStr
      check source[hit["startByte"].getInt..<hit["endByte"].getInt] == hit["matched"].getStr
      check validateUtf8(hit["excerpt"].getStr) < 0
      let localStart = hit["startByte"].getInt-hit["excerptStartByte"].getInt
      check hit["excerpt"].getStr[localStart..<localStart+hit["matched"].getStr.len] == hit["matched"].getStr
      if hit["matched"].getStr == "碳纤维": chinese = true
      if hit["rule"].getStr == "missile": inc missile
      if hit["rule"].getStr == "carbon-fiber": check hit["bucket"].getStr == "indirect"
    check chinese and missile == 1
    check scanKeywords(%*{"title":"Civil carbon fiber bridge"})["tags"][0]["bucket"].getStr == "indirect"
  test "custom phrases, bounded output, empty evidence and malformed input":
    check scanKeywords(%*{"abstract":"Exact phrase."},"Exact phrase")["hits"].len == 1
    let many = scanKeywords(%*{"pdf":repeat("missile ",600)})
    check many["hits"].len == 500
    check many["totalMatches"].getInt == 600
    check many["truncated"].getBool
    check scanKeywords(%*{"title":""})["hits"].len == 0
    expect ValueError: discard scanKeywords(%*{"title":4})
    expect ValueError: discard scanKeywords(%*{"title":"text"},repeat("x",161))
  test "AI quotes are located separately from interpretations":
    let fields = %*{"pdf":"The carbon fiber material is used for civil aircraft. 原始中文证据必须保留。"}
    let parsed = validateReview($(%*{"direct":[{"finding":"Unsupported","field":"pdf","quote":"A missile uses this technology.","relevance":"Military","caveat":"Unclear"}],
      "indirect":[{"finding":"Material","field":"pdf","quote":"carbon fiber material is used for civil aircraft","relevance":"Potential dual-use material","caveat":"Civilian application explicitly described; military use unverified."}],"limitations":"Partial extract."}),fields)
    check parsed["direct"].len == 0
    check parsed["indirect"].len == 1
    check parsed["unverified"].len == 1
    check parsed["indirect"][0]["startByte"].getInt == 4
    check validateReview("not JSON",fields)["formatError"].getStr.len > 0
    check validateReview("[]",fields)["formatError"].getStr.len > 0
    expect ValueError: discard reviewPreset("invented")

suite "Saved drill-down records":
  setup:
    let store = openStore(":memory:")
    store.ensureDataset("one"); store.ensureDataset("two")
    for (oid,label) in [("author","Name mention"),("other-author","Name mention"),("query","Name search"),("patent","Patent"),("paper","Paper"),("unrelated","Paper")]:
      store.insertNode("one",NodeRecord(oid:oid,label:label,properties: %*{"name":"Same name","title":oid}))
    store.insertEdge("one",EdgeRecord(oid:"listed",source:"patent",target:"author",label:"lists_inventor",properties:newJObject()))
    store.insertEdge("one",EdgeRecord(oid:"searched",source:"author",target:"query",label:"searched_name",properties:newJObject()))
    store.insertEdge("one",EdgeRecord(oid:"hit",source:"query",target:"paper",label:"name_search_hit",properties:newJObject()))
    store.insertEdge("one",EdgeRecord(oid:"other-list",source:"unrelated",target:"other-author",label:"lists_author",properties:newJObject()))
  teardown:
    store.close()
  test "exact-node traversal, evidence bases, pagination and dataset isolation":
    let data = store.authorDocuments("one","author",1)
    check data["meta"]["total"].getInt == 2
    check data["meta"]["hasMore"].getBool
    check data["rows"][0]["basis"].getStr == "name_search_candidate"
    check store.authorDocuments("one","author",1,1)["rows"][0]["basis"].getStr == "source_listed"
    expect ApiError: discard store.authorDocuments("two","author")
    expect ValueError: discard store.authorDocuments("one","patent")
    check store.savedNameSearches()["total"].getInt == 1
    check store.savedNameSearches("two")["total"].getInt == 0
  test "report storage does not rewrite source nodes and respects foreign keys":
    let original = store.getNode("one","patent").get.properties
    let report = %*{"id":"run","dataset":"one","node":"patent","kind":"keywords","createdAt":"2026-09-09T00:00:00Z","evidence":{"text":"碳纤维"},"result":{"tags":[]}}
    store.saveReport(report)
    check store.loadReport("one","patent","run") == report
    check store.listReports("one","patent")["total"].getInt == 1
    check store.getNode("one","patent").get.properties == original
    expect ApiError: discard store.loadReport("two","patent","run")
    expect ApiError: discard store.loadReport("one","paper","run")
    store.deleteNode("one","patent")
    check store.db.scalarInt("SELECT count(*) FROM analysis_reports") == 0
  test "canonical authored and invented edges remain source-listed without duplicates":
    store.insertEdge("one",EdgeRecord(oid:"authored",source:"author",target:"paper",label:"AUTHORED",properties:newJObject()))
    store.insertEdge("one",EdgeRecord(oid:"invented",source:"author",target:"patent",label:"INVENTED",properties:newJObject()))
    let data = store.authorDocuments("one","author")
    check data["meta"]["total"].getInt == 2
    for row in data["rows"]: check row["basis"].getStr == "source_listed"
  test "version-one migration preserves graph data and reports survive reopening":
    let dir = createTempDir("turncoat-analysis-","")
    let path = dir / "app.db"
    var disk = openStore(path)
    try:
      disk.ensureDataset("saved")
      disk.insertNode("saved",NodeRecord(oid:"doc",label:"Paper",properties: %*{"title":"Original"}))
      disk.db.execute("DROP TABLE analysis_reports")
      disk.db.execute("DROP TABLE investigation_shares")
      disk.db.execute("PRAGMA user_version=1")
      disk.close(); disk = openStore(path)
      check disk.db.scalarInt("PRAGMA user_version") == 3
      check disk.getNode("saved","doc").get.properties["title"].getStr == "Original"
      disk.saveReport(%*{"id":"persisted","dataset":"saved","node":"doc","kind":"ai","createdAt":"2026-09-09","rawResponse":"原文"})
      disk.close(); disk = openStore(path)
      check disk.loadReport("saved","doc","persisted")["rawResponse"].getStr == "原文"
    finally:
      disk.close(); removeDir(dir)

suite "Document screening loopback integration":
  test "source snapshots, explicit retrieval, model review, malformed replies and persistence":
    waitFor runIntegration()

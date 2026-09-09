## Real async workers and SQLite; all network traffic uses a loopback fixture.
import std/[unittest, asyncdispatch, asynchttpserver, httpcore, net, json,
  os, tempfiles, strutils]
import analysis/jobs
import documents, arxiv_client, patents_client, llm/client, api_errors
import storage/[sqlite, driver, analysis_store]

const patentPage = staticRead("fixtures/patent.html")
const pdfFile = staticRead("fixtures/document.pdf")
var modelCalls, pdfCalls, modelActive, peakModels: int
var releaseModel, failModel: bool
proc fixture(req: Request) {.async, gcsafe.} =
  case req.url.path
  of "/patent/US1234567B1/en": await req.respond(Http200,patentPage)
  of "/fixture.pdf":
    inc pdfCalls
    await sleepAsync(50)
    await req.respond(Http200,pdfFile,newHttpHeaders({"Content-Type":"application/pdf"}))
  of "/v1/chat/completions":
    inc modelCalls;inc modelActive;peakModels=max(peakModels,modelActive)
    while not releaseModel: await sleepAsync(10)
    dec modelActive
    if failModel: await req.respond(Http503,"Synthetic model unavailable")
    else:
      let text = $(%*{"direct":[],"indirect":[],"limitations":"Synthetic bounded PDF evidence."})
      await req.respond(Http200,$(%*{"model":"fixture-model","choices":[{"message":{"content":text},"finish_reason":"stop"}]}))
  else: await req.respond(Http404,"Unexpected fixture request")

proc runChecks() {.async.} =
  doAssert findExe("pdftotext").len>0, "Install Poppler to run PDF background job integration tests."
  let server=newAsyncHttpServer()
  server.listen(Port(0),"127.0.0.1")
  let origin="http://127.0.0.1:" & $server.getPort()
  proc acceptRequests() {.async.} =
    while true:
      try: await server.acceptRequest(fixture)
      except OSError: break
  asyncCheck acceptRequests()
  let directory=createTempDir("turncoat-jobs-","")
  var store=openStore(directory/"app.db")
  var config=defaultLlmConfig()
  config.baseUrl=origin & "/v1";config.timeoutMs=5000;config.maxConcurrent=2
  let llm=newLlmClient(config)
  let docs=newDocumentClient(newArxivClient(origin & "/arxiv",intervalMs=0),newPatentsClient(origin,intervalMs=0),pdfOrigin=origin)
  let manager=newAnalysisJobManager(store,docs,llm)
  try:
    store.ensureDataset("saved")
    let metadata=await docs.metadata("patents","US1234567B1")
    for oid in ["first","second","third"]:
      store.insertNode("saved",NodeRecord(oid:oid,label:"Patent",properties: %*{"publicationNumber":"US1234567B1","sourceUrl":metadata["sourceUrl"],"title":"UTF-8 杨超 " & oid,"detailLoaded":true,"providerRecord":metadata["providerRecord"]}))
    let first=manager.startAnalysisJobs("saved","first")["jobs"]
    let second=manager.startAnalysisJobs("saved","second")["jobs"]
    check first.len==2 and second.len==2
    check first[0]["state"].getStr=="queued"
    check first[1]["preset"].getStr=="wartime"
    let duplicate=manager.startAnalysisJobs("saved","first")["jobs"]
    check duplicate[0]["id"]==first[0]["id"] and duplicate[1]["id"]==first[1]["id"]
    for attempt in 0..<500:
      if modelActive==2 and store.analysisJob(first[0]["id"].getStr)["state"].getStr=="succeeded": break
      await sleepAsync(10)
    check modelActive==2 and peakModels==2
    check pdfCalls==1 # Both kinds and both documents share the same PDF retrieval.
    check store.analysisJob(first[0]["id"].getStr)["state"].getStr=="succeeded"
    check store.analysisJob(first[1]["id"].getStr)["state"].getStr=="running"
    let third=manager.startAnalysisJobs("saved","third")["jobs"]
    check third[1]["state"].getStr=="queued"
    for attempt in 0..<100:
      if store.analysisJob(third[0]["id"].getStr)["state"].getStr=="succeeded": break
      await sleepAsync(10)
    check store.analysisJob(third[0]["id"].getStr)["state"].getStr=="succeeded"
    check modelCalls==2 # Keyword jobs proceed while the model slots are occupied.
    releaseModel=true
    await manager.waitForAnalysisJobs()
    check modelCalls==3 and peakModels==2
    for item in store.analysisJobs()["jobs"]:
      check item["state"].getStr=="succeeded"
      let report=store.loadReport("saved",item["node"].getStr,item["reportId"].getStr)
      check report["evidence"]["pdfIncluded"].getBool
      check "Synthetic patent reader fixture" in report["evidence"]["fields"]["pdf"].getStr
    discard manager.startAnalysisJobs("saved","first")
    await manager.waitForAnalysisJobs()
    check modelCalls==3
    expect ApiError: discard manager.startAnalysisJobs("other","first")
    expect ValueError: discard manager.startAnalysisJobs("saved","first",kind="invalid")
    expect ValueError: discard manager.startAnalysisJobs("saved","first",preset="invalid")

    failModel=true
    let failed=manager.startAnalysisJobs("saved","first",force=true)["jobs"]
    await manager.waitForAnalysisJobs()
    check store.analysisJob(failed[0]["id"].getStr)["state"].getStr=="succeeded"
    check store.analysisJob(failed[1]["id"].getStr)["state"].getStr=="failed"
    check store.analysisJob(failed[1]["id"].getStr)["error"].getStr.len>0
    failModel=false
    let retry=manager.startAnalysisJobs("saved","first",kind="ai",force=true)["jobs"][0]
    await manager.waitForAnalysisJobs()
    check store.analysisJob(retry["id"].getStr)["state"].getStr=="succeeded"

    # A seed can be queued before its provider metadata arrives.
    store.insertNode("saved",NodeRecord(oid:"saved:investigation",label:"Investigation",properties: %*{"state":"running"}))
    store.insertNode("saved",NodeRecord(oid:"pending",label:"Patent",properties: %*{"publicationNumber":"US1234567B1"}))
    let pending=manager.startAnalysisJobs("saved","pending",kind="keywords")["jobs"][0]
    await sleepAsync(30)
    check store.analysisJob(pending["id"].getStr)["state"].getStr=="preparing"
    store.db.execute("UPDATE nodes SET properties=? WHERE dataset='saved' AND oid='pending'",@[$(%*{"publicationNumber":"US1234567B1","detailLoaded":true,"sourceUrl":metadata["sourceUrl"],"title":metadata["title"],"providerRecord":metadata["providerRecord"]})])
    await manager.waitForAnalysisJobs()
    check store.analysisJob(pending["id"].getStr)["state"].getStr=="succeeded"

    # Durable state survives restart; interrupted inference is never replayed.
    let before=modelCalls
    let interrupted=store.analysisJob(retry["id"].getStr)
    interrupted["state"] = %"running"
    store.updateAnalysisJob(interrupted)
    store.close();store=openStore(directory/"app.db")
    let reopened=newAnalysisJobManager(store,docs,llm)
    await reopened.waitForAnalysisJobs()
    check store.analysisJob(retry["id"].getStr)["state"].getStr=="interrupted"
    check store.analysisJob(first[0]["id"].getStr)["state"].getStr=="succeeded"
    check modelCalls==before

    # The queue has a fixed bound, including jobs waiting for source metadata.
    store.db.execute("UPDATE nodes SET properties='{}' WHERE dataset='saved' AND oid='pending'")
    # Populate persisted jobs directly to exercise admission without unnecessary inference.
    for i in 0..<MaxPendingAnalysisJobs:
      store.insertAnalysisJob(%*{"id":"queued-" & $i,"dataset":"saved","node":"first","kind":"ai","state":"queued","createdAt":jobStamp(),"updatedAt":jobStamp()},"queue-key-" & $i)
    expect ApiError: discard reopened.startAnalysisJobs("saved","first",force=true)
    check store.pendingAnalysisCount()==MaxPendingAnalysisJobs
    store.interruptAnalysisJobs()
  finally:
    releaseModel=true
    await manager.waitForAnalysisJobs()
    docs.close();store.close();server.close();removeDir(directory)

suite "Durable concurrent analysis workers":
  test "parallel completion, shared PDF, deduplication, failure isolation, restart and queue bounds":
    waitFor runChecks()

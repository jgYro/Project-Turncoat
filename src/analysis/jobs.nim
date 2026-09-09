## Independent async workers survive browser navigation. SQLite stays on its owning thread.
import std/[asyncdispatch, json, tables, strutils, sysrand, monotimes, times]
import checksums/sha1
import service
import ../documents
import ../llm/client
import ../storage/[sqlite, job_store]
export job_store

const MaxPendingAnalysisJobs* = 32
type AnalysisJobManager* = ref object
  store: GraphStore
  documents: DocumentClient
  llm: LlmClient
  queued: seq[JsonNode]
  active: Table[string,string]
  tasks: Table[string,Future[void]]

proc newAnalysisJobManager*(store: GraphStore; documents: DocumentClient; llm: LlmClient): AnalysisJobManager =
  store.interruptAnalysisJobs()
  AnalysisJobManager(store:store,documents:documents,llm:llm)

proc pump(manager: AnalysisJobManager) {.gcsafe.}

proc awaitSource(manager: AnalysisJobManager; job: JsonNode): Future[void] {.async.} =
  let deadline = getMonoTime()+initDuration(seconds=120)
  while true:
    let node = manager.store.requireNode(job["dataset"].getStr,job["node"].getStr)
    if node.properties{"providerRecord"}!=nil:
      job["title"] = %node.properties{"title"}.getStr(job["title"].getStr)
      return
    let root = manager.store.getNode(job["dataset"].getStr,job["dataset"].getStr & ":investigation")
    if root.isNone or root.get.properties{"state"}.getStr notin ["pending","running"]:
      raise apiError("Source metadata is unavailable. Open or expand this document, then retry analysis.",422)
    if getMonoTime()>=deadline: raise apiError("Timed out waiting for source metadata. Retry when retrieval finishes.",504)
    await sleepAsync(100)

proc execute(manager: AnalysisJobManager; job: JsonNode): Future[void] {.async.} =
  await sleepAsync(1) # Return the job IDs to the browser before doing work.
  try:
    job["state"] = %"preparing"
    manager.store.updateAnalysisJob(job)
    await manager.awaitSource(job)
    let progress: AnalysisProgress = proc(stage: string) {.gcsafe.} =
      job["state"] = %stage
      manager.store.updateAnalysisJob(job)
    let report = await manager.store.drilldown(manager.documents,manager.llm,
      if job["kind"].getStr=="ai":"review" else:"scan",job["request"],progress,waitForModel=true)
    job["reportId"] = report["id"]
    job["pdfIncluded"] = report["evidence"]["pdfIncluded"]
    job["warning"] = %report["evidence"]{"warning"}.getStr
    job["state"] = %"succeeded"
    if report["result"]{"formatError"}.getStr.len>0:
      job["state"] = %"failed"
      job["error"] = report["result"]["formatError"]
  except CatchableError as error:
    job["state"] = %"failed"
    job["error"] = %error.publicMessage
  finally:
    job["finishedAt"] = %jobStamp()
    manager.store.updateAnalysisJob(job)
    manager.active.del(job["id"].getStr)
    manager.tasks.del(job["id"].getStr)
    manager.pump()

proc pump(manager: AnalysisJobManager) {.gcsafe.} =
  var index = 0
  while index<manager.queued.len:
    let job = manager.queued[index]
    let kind = job["kind"].getStr
    var running = 0
    for activeKind in manager.active.values:
      if activeKind==kind: inc running
    let capacity = if kind=="ai":min(2,manager.llm.config.maxConcurrent) else:2
    if running>=capacity:
      inc index
      continue
    manager.queued.delete(index)
    let id = job["id"].getStr
    manager.active[id] = kind
    manager.tasks[id] = manager.execute(job)

proc startAnalysisJobs*(manager: AnalysisJobManager; dataset, oid: string;
    kind = "all"; preset = "wartime"; query = ""; includePdf = true; force = false): JsonNode =
  if kind notin ["all","keywords","ai"]: raise newException(ValueError,"Choose keywords, ai, or all.")
  if query.len>160: raise newException(ValueError,"Keep the keyword phrase below 160 UTF-8 bytes.")
  if kind!="keywords": discard reviewPreset(preset)
  let reference = manager.store.documentReference(dataset,oid)
  let node = manager.store.requireNode(dataset,oid)
  var fresh: seq[(JsonNode,string)]
  var jobs = newJArray()
  for jobKind in ["keywords","ai"]:
    if kind!="all" and kind!=jobKind: continue
    let request = %*{"dataset":dataset,"node":oid,"preset":(if jobKind=="ai":preset else:""),
      "query":(if jobKind=="keywords":query else:""),"includePdf":jobKind=="ai" or includePdf}
    var key = ($secureHash($request & jobKind & (if jobKind=="ai": ReviewVersion & manager.llm.config.model else: KeywordCatalogText))).toLowerAscii
    let previous = manager.store.findAnalysisJob(key)
    # Repeated Investigate clicks reuse both pending jobs and completed reports.
    if not force and previous!=nil:
      jobs.add(previous)
      continue
    let id = ($secureHash($urandom(24))).toLowerAscii
    if force: key.add(":" & id)
    let stamp = jobStamp()
    let job = %*{"id":id,"dataset":dataset,"node":oid,"reference":reference,
      "title":node.properties{"title"}.getStr(reference["id"].getStr),"kind":jobKind,
      "preset":request["preset"],"request":request,"state":"queued","createdAt":stamp,
      "updatedAt":stamp,"error":"","reportId":""}
    fresh.add((job,key));jobs.add(job)
  if manager.store.pendingAnalysisCount()+fresh.len>MaxPendingAnalysisJobs:
    raise apiError("The analysis queue is full. Wait for a job to finish before investigating another document.",429)
  manager.store.transaction:
    for (job,key) in fresh: manager.store.insertAnalysisJob(job,key)
  for (job,key) in fresh: manager.queued.add(job)
  manager.pump()
  return %*{"jobs":jobs}

proc waitForAnalysisJobs*(manager: AnalysisJobManager): Future[void] {.async.} =
  ## Test/shutdown helper; request handlers never wait for the full queue.
  while manager.active.len>0 or manager.queued.len>0: await sleepAsync(20)

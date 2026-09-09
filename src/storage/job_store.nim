## Durable progress and result references; document evidence stays in analysis_reports.
import std/[json, times]
import sqlite, driver
import ../api_errors

const PendingJobStates* = ["queued", "preparing", "running"]
proc jobStamp*(): string = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

proc analysisJob*(store: GraphStore; id: string): JsonNode =
  for row in store.db.rows("SELECT job FROM analysis_jobs WHERE id=?", @[id]): return parseJson(row[0])
  raise apiError("This background job was not found.", 404)

proc findAnalysisJob*(store: GraphStore; key: string): JsonNode =
  for row in store.db.rows("SELECT job FROM analysis_jobs WHERE dedupe_key=?", @[key]): return parseJson(row[0])
  return nil

proc insertAnalysisJob*(store: GraphStore; job: JsonNode; key: string) =
  store.db.execute("INSERT INTO analysis_jobs(id,dataset,node,kind,state,dedupe_key,created_at,updated_at,job) VALUES(?,?,?,?,?,?,?,?,?)",
    @[job["id"].getStr,job["dataset"].getStr,job["node"].getStr,job["kind"].getStr,
      job["state"].getStr,key,job["createdAt"].getStr,job["updatedAt"].getStr,$job])

proc updateAnalysisJob*(store: GraphStore; job: JsonNode) =
  job["updatedAt"] = %jobStamp()
  store.db.execute("UPDATE analysis_jobs SET state=?,updated_at=?,job=? WHERE id=?",
    @[job["state"].getStr,job["updatedAt"].getStr,$job,job["id"].getStr])

proc pendingAnalysisCount*(store: GraphStore): int =
  store.db.scalarInt("SELECT count(*) FROM analysis_jobs WHERE state IN ('queued','preparing','running')")

proc analysisJobs*(store: GraphStore; dataset = ""; node = ""): JsonNode =
  if dataset.len>0: validateDataset(dataset)
  if node.len>512: raise newException(ValueError,"Invalid node identifier.")
  var items = newJArray()
  for row in store.db.rows("""SELECT job FROM analysis_jobs WHERE (?='' OR dataset=?) AND (?='' OR node=?)
      ORDER BY state IN ('queued','preparing','running') DESC,created_at DESC,rowid DESC LIMIT 100""", @[dataset,dataset,node,node]):
    items.add(parseJson(row[0]))
  %*{"jobs":items,"active":store.pendingAnalysisCount(),"limit":100}

proc interruptAnalysisJobs*(store: GraphStore) =
  var jobs: seq[JsonNode]
  for row in store.db.rows("SELECT job FROM analysis_jobs WHERE state IN ('queued','preparing','running')"):
    jobs.add(parseJson(row[0]))
  for job in jobs:
    job["state"] = %"interrupted"
    job["error"] = %"Server restarted before this job finished. Retry to run it again."
    store.updateAnalysisJob(job)

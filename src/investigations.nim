## Bounded name exploration. Source mentions are document-scoped, never identities.
import std/[asyncdispatch, json, strutils, times, sysrand, tables]
import checksums/sha1
import arxiv, arxiv_client, patents, patents_client
import storage/[sqlite, investigation_store]
from documents import documentId

const InvestigationSchema = "turncoat/investigation/v1"

type
  InvestigationLimits* = object
    maxRequests*, maxNames*, maxNodes*, maxEdges*: int
  InvestigationManager* = ref object
    store*: GraphStore
    patents: PatentsClient
    papers: ArxivClient
    limits: InvestigationLimits
    active: Table[string,Future[void]]
    task*: Future[void]

proc defaultInvestigationLimits*(): InvestigationLimits =
  InvestigationLimits(maxRequests: 40, maxNames: 12, maxNodes: 500, maxEdges: 1000)

proc stamp(): string = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
proc digest(value: string): string = ($secureHash(value)).toLowerAscii
proc rootId(id: string): string = id & ":investigation"
proc recordId(id, kind, key: string): string = id & ":" & kind & ":" & digest(key)

proc job(manager: InvestigationManager; id: string): NodeRecord =
  validateDataset(id)
  let stored = manager.store.getNode(id, rootId(id))
  if stored.isNone or stored.get.properties{"schema"}.getStr != InvestigationSchema:
    raise apiError("Investigation not found.", 404)
  stored.get

proc save(manager: InvestigationManager; id: string; properties: JsonNode) =
  properties["updatedAt"] = %stamp()
  manager.store.upsertNode(id, NodeRecord(oid: rootId(id), label: "Investigation", properties: properties))

proc event(manager: InvestigationManager; id, message: string) =
  let properties = manager.job(id).properties
  let events = properties["events"]
  if events.len >= 100: events.elems.delete(0)
  events.add(%*{"at": stamp(), "message": message})
  manager.save(id, properties)

proc setState(manager: InvestigationManager; id, state: string) =
  let properties = manager.job(id).properties
  properties["state"] = %state
  manager.save(id, properties)

proc newInvestigationManager*(store: GraphStore; patents: PatentsClient;
    papers: ArxivClient; limits = defaultInvestigationLimits()): InvestigationManager =
  if limits.maxRequests < 1 or limits.maxNames < 1 or limits.maxNodes < 2 or limits.maxEdges < 1:
    raise newException(ValueError, "Invalid investigation limits")
  result = InvestigationManager(store: store, patents: patents, papers: papers, limits: limits)
  # A restart preserves evidence but must never silently restart network work.
  for id in store.runningInvestigationIds(InvestigationSchema):
    result.setState(id, "interrupted")
    result.event(id, "Server restarted. Saved evidence is intact; expand a node to continue.")

proc putNode(manager: InvestigationManager; id: string; node: NodeRecord) =
  if manager.store.getNode(id, node.oid).isNone and manager.store.countNodes(id) >= manager.limits.maxNodes:
    raise apiError("Saved graph node limit reached.", 409)
  manager.store.upsertNode(id, node)

proc connect(manager: InvestigationManager; id, source, target, label: string;
    properties: JsonNode) =
  let oid = recordId(id, "edge", source & "\n" & label & "\n" & target)
  if manager.store.getEdge(id, oid).isNone and manager.store.countEdges(id) >= manager.limits.maxEdges:
    raise apiError("Saved graph relationship limit reached.", 409)
  manager.store.upsertEdge(id, EdgeRecord(oid: oid, source: source, target: target,
    label: label, properties: properties))

proc stopped(manager: InvestigationManager; id: string): bool =
  manager.job(id).properties["state"].getStr != "running"

proc cancelled(manager: InvestigationManager; id: string): bool =
  manager.job(id).properties["state"].getStr in ["cancelled", "interrupted", "failed"]

proc reserve(manager: InvestigationManager; id, description: string): bool =
  if manager.stopped(id): return false
  let properties = manager.job(id).properties
  if properties["requests"].getInt >= manager.limits.maxRequests:
    manager.setState(id, "limited")
    manager.event(id, "Request budget reached. Saved results remain available.")
    return false
  properties["requests"] = %(properties["requests"].getInt + 1)
  manager.save(id, properties)
  manager.event(id, description)
  true

proc mention(manager: InvestigationManager; id, source, name, role, sourceUrl: string): string =
  result = recordId(id, "mention", source & "\n" & role & "\n" & name)
  manager.putNode(id, NodeRecord(oid: result, label: if role == "assignee": "Assignee" else: "Name mention",
    properties: %*{"name": name, "originalName": name, "role": role,
      "sourceUrl": sourceUrl, "sourceRecord": source,
      "nameOrigin": "provider metadata", "identityResolved": false}))
  manager.connect(id, source, result, "lists_" & role,
    %*{"evidence": "source_metadata", "sourceUrl": sourceUrl})

proc savePatent(manager: InvestigationManager; id: string; data: JsonNode; full: bool): string =
  let publication = data["publication_number"].getStr
  result = recordId(id, "patent", publication)
  let old = manager.store.getNode(id, result)
  # A search snippet must never overwrite a previously retrieved full record.
  if old.isSome and old.get.properties{"detailLoaded"}.getBool and not full: return
  manager.putNode(id, NodeRecord(oid: result, label: "Patent", properties: %*{
    "publicationNumber": publication, "title": data["title"], "source": "Google Patents",
    "sourceUrl": data["url"], "retrievedAt": stamp(), "detailLoaded": full,
    "providerRecord": data}))
  if full:
    for name in data["inventors"]:
      if name.getStr.strip.len > 0:
        discard manager.mention(id, result, name.getStr, "inventor", data["url"].getStr)
    for name in data["original_assignees"]:
      if name.getStr.strip.len > 0:
        discard manager.mention(id, result, name.getStr, "assignee", data["url"].getStr)

proc savePaper(manager: InvestigationManager; id: string; paper: Paper; oid = ""): string =
  result = if oid.len>0: oid else: recordId(id, "paper", paper.id)
  let url = "https://arxiv.org/abs/" & paper.id
  manager.putNode(id, NodeRecord(oid: result, label: "Paper", properties: %*{
    "arxivId": paper.id, "title": paper.title, "source": "arXiv", "sourceUrl": url,
    "retrievedAt": stamp(), "providerRecord": %paper}))

proc searchName(manager: InvestigationManager; id, mentionId, name, provider: string): Future[void] {.async.} =
  if manager.stopped(id): return
  let queryId = recordId(id, "query", provider & "\n" & name)
  let previous = manager.store.getNode(id, queryId)
  let query = if previous.isSome: previous.get.properties
    else: %*{"name": name, "queryName": name, "provider": provider,
      "field": (if provider == "arXiv": "author" else: "inventor"), "state": "pending",
      "matchBasis": "name_only", "identityResolved": false}
  manager.putNode(id, NodeRecord(oid: queryId, label: "Name search", properties: query))
  manager.connect(id, mentionId, queryId, "searched_name", %*{
    "queryName": name, "nameOrigin": (if name == manager.store.getNode(id, mentionId).get.properties["originalName"].getStr:
      "provider metadata" else: "user supplied spelling"), "identityResolved": false})
  if query["state"].getStr == "completed": return
  if not manager.reserve(id, "Searching " & provider & " for “" & name & "”…"): return
  query["state"] = %"running"
  query["startedAt"] = %stamp()
  manager.putNode(id, NodeRecord(oid: queryId, label: "Name search", properties: query))
  try:
    var found: seq[string]
    var patentResponse: JsonNode
    var paperResponse: SearchResult
    if provider == "Google Patents":
      var options = defaultPatentOptions()
      options.inventor = name
      query["queryUrl"] = %options.patentSearchUrl()
      patentResponse = await manager.patents.search(options)
      if manager.cancelled(id): return
    else:
      var options = defaultOptions()
      options.author = name
      query["queryUrl"] = %("https://export.arxiv.org/api/query?" & options.apiQuery())
      paperResponse = await manager.papers.search(options)
      if manager.cancelled(id): return
    manager.store.transaction:
      if provider == "Google Patents":
        for record in patentResponse["results"]:
          if found.len >= 10: break
          found.add(manager.savePatent(id, record, false))
        query["total"] = patentResponse["total"]
        query["hasMore"] = patentResponse["has_next"]
      else:
        for paper in paperResponse.papers:
          if found.len >= 10: break
          found.add(manager.savePaper(id, paper))
        query["total"] = %paperResponse.total
        query["hasMore"] = %(paperResponse.total > found.len)
      for oid in found:
        manager.connect(id, queryId, oid, "name_search_hit", %*{
          "evidence": "provider_search_result", "queryName": name,
          "provider": provider, "queryUrl": query["queryUrl"], "identityResolved": false})
      query["returned"] = %found.len
      query["state"] = %"completed"
      query["completedAt"] = %stamp()
      if query.hasKey("error"): query.delete("error")
      manager.putNode(id, NodeRecord(oid: queryId, label: "Name search", properties: query))
    manager.event(id, provider & " returned " & $found.len & " name-search candidates for “" & name & "”.")
  except CatchableError as error:
    query["state"] = %"failed"
    query["error"] = %error.msg
    manager.putNode(id, NodeRecord(oid: queryId, label: "Name search", properties: query))
    manager.event(id, provider & ": " & error.msg)
    let properties = manager.job(id).properties
    properties["failures"] = %(properties["failures"].getInt + 1)
    manager.save(id, properties)

proc searchBoth(manager: InvestigationManager; id, mentionId, name: string): Future[void] {.async.} =
  if name.len == 0 or name.len > 200:
    manager.event(id, "Skipped a name outside the providers’ 1–200 byte search limit.")
    return
  # Only these two adapters can issue network requests. Each retains its own paced queue.
  let google = manager.searchName(id, mentionId, name, "Google Patents")
  let arxiv = manager.searchName(id, mentionId, name, "arXiv")
  var failure: ref CatchableError
  try: await google
  except CatchableError as error: failure = error
  try: await arxiv
  except CatchableError as error:
    if failure.isNil: failure = error
  if not failure.isNil: raise failure

proc expandRecord(manager: InvestigationManager; id, oid, spelling: string): Future[void] {.async.} =
  var node = manager.store.getNode(id, oid).get
  if node.label == "Name mention":
    let name = if spelling.len > 0: spelling else: node.properties["originalName"].getStr
    await manager.searchBoth(id, oid, name)
    return
  if node.label == "Patent" and not node.properties{"detailLoaded"}.getBool:
    let publication = node.properties["publicationNumber"].getStr
    if not manager.reserve(id, "Reading inventors and assignees from " & publication & "…"): return
    let data = await manager.patents.lookup(publication)
    if manager.stopped(id): return
    manager.store.transaction:
      discard manager.savePatent(id, data, true)
    node = manager.store.getNode(id, oid).get
    manager.event(id, "Saved patent metadata and " & $data["inventors"].len & " inventor names.")
  if node.label == "Paper":
    if node.properties{"providerRecord"}==nil:
      let identifier = node.properties["arxivId"].getStr
      if not manager.reserve(id,"Reading paper metadata from arXiv…"): return
      var options = defaultOptions()
      options.query = identifier; options.field = "id"
      let data = await manager.papers.search(options)
      if manager.stopped(id): return
      var found = false
      for paper in data.papers:
        if paper.id==identifier or (not identifier.contains('v') and paper.id.startsWith(identifier & "v")):
          discard manager.savePaper(id,paper,oid)
          found = true
          break
      if not found: raise apiError("This paper was not returned by arXiv.",404)
      node = manager.store.getNode(id,oid).get
    # The full source author list is preserved in providerRecord. Expose coauthors
    # when the paper is selected, keeping the first inventor expansion bounded.
    manager.store.transaction:
      for name in node.properties["providerRecord"]["authors"]:
        if name.getStr.strip.len > 0:
          discard manager.mention(id, oid, name.getStr, "author", node.properties["sourceUrl"].getStr)
  var mentions: seq[NodeRecord]
  for record in manager.store.streamStoredNodes(id):
    if record.label == "Name mention" and record.properties{"sourceRecord"}.getStr == oid:
      mentions.add(record)
  if mentions.len == 0: manager.event(id, "No individual names were supplied for this record.")
  for index, record in mentions:
    if manager.stopped(id): break
    if index >= manager.limits.maxNames:
      manager.event(id, "Automatic name limit reached. Select remaining names to search them individually.")
      break
    await manager.searchBoth(id, record.oid, record.properties["originalName"].getStr)

proc run(manager: InvestigationManager; id, oid, spelling: string): Future[void] {.async.} =
  # Yield so POST returns immediately and the browser can display the seed first.
  await sleepAsync(1)
  try:
    await manager.expandRecord(id, oid, spelling)
    if not manager.stopped(id):
      var failures = 0
      for node in manager.store.streamStoredNodes(id):
        if node.label == "Name search" and node.properties{"state"}.getStr == "failed": inc failures
      manager.setState(id, if failures > 0: "partial" else: "completed")
      manager.event(id, "Expansion finished. Select a patent, paper, or name to continue.")
  except CatchableError as error:
    manager.setState(id, "failed")
    manager.event(id, error.msg)
  finally:
    var unfinished: seq[NodeRecord]
    for node in manager.store.streamStoredNodes(id):
      if node.label == "Name search" and node.properties{"state"}.getStr in ["running", "pending"]:
        unfinished.add(node)
    for node in unfinished:
      node.properties["state"] = manager.job(id).properties["state"]
      manager.putNode(id, node)
    manager.active.del(id)

proc ensureIdle(manager: InvestigationManager; id = "") =
  if id in manager.active:
    raise apiError("This investigation is already expanding. Wait before expanding it again.",409)
  if manager.active.len>=2:
    raise apiError("Two investigations are expanding. Wait for one to finish before starting another.",409)

proc launch(manager: InvestigationManager; id, oid, spelling: string) =
  manager.ensureIdle(id)
  manager.setState(id, "running")
  manager.task = manager.run(id, oid, spelling)
  manager.active[id] = manager.task

proc startInvestigation*(manager: InvestigationManager; publication: string; source = "patents"): string =
  let publication = documentId(source,publication)
  manager.ensureIdle()
  result = "inv-"
  for value in urandom(12): result.add(toHex(value, 2).toLowerAscii)
  let seed = recordId(result, if source=="arxiv":"paper" else:"patent", publication)
  manager.store.transaction:
    manager.store.ensureDataset(result)
    manager.save(result, %*{"schema": InvestigationSchema, "name": publication & " investigation",
      "seed": seed, "publicationNumber": publication, "state": "pending", "requests": 0,
      "failures": 0, "createdAt": stamp(), "events": [], "limits": %manager.limits,
      "namePolicy": "Provider names preserved; optional spellings are user supplied. No identity resolution."})
    if source=="patents":
      manager.putNode(result, NodeRecord(oid: seed, label: "Patent", properties: %*{
        "title": publication, "publicationNumber": publication, "detailLoaded": false,
        "source": "Google Patents", "sourceUrl": patentUrl(publication)}))
    else:
      manager.putNode(result, NodeRecord(oid:seed,label:"Paper",properties: %*{
        "title":publication,"arxivId":publication,"source":"arXiv","sourceUrl":"https://arxiv.org/abs/" & publication}))
    manager.connect(result, rootId(result), seed, "investigates", %*{"evidence": "user_selection"})
  manager.launch(result, seed, "")

proc expandInvestigation*(manager: InvestigationManager; id, oid: string; spelling = "") =
  discard manager.job(id)
  let node = manager.store.getNode(id, oid)
  if node.isNone or node.get.label notin ["Patent", "Paper", "Name mention"]:
    raise apiError("Select a patent, paper, or individual name from this investigation.", 400)
  if spelling.len > 200 or (spelling.len > 0 and node.get.label != "Name mention"):
    raise apiError("A search spelling is allowed only for an individual name (up to 200 bytes).", 400)
  manager.launch(id, oid, spelling.strip)

proc cancelInvestigation*(manager: InvestigationManager; id: string) =
  discard manager.job(id)
  if id in manager.active and not manager.stopped(id):
    manager.setState(id, "cancelled")
    manager.event(id, "Stopped. An in-flight provider request may finish; no further results will be added.")

proc investigationSnapshot*(manager: InvestigationManager; id: string): JsonNode =
  let job = manager.job(id)
  result = %*{"id": id, "job": job.properties, "nodes": [], "links": [],
    "busy": id in manager.active}
  for node in manager.store.streamStoredNodes(id):
    result["nodes"].add(%*{"id": node.oid, "label": node.label, "properties": node.properties})
  for edge in manager.store.streamStoredEdges(id):
    result["links"].add(%*{"id": edge.oid, "source": edge.source, "target": edge.target,
      "label": edge.label, "properties": edge.properties})

proc listInvestigations*(manager: InvestigationManager): JsonNode =
  manager.store.recentInvestigations(InvestigationSchema)

## Saved drill-down evidence and reports, separate from original node properties.
import std/json
import sqlite, driver
import ../api/dto
import ../api_errors

proc requireNode*(store: GraphStore; dataset, oid: string): NodeRecord =
  let node = store.getNode(dataset, oid)
  if node.isNone: raise apiError("This node was not found in the selected dataset.", 404)
  node.get

proc authorDocuments*(store: GraphStore; dataset, oid: string; limit = 50; offset = 0): JsonNode =
  let author = store.requireNode(dataset, oid)
  if author.label notin ["Name mention", "Name search", "Person", "Author", "Inventor"]:
    raise newException(ValueError, "Select an author, inventor, or name-search node.")
  if limit < 1 or limit > 100 or offset < 0 or offset > 100_000:
    raise newException(ValueError, "Invalid author table page.")
  # Traverse only explicit saved edges from this exact node, never same-name nodes.
  const matches = """WITH matches(oid,basis) AS (
    SELECT source,'source_listed' FROM edges WHERE dataset=? AND target=? AND label IN ('lists_author','lists_inventor')
    UNION ALL
    SELECT target,'source_listed' FROM edges WHERE dataset=? AND source=? AND label IN ('authored','invented','AUTHORED','INVENTED')
    UNION ALL
    SELECT hit.target,'name_search_candidate' FROM edges q JOIN edges hit
      ON hit.dataset=q.dataset AND hit.source=q.target AND hit.label='name_search_hit'
      WHERE q.dataset=? AND q.source=? AND q.label='searched_name'
    UNION ALL
    SELECT target,'name_search_candidate' FROM edges WHERE dataset=? AND source=? AND label='name_search_hit'
  ), docs AS (
    SELECT n.oid,n.label,n.properties,
      CASE WHEN max(m.basis='source_listed') THEN 'source_listed' ELSE 'name_search_candidate' END basis
    FROM matches m JOIN nodes n ON n.oid=m.oid AND n.dataset=?
    WHERE n.label IN ('Paper','Patent') GROUP BY n.oid
  ) """
  let args = @[dataset,oid,dataset,oid,dataset,oid,dataset,oid,dataset]
  let total = store.db.scalarInt(matches & "SELECT count(*) FROM docs", args)
  var rows = newJArray()
  for row in store.db.rows(matches & "SELECT oid,label,properties,basis FROM docs ORDER BY json_extract(properties,'$.title'),oid LIMIT ? OFFSET ?", args & @[$limit,$offset]):
    rows.add(%*{"node":nodeDto(nodeFromRow(row[0..2])), "basis":row[3]})
  let root = store.getNode(dataset, dataset & ":investigation")
  let canSearch = author.label == "Name mention" and root.isSome and root.get.properties{"schema"}.getStr == "turncoat/investigation/v1"
  result = %*{"author":nodeDto(author), "rows":rows, "meta":{"total":total, "offset":offset, "returned":rows.len,
    "nextOffset":offset+rows.len, "hasMore":offset+rows.len<total}, "canSearch":canSearch,
    "job":(if root.isSome: root.get.properties else: newJNull())}

proc saveReport*(store: GraphStore; report: JsonNode) =
  let dataset = report{"dataset"}.getStr
  let oid = report{"node"}.getStr
  discard store.requireNode(dataset, oid)
  let kind = report{"kind"}.getStr
  if report.kind != JObject or kind notin ["keywords", "ai"] or
      report{"id"}.getStr.len notin 1..100 or report{"createdAt"}.getStr.len == 0 or ($report).len > 1_000_000:
    raise newException(ValueError, "Invalid or oversized analysis report.")
  store.db.execute("INSERT INTO analysis_reports(id,dataset,node,kind,created_at,report) VALUES(?,?,?,?,?,?)",
    @[report["id"].getStr,dataset,oid,kind,report["createdAt"].getStr,$report])

proc listReports*(store: GraphStore; dataset, oid: string; limit = 20; offset = 0): JsonNode =
  discard store.requireNode(dataset, oid)
  if limit < 1 or limit > 100 or offset < 0 or offset > 100_000:
    raise newException(ValueError, "Invalid report page.")
  var items = newJArray()
  let total = store.db.scalarInt("SELECT count(*) FROM analysis_reports WHERE dataset=? AND node=?", @[dataset,oid])
  for row in store.db.rows("SELECT id,kind,created_at,json_extract(report,'$.preset'),json_extract(report,'$.query') FROM analysis_reports WHERE dataset=? AND node=? ORDER BY created_at DESC,rowid DESC LIMIT ? OFFSET ?", @[dataset,oid,$limit,$offset]):
    items.add(%*{"id":row[0], "kind":row[1], "createdAt":row[2], "preset":row[3], "query":row[4]})
  %*{"items":items, "total":total, "hasMore":offset+items.len<total, "nextOffset":offset+items.len}

proc loadReport*(store: GraphStore; dataset, oid, id: string): JsonNode =
  discard store.requireNode(dataset, oid)
  for row in store.db.rows("SELECT report FROM analysis_reports WHERE dataset=? AND node=? AND id=?", @[dataset,oid,id]):
    return parseJson(row[0])
  raise apiError("This report was not found for the selected document.", 404)

proc savedNameSearches*(store: GraphStore; dataset = ""; limit = 50; offset = 0): JsonNode =
  if dataset.len > 0: validateDataset(dataset)
  if limit < 1 or limit > 100 or offset < 0 or offset > 100_000:
    raise newException(ValueError,"Invalid search history page.")
  let where = " WHERE label='Name search'" & (if dataset.len>0:" AND dataset=?" else:"")
  let args = if dataset.len>0: @[dataset] else: @[]
  let total = store.db.scalarInt("SELECT count(*) FROM nodes" & where,args)
  var items = newJArray()
  for row in store.db.rows("SELECT dataset,oid,properties FROM nodes" & where & " ORDER BY json_extract(properties,'$.startedAt') DESC,oid LIMIT ? OFFSET ?",args & @[$limit,$offset]):
    items.add(%*{"dataset":row[0],"node":row[1],"search":parseJson(row[2])})
  %*{"items":items,"total":total,"hasMore":offset+items.len<total,"nextOffset":offset+items.len}

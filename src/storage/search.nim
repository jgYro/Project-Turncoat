import std/[strutils, unicode, json]
import sqlite, driver

type
  SearchUnavailable* = object of CatchableError
  SearchPage* = object
    nodes*: seq[NodeRecord]
    total*, offset*, limit*: int

proc searchNodes*(store: GraphStore; dataset, query: string; limit = 30;
    labels: seq[string] = @[]; offset = 0): SearchPage =
  validateDataset(dataset)
  validatePage(limit, offset)
  if not store.ftsEnabled: raise newException(SearchUnavailable, "FTS5 search is unavailable or disabled")
  if query.len == 0 or query.len > 512 or validateUtf8(query) != -1 or '\0' in query:
    raise newException(ValueError, "Search query must be valid UTF-8, 1..512 bytes")
  if labels.len > 20: raise newException(ValueError, "At most 20 label filters are allowed")
  for label in labels: validateLabel(label)
  var terms: seq[string]
  for term in strutils.splitWhitespace(query):
    terms.add("\"" & term.replace("\"", "\"\"") & "\"")
  if terms.len == 0 or terms.len > 32: raise newException(ValueError, "Search requires 1..32 terms")
  let expression = terms.join(" AND ")
  let labelJson = $(%labels)
  let args = @[dataset, expression, $labels.len, labelJson]
  const predicate = """ FROM node_fts JOIN nodes n ON n.rowid=node_fts.rowid
    WHERE n.dataset=? AND node_fts MATCH ? AND
    (? = '0' OR n.label IN (SELECT value FROM json_each(?)))"""
  result = SearchPage(limit: limit, offset: offset,
    total: store.db.scalarInt("SELECT count(*)" & predicate, args))
  for row in store.db.rows("SELECT n.oid,n.label,n.properties" & predicate &
      " ORDER BY n.oid LIMIT ? OFFSET ?", args & @[$limit, $offset]):
    result.nodes.add(nodeFromRow(row))

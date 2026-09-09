## Immutable, revocable snapshots. No provider or model calls occur here.
import std/[json, strutils, sysrand, times]
import sqlite, driver
import ../api_errors

const MaxShareBytes* = 8_000_000

proc validShareToken*(token: string): bool =
  token.len == 64 and token.allCharsInSet({'0'..'9','a'..'f'})

proc createShare*(store: GraphStore; dataset: string; includeReports = true): JsonNode =
  validateDataset(dataset)
  var snapshot = %*{"schema":"turncoat-share-v1","dataset":dataset,"nodes":[],"links":[],"reports":[],"reportsOmitted":0}
  let created = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  snapshot["createdAt"] = %created
  driver.snapshot(store.db):
    let root = store.getNode(dataset,dataset & ":investigation")
    if root.isNone or root.get.properties{"schema"}.getStr != "turncoat/investigation/v1":
      raise apiError("Select a saved investigation to share.",404)
    if store.countNodes(dataset)>2000 or store.countEdges(dataset)>5000:
      raise apiError("This investigation exceeds the sharing limit.",413)
    snapshot["job"] = root.get.properties
    for node in store.streamStoredNodes(dataset):
      snapshot["nodes"].add(%*{"id":node.oid,"label":node.label,"properties":node.properties})
    for edge in store.streamStoredEdges(dataset):
      snapshot["links"].add(%*{"id":edge.oid,"source":edge.source,"target":edge.target,"label":edge.label,"properties":edge.properties})
    var size = ($snapshot).len
    if size>MaxShareBytes: raise apiError("This graph is too large to share as a snapshot.",413)
    if includeReports:
      # One latest keyword scan and one latest AI review per document.
      const latest = " FROM analysis_reports r WHERE dataset=? AND NOT EXISTS (SELECT 1 FROM analysis_reports n WHERE n.dataset=r.dataset AND n.node=r.node AND n.kind=r.kind AND n.rowid>r.rowid)"
      let total = store.db.scalarInt("SELECT count(*)" & latest,@[dataset])
      for row in store.db.rows("SELECT report" & latest & " ORDER BY rowid DESC LIMIT 100",@[dataset]):
        if size+row[0].len+1024 <= MaxShareBytes:
          snapshot["reports"].add(parseJson(row[0]));size += row[0].len+1
      snapshot["reportsOmitted"] = %(total-snapshot["reports"].len)
    snapshot["includesReports"] = %includeReports
  var token = ""
  for b in urandom(32): token.add(toHex(b,2).toLowerAscii)
  store.db.execute("INSERT INTO investigation_shares(token,dataset,created_at,snapshot) VALUES(?,?,?,?)",@[token,dataset,created,$snapshot])
  %*{"token":token,"path":"/shared/" & token,"createdAt":created,"reports":snapshot["reports"].len,"reportsOmitted":snapshot["reportsOmitted"]}

proc loadShare*(store: GraphStore; token: string): JsonNode =
  if validShareToken(token):
    for row in store.db.rows("SELECT snapshot FROM investigation_shares WHERE token=?",@[token]): return parseJson(row[0])
  raise apiError("This shared investigation is unavailable or its link was revoked.",404)

proc listShares*(store: GraphStore; dataset: string): JsonNode =
  validateDataset(dataset)
  result = newJArray()
  for row in store.db.rows("SELECT token,created_at FROM investigation_shares WHERE dataset=? ORDER BY created_at DESC,rowid DESC",@[dataset]):
    result.add(%*{"token":row[0],"path":"/shared/" & row[0],"createdAt":row[1]})

proc revokeShare*(store: GraphStore; dataset, token: string) =
  validateDataset(dataset)
  if not validShareToken(token): raise newException(ValueError,"Invalid sharing link.")
  store.db.execute("DELETE FROM investigation_shares WHERE dataset=? AND token=?",@[dataset,token])

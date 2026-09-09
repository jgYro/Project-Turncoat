## Generic extraction and transactional FTS indexing; no label-specific fields.
import std/[json, strutils]
import ../model/graph_record
import driver

type TextExtractor* = proc(node: NodeRecord): string {.gcsafe.}

proc collectText(value: JsonNode; parts: var seq[string]) =
  case value.kind
  of JString: parts.add(value.getStr)
  of JObject:
    for key, child in value: collectText(child, parts)
  of JArray:
    for child in value: collectText(child, parts)
  else: discard

proc searchableText*(node: NodeRecord): string {.gcsafe.} =
  var parts = @[node.oid, node.label]
  collectText(canonicalJson(node.properties), parts)
  parts.join(" ")

proc initializeSearch*(db: Connection; enabled: bool): bool =
  if not enabled: return false
  try:
    db.transaction:
      let exists = db.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='node_fts'") > 0
      db.execute("""CREATE VIRTUAL TABLE IF NOT EXISTS node_fts USING fts5(
        search_text, content='nodes', content_rowid='rowid', tokenize='unicode61')""")
      db.execute("""CREATE TRIGGER IF NOT EXISTS nodes_fts_insert AFTER INSERT ON nodes BEGIN
        INSERT INTO node_fts(rowid,search_text) VALUES(new.rowid,new.search_text); END""")
      db.execute("""CREATE TRIGGER IF NOT EXISTS nodes_fts_delete AFTER DELETE ON nodes BEGIN
        INSERT INTO node_fts(node_fts,rowid,search_text) VALUES('delete',old.rowid,old.search_text); END""")
      db.execute("""CREATE TRIGGER IF NOT EXISTS nodes_fts_update AFTER UPDATE ON nodes BEGIN
        INSERT INTO node_fts(node_fts,rowid,search_text) VALUES('delete',old.rowid,old.search_text);
        INSERT INTO node_fts(rowid,search_text) VALUES(new.rowid,new.search_text); END""")
      if not exists: db.execute("INSERT INTO node_fts(node_fts) VALUES('rebuild')")
    result = true
  except StorageError as error:
    if "no such module: fts5" notin error.msg: raise

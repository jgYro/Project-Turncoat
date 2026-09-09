import std/[json, options, os, sets]
import ../model/graph_record
import driver, schema, search_index
export graph_record, options, StorageError, TextExtractor

type
  GraphStore* = ref object
    db*: Connection # Internal storage connection; API/graph modules use methods below.
    ftsEnabled*: bool
    extractor: TextExtractor
  DatasetInfo* = object
    id*: string
    nodes*, edges*: int
  EdgePage* = object
    edges*: seq[EdgeRecord]
    total*, offset*, limit*: int
  Neighborhood* = object
    records*: GraphRecords
    total*, offset*, limit*: int # counts refer to incident edges, including self-loops once

proc openStore*(path: string; enableFts = true; extractor: TextExtractor = searchableText): GraphStore =
  if path.len == 0 or '\0' in path: raise newException(ValueError, "Invalid database path")
  if path != ":memory:" and path.parentDir.len > 0: createDir(path.parentDir)
  new(result)
  result.db = connect(path)
  try:
    result.db.initializeSchema()
    result.ftsEnabled = result.db.initializeSearch(enableFts)
    result.extractor = extractor
  except:
    result.db.close()
    raise

proc close*(store: GraphStore) = store.db.close()

template transaction*(store: GraphStore; body: untyped) =
  driver.transaction(store.db): body

template snapshot*(store: GraphStore; body: untyped) =
  driver.snapshot(store.db): body

proc ensureDataset*(store: GraphStore; dataset: string) =
  validateDataset(dataset)
  store.db.execute("INSERT INTO datasets(id) VALUES(?) ON CONFLICT(id) DO NOTHING", @[dataset])

proc datasetExists*(store: GraphStore; dataset: string): bool =
  validateDataset(dataset)
  store.db.scalarInt("SELECT count(*) FROM datasets WHERE id=?", @[dataset]) > 0

proc countNodes*(store: GraphStore; dataset: string): int =
  validateDataset(dataset)
  store.db.scalarInt("SELECT count(*) FROM nodes WHERE dataset=?", @[dataset])

proc countEdges*(store: GraphStore; dataset: string): int =
  validateDataset(dataset)
  store.db.scalarInt("SELECT count(*) FROM edges WHERE dataset=?", @[dataset])

proc datasets*(store: GraphStore): seq[DatasetInfo] =
  for row in store.db.rows("SELECT id FROM datasets ORDER BY id"):
    result.add(DatasetInfo(id: row[0], nodes: store.countNodes(row[0]), edges: store.countEdges(row[0])))

proc nodeFromRow*(row: Row): NodeRecord =
  NodeRecord(oid: row[0], label: row[1], properties: parseJson(row[2]))

proc edgeFromRow(row: Row): EdgeRecord =
  EdgeRecord(oid: row[0], source: row[1], target: row[2], label: row[3], properties: parseJson(row[4]))

proc propertyText(record: NodeRecord | EdgeRecord): string =
  # Validate the complete portable record's size so every stored record can export.
  let portable = record.toJson()
  if ($portable).len > MaxRecordBytes: raise newException(ValueError, "Record exceeds 1 MiB")
  $portable["properties"]

proc writeNode(store: GraphStore; dataset: string; node: NodeRecord; upsert: bool) =
  validateDataset(dataset)
  node.validate()
  let properties = propertyText(node)
  let query = if upsert:
    """INSERT INTO nodes(oid,dataset,label,properties,search_text) VALUES(?,?,?,?,?)
       ON CONFLICT(oid) DO UPDATE SET label=excluded.label, properties=excluded.properties,
       search_text=excluded.search_text"""
  else: "INSERT INTO nodes(oid,dataset,label,properties,search_text) VALUES(?,?,?,?,?)"
  store.db.execute(query, @[node.oid, dataset, node.label, properties, store.extractor(node)])

proc insertNode*(store: GraphStore; dataset: string; node: NodeRecord) = store.writeNode(dataset, node, false)
proc upsertNode*(store: GraphStore; dataset: string; node: NodeRecord) = store.writeNode(dataset, node, true)

proc getNode*(store: GraphStore; dataset, oid: string): Option[NodeRecord] =
  validateDataset(dataset)
  validateOid(oid)
  for row in store.db.rows("SELECT oid,label,properties FROM nodes WHERE dataset=? AND oid=?", @[dataset, oid]):
    return some(nodeFromRow(row))

proc deleteNode*(store: GraphStore; dataset, oid: string) =
  validateDataset(dataset)
  validateOid(oid)
  store.db.execute("DELETE FROM nodes WHERE dataset=? AND oid=?", @[dataset, oid])

proc writeEdge(store: GraphStore; dataset: string; edge: EdgeRecord; upsert: bool) =
  validateDataset(dataset)
  edge.validate()
  let properties = propertyText(edge)
  let query = if upsert:
    """INSERT INTO edges(oid,dataset,source,target,label,properties) VALUES(?,?,?,?,?,?)
       ON CONFLICT(oid) DO UPDATE SET source=excluded.source,target=excluded.target,
       label=excluded.label,properties=excluded.properties"""
  else: "INSERT INTO edges(oid,dataset,source,target,label,properties) VALUES(?,?,?,?,?,?)"
  store.db.execute(query, @[edge.oid, dataset, edge.source, edge.target, edge.label, properties])

proc insertEdge*(store: GraphStore; dataset: string; edge: EdgeRecord) = store.writeEdge(dataset, edge, false)
proc upsertEdge*(store: GraphStore; dataset: string; edge: EdgeRecord) = store.writeEdge(dataset, edge, true)

proc getEdge*(store: GraphStore; dataset, oid: string): Option[EdgeRecord] =
  validateDataset(dataset)
  validateOid(oid)
  for row in store.db.rows("SELECT oid,source,target,label,properties FROM edges WHERE dataset=? AND oid=?", @[dataset, oid]):
    return some(edgeFromRow(row))

proc deleteEdge*(store: GraphStore; dataset, oid: string) =
  validateDataset(dataset)
  validateOid(oid)
  store.db.execute("DELETE FROM edges WHERE dataset=? AND oid=?", @[dataset, oid])

proc validatePage*(limit, offset: int) =
  if limit < 1 or limit > 1000 or offset < 0 or offset > 1_000_000:
    raise newException(ValueError, "limit must be 1..1000; offset must be 0..1000000")

proc getEdgesForNode*(store: GraphStore; dataset, oid: string; limit = 100; offset = 0): EdgePage =
  validateDataset(dataset)
  validateOid(oid)
  validatePage(limit, offset)
  result.limit = limit
  result.offset = offset
  result.total = store.db.scalarInt("""SELECT count(*) FROM (
    SELECT oid FROM edges WHERE dataset=? AND source=? UNION
    SELECT oid FROM edges WHERE dataset=? AND target=?)""", @[dataset, oid, dataset, oid])
  for row in store.db.rows("""SELECT oid,source,target,label,properties FROM edges WHERE oid IN (
    SELECT oid FROM edges WHERE dataset=? AND source=? UNION
    SELECT oid FROM edges WHERE dataset=? AND target=?) ORDER BY oid LIMIT ? OFFSET ?""",
      @[dataset, oid, dataset, oid, $limit, $offset]):
    result.edges.add(edgeFromRow(row))

proc getNeighbors*(store: GraphStore; dataset, oid: string; limit = 100; offset = 0): Neighborhood =
  let root = store.getNode(dataset, oid)
  if root.isNone: raise newException(ValueError, "Node does not exist in dataset")
  let page = store.getEdgesForNode(dataset, oid, limit, offset)
  result = Neighborhood(total: page.total, offset: offset, limit: limit)
  result.records.nodes.add(root.get)
  result.records.edges = page.edges
  var seen = [oid].toHashSet
  for edge in page.edges:
    for other in [edge.source, edge.target]:
      if other notin seen:
        result.records.nodes.add(store.getNode(dataset, other).get)
        seen.incl(other)

iterator streamStoredNodes*(store: GraphStore; dataset: string): NodeRecord =
  validateDataset(dataset)
  for row in store.db.rows("SELECT oid,label,properties FROM nodes WHERE dataset=? ORDER BY oid", @[dataset]):
    yield nodeFromRow(row)

iterator streamStoredEdges*(store: GraphStore; dataset: string): EdgeRecord =
  validateDataset(dataset)
  for row in store.db.rows("SELECT oid,source,target,label,properties FROM edges WHERE dataset=? ORDER BY oid", @[dataset]):
    yield edgeFromRow(row)

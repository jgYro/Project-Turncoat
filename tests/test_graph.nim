import std/[unittest, json, os, sequtils, strutils, tempfiles]
import model/graph_record
import storage/[sqlite, jsonl, search, driver]
import graph/[adapter, loader, traversal]
import api/[dto, service]
import config

const Fixture = "tests/fixtures/graph/demo.jsonl"
const Person = "demo:person:1"

proc node(id: string; name = "Test"): NodeRecord =
  NodeRecord(oid: id, label: "Custom", properties: %*{"name": name})

proc edge(id, source, target: string): EdgeRecord =
  EdgeRecord(oid: id, source: source, target: target, label: "RELATES", properties: %*{})

suite "Canonical graph records":
  test "NodeRecord deterministic nested serialization":
    let n = NodeRecord(oid: "source:kind:123", label: "Any label", properties:
      %*{"z": [true, newJNull(), {"b": 2, "a": 1}], "a": "O'Reilly \"quoted\" 漢字"})
    let encoded = $n.toJson()
    check encoded.find("\"a\"") < encoded.find("\"z\"")
    check parseRecord(encoded).node == n
    check encoded == $parseRecord(encoded).node.toJson()
  test "EdgeRecord serialization preserves endpoints and properties":
    let e = EdgeRecord(oid: "relation:1", source: "a:1", target: "b:2", label: "WHATEVER", properties: %*{"weight": 2.5})
    check parseRecord($e.toJson()).edge == e
  test "Invalid types, identifiers, properties and dataset names":
    for raw in ["null", "[]", "{}", "{", """{"type":"bad","oid":"a","label":"L","properties":{}}""",
      """{"type":"node","oid":"a","label":"L","properties":[]}"""]:
      expect CatchableError: discard parseRecord(raw)
    for id in ["", "a b", "a\n", repeat('x', 513)]:
      expect ValueError: validateOid(id)
    for id in ["", "../x", "a/b", "a b", "x'; DROP TABLE nodes;--"]:
      expect ValueError: validateDataset(id)
  test "deep JSON properties and nonfinite numbers are rejected":
    let nested = """{"type":"node","oid":"deep","label":"L","properties":{"v":""" &
      repeat('[', 70) & "0" & repeat(']', 70) & "}}"
    expect ValueError: discard parseRecord(nested)
    expect ValueError: discard parseRecord("""{"type":"node","oid":"inf","label":"L","properties":{"v":1e999}}""")

suite "SQLite, JSONL and graph operations":
  setup:
    let directory = createTempDir("graph-tests-", "")
    let store = openStore(directory / "app.db")
    store.ensureDataset("demo")
  teardown:
    store.close()
    removeDir(directory)

  test "schema is initialized and persists after reopening":
    store.insertNode("demo", node("test:1"))
    let reopened = openStore(directory / "app.db")
    check reopened.getNode("demo", "test:1").isSome
    check reopened.db.scalarInt("PRAGMA foreign_keys") == 1
    check reopened.db.scalarInt("PRAGMA user_version") == 1
    reopened.close()
  test "insert node and edge with bound quotes and Unicode":
    store.insertNode("demo", node("test:'1", "O'Reilly 漢字"))
    store.insertNode("demo", node("test:2"))
    store.insertEdge("demo", edge("edge:1", "test:'1", "test:2"))
    check store.getNode("demo", "test:'1").get.properties["name"].getStr == "O'Reilly 漢字"
    check store.getEdge("demo", "edge:1").get.target == "test:2"
    check store.countNodes("demo") == 2
    check store.countEdges("demo") == 1
  test "insert duplicate errors leave connection usable":
    store.insertNode("demo", node("test:1"))
    expect StorageError: store.insertNode("demo", node("test:1"))
    store.insertNode("demo", node("test:2"))
    check store.countNodes("demo") == 2
  test "node upsert replaces properties and updates FTS atomically":
    store.upsertNode("demo", node("test:1", "Beforeword"))
    store.upsertNode("demo", node("test:1", "Afterword"))
    check store.countNodes("demo") == 1
    check store.getNode("demo", "test:1").get.properties["name"].getStr == "Afterword"
    check store.searchNodes("demo", "Beforeword").total == 0
    check store.searchNodes("demo", "Afterword").total == 1
  test "edge upsert changes endpoints, label and properties":
    for id in ["a", "b", "c"]: store.insertNode("demo", node(id))
    store.insertEdge("demo", edge("e", "a", "b"))
    var changed = edge("e", "c", "a")
    changed.label = "NEW_LABEL"
    changed.properties = %*{"changed": true}
    store.upsertEdge("demo", changed)
    check store.getEdge("demo", "e").get == changed
    check store.getEdgesForNode("demo", "b").total == 0
    check store.getEdgesForNode("demo", "c").total == 1
  test "foreign keys, global OID uniqueness and dataset isolation":
    store.ensureDataset("other")
    store.insertNode("demo", node("a"))
    store.insertNode("other", node("b"))
    expect StorageError: store.upsertNode("other", node("a"))
    expect StorageError: store.insertEdge("demo", edge("e", "a", "b"))
    expect StorageError: store.insertEdge("demo", edge("e", "a", "missing"))
    expect StorageError: store.insertEdge("demo", edge("a", "a", "a"))
    store.insertEdge("demo", edge("e", "a", "a"))
    expect StorageError: store.insertNode("demo", node("e"))
    expect StorageError: store.upsertEdge("other", edge("e", "b", "b"))
    check store.getNode("other", "a").isNone
    check store.getEdge("other", "e").isNone
    check store.getNeighbors("other", "b").records.nodes.len == 1
    check store.searchNodes("other", "Test").total == 1
  test "bidirectional neighbors paginate parallel edges and self loops once":
    for id in ["a", "b", "c"]: store.insertNode("demo", node(id))
    for e in [edge("e1", "a", "b"), edge("e2", "b", "a"), edge("e3", "a", "a"), edge("e4", "c", "a")]:
      store.insertEdge("demo", e)
    let first = store.getNeighbors("demo", "a", 2)
    check first.total == 4
    check first.records.nodes.len == 2
    check first.records.edges.len == 2
    let second = store.getNeighbors("demo", "a", 2, 2)
    check second.records.edges.mapIt(it.oid) == @["e3", "e4"]
    check store.getNeighbors("demo", "a", 2, 4).records.edges.len == 0
    let graph = store.getNeighbors("demo", "a").records.toGrim()
    check graph.neighbors("a") == @["a", "b", "c"]
  test "delete node cascades edges and removes search text":
    store.insertNode("demo", node("a", "Deleteword"))
    store.insertNode("demo", node("b"))
    store.insertEdge("demo", edge("e", "a", "b"))
    store.deleteNode("demo", "a")
    check store.countEdges("demo") == 0
    check store.searchNodes("demo", "Deleteword").total == 0
    store.deleteEdge("demo", "missing")
  test "batch transaction rolls back nodes and FTS":
    expect StorageError:
      store.transaction:
        store.insertNode("demo", node("a", "Rollbackword"))
        store.insertEdge("demo", edge("e", "a", "absent"))
    check store.countNodes("demo") == 0
    check store.searchNodes("demo", "Rollbackword").total == 0
  test "JSONL round trip, streaming and duplicate imports":
    let report = store.importGraph("demo", Fixture, 2)
    check report.nodes == 4
    check report.edges == 3
    discard store.importGraph("demo", Fixture)
    check store.countNodes("demo") == 4
    check store.countEdges("demo") == 3
    let output = directory / "export.jsonl"
    store.exportGraph("demo", output)
    check toSeq(streamNodes(output)).len == 4
    check toSeq(streamEdges(output)).len == 3
    let other = openStore(directory / "other.db")
    discard other.importGraph("copied", output)
    other.exportGraph("copied", directory / "again.jsonl")
    check readFile(output) == readFile(directory / "again.jsonl")
    other.close()
  test "export refuses overwriting the database and existing files":
    expect ValueError: store.exportGraph("demo", directory / "app.db")
    let output = directory / "export.jsonl"
    writeFile(output, "keep")
    expect ValueError: store.exportGraph("demo", output)
    check readFile(output) == "keep"
    check store.countNodes("demo") == 0
  test "edge-first import uses two passes and CRLF is accepted":
    let path = directory / "edgefirst.jsonl"
    writeFile(path, $edge("e", "a", "b").toJson() & "\r\n" & $node("a").toJson() & "\r\n" & $node("b").toJson())
    discard store.importGraph("demo", path, 1)
    check store.countEdges("demo") == 1
  test "malformed JSONL reports the actual line and committed batches":
    let path = directory / "bad.jsonl"
    writeFile(path, $node("a").toJson() & "\n" & $node("b").toJson() & "\n{bad}\n")
    try:
      discard store.importGraph("demo", path, 1)
      check false
    except ImportError as error:
      check error.line == 3
      check error.committed.nodes == 2
      check "Line 3" in error.msg
    check store.countNodes("demo") == 2
    writeFile(path, "\n")
    expect ImportError: discard toSeq(streamNodes(path))
    writeFile(path, repeat('x', MaxRecordBytes + 1))
    expect ImportError: discard toSeq(streamNodes(path))
  test "failed edge batch rolls back only that batch":
    let path = directory / "missing.jsonl"
    writeFile(path, $node("a").toJson() & "\n" & $edge("e1", "a", "a").toJson() & "\n" & $edge("e2", "a", "missing").toJson())
    try:
      discard store.importGraph("demo", path, 10)
      check false
    except ImportError as error:
      check error.line == 3
      check error.committed.nodes == 1
      check error.committed.edges == 0
    check store.countEdges("demo") == 0
  test "FTS is generic, supports aliases, labels, pagination and literal syntax":
    discard store.importGraph("demo", Fixture)
    check store.ftsEnabled
    check store.searchNodes("demo", "Example").total == 2
    check store.searchNodes("demo", "Example", labels = @["Person"]).nodes[0].oid == Person
    check store.searchNodes("demo", "graph").total == 3
    check store.searchNodes("demo", "graph", limit = 1).nodes.len == 1
    check store.searchNodes("demo", "graph", limit = 1, offset = 1).nodes.len == 1
    check store.searchNodes("demo", "A. Example").nodes[0].oid == Person
    discard store.searchNodes("demo", "\" OR * : -")
    expect ValueError: discard store.searchNodes("demo", " ")
  test "FTS disabled remains a usable store and can later build the index":
    let disabled = openStore(directory / "disabled.db", false)
    disabled.ensureDataset("demo")
    disabled.insertNode("demo", node("a", "Searchable"))
    expect SearchUnavailable: discard disabled.searchNodes("demo", "Searchable")
    check handleRequest(disabled, defaultConfig(), searchOp, "demo", query = "q=Searchable").status == 503
    check disabled.countNodes("demo") == 1
    disabled.close()
    let enabled = openStore(directory / "disabled.db")
    check enabled.searchNodes("demo", "Searchable").total == 1
    enabled.close()
  test "custom search extraction is independent of labels":
    let custom = openStore(directory / "custom.db",
      extractor = proc(n: NodeRecord): string {.gcsafe.} = n.properties["indexMe"].getStr)
    custom.ensureDataset("x")
    custom.insertNode("x", NodeRecord(oid: "x:1", label: "Whatever",
      properties: %*{"indexMe": "Chosenword", "name": "Ignoredword"}))
    check custom.searchNodes("x", "Chosenword").total == 1
    check custom.searchNodes("x", "Ignoredword").total == 0
    custom.close()
  test "bounded subgraph loading and Grim traversal":
    discard store.importGraph("demo", Fixture)
    let loaded = store.loadSubgraph("demo", "demo:institution:1", 1)
    check loaded.graph.nodeCount == 2
    check loaded.graph.edgeCount == 1
    check not loaded.truncated
    check store.loadSubgraph("demo", "demo:institution:1", 2).graph.nodeCount == 4
    check store.loadSubgraph("demo", Person, 0).graph.nodeCount == 1
    check loaded.graph.traverse("demo:institution:1", 1) == @["demo:institution:1", Person]
    check store.loadNodes("demo", @[Person, Person]).nodeCount == 1
    var limits = defaultLimits()
    limits.neighborLimit = 1
    let capped = store.loadSubgraph("demo", Person, 1, limits)
    check capped.truncated
    check capped.expansions[0].total == 3
    limits = defaultLimits()
    limits.maxNodes = 2
    let budget = store.loadSubgraph("demo", Person, 2, limits)
    check budget.budgetTruncated
    check budget.graph.nodeCount <= 2
    expect ValueError: discard store.loadSubgraph("demo", Person, 4)
  test "adapter rejects dangling edges and preserves arbitrary JSON":
    expect ValueError: discard toGrim(GraphRecords(nodes: @[node("a")], edges: @[edge("e", "a", "missing")]))
    discard store.importGraph("demo", Fixture)
    let graph = store.getNeighbors("demo", Person).records.toGrim()
    check graph.records().nodes[0].properties == store.getNode("demo", Person).get.properties
    let dto = graphDto(graph.records())
    check dto["nodes"].len == 4
    check dto["links"].len == 3
    check dto["nodes"][0].hasKey("id")
    check not dto["nodes"][0].hasKey("oid")
    check dto["links"][0]["source"].kind == JString
  test "API DTOs, status codes, dataset isolation and limit metadata":
    discard store.importGraph("demo", Fixture)
    let cfg = defaultConfig()
    check handleRequest(store, cfg, healthOp).body["status"].getStr == "ok"
    check handleRequest(store, cfg, datasetsOp).body["datasets"].len == 1
    check handleRequest(store, cfg, searchOp, "demo", query = "q=Example").status == 200
    let neighbors = handleRequest(store, cfg, neighborsOp, "demo", Person, "limit=1")
    check neighbors.status == 200
    check neighbors.body["meta"]["returned"].getInt == 1
    check neighbors.body["meta"]["total"].getInt == 3
    check neighbors.body["meta"]["truncated"].getBool
    check neighbors.body["meta"]["hasMore"].getBool
    check handleRequest(store, cfg, nodeOp, "other", Person).status == 404
    check handleRequest(store, cfg, nodeOp, "demo", "missing").status == 404
    check handleRequest(store, cfg, subgraphOp, "demo", Person, "depth=4").status == 400
    check handleRequest(store, cfg, neighborsOp, "demo", Person, "limit=0").status == 400
    check handleRequest(store, cfg, neighborsOp, "demo", Person, "offset=-1").status == 400
    check handleRequest(store, cfg, searchOp, "demo", query = "q=x&q=y").status == 400
    check handleRequest(store, cfg, nodeOp, "../demo", Person).status == 400
  test "unknown future schema is refused":
    store.db.execute("PRAGMA user_version=999")
    expect StorageError: discard openStore(directory / "app.db")

## Only this module imports Grim. Its graph and Box types never cross this boundary.
import std/[json, tables, sets, algorithm]
import grim/[graph, entities, box]
import ../model/graph_record

type WorkingGraph* = ref object
  inner: Graph
  records: GraphRecords

proc toGrim*(records: GraphRecords): WorkingGraph =
  new(result)
  result.inner = newGraph("working subgraph")
  var known = initHashSet[string]()
  for node in records.nodes:
    node.validate()
    if node.oid in known: raise newException(ValueError, "Duplicate working graph OID: " & node.oid)
    known.incl(node.oid)
    # Grim's Box cannot store arrays/objects. Keep one lossless JSON string in
    # its private property map and typed canonical JSON for non-Grim consumers.
    discard result.inner.addNode(node.label,
      {"canonical_properties": initBox($canonicalJson(node.properties))}.toTable, oid = node.oid)
    result.records.nodes.add(NodeRecord(oid: node.oid, label: node.label, properties: node.properties.copy))
  let nodeIds = known
  for edge in records.edges:
    edge.validate()
    if edge.oid in known: raise newException(ValueError, "Duplicate working graph OID: " & edge.oid)
    if edge.source notin nodeIds or edge.target notin nodeIds:
      raise newException(ValueError, "Edge endpoint is missing from working graph: " & edge.oid)
    known.incl(edge.oid)
    discard result.inner.addEdge(edge.source, edge.target, edge.label,
      {"canonical_properties": initBox($canonicalJson(edge.properties))}.toTable, oid = edge.oid)
    result.records.edges.add(EdgeRecord(oid: edge.oid, source: edge.source, target: edge.target,
      label: edge.label, properties: edge.properties.copy))

proc records*(graph: WorkingGraph): GraphRecords =
  for node in graph.records.nodes:
    result.nodes.add(NodeRecord(oid: node.oid, label: node.label, properties: node.properties.copy))
  for edge in graph.records.edges:
    result.edges.add(EdgeRecord(oid: edge.oid, source: edge.source, target: edge.target,
      label: edge.label, properties: edge.properties.copy))

proc neighbors*(graph: WorkingGraph; oid: string): seq[string] =
  validateOid(oid)
  var isNode = false
  for node in graph.records.nodes:
    if node.oid == oid: isNode = true
  if not isNode: raise newException(ValueError, "Node is absent from working graph")
  var seen = initHashSet[string]()
  let adjacent = graph.inner.node(oid).neighbors(Direction.OutIn)
  # Grim's closure lacks gcsafe annotations; inspection confirms it reads only
  # this node's adjacency tables. Working graphs stay on the request thread.
  {.cast(gcsafe).}:
    for other in adjacent():
      if other notin seen:
        seen.incl(other)
        result.add(other)
  result.sort()

proc nodeCount*(graph: WorkingGraph): int = graph.inner.numberOfNodes
proc edgeCount*(graph: WorkingGraph): int = graph.inner.numberOfEdges

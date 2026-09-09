import std/[sets, options]
import ../storage/sqlite
import ../config
import adapter

type
  ExpansionInfo* = object
    oid*: string
    returned*, total*: int
    truncated*: bool
  LoadedSubgraph* = object
    graph*: WorkingGraph
    expansions*: seq[ExpansionInfo]
    depth*: int
    truncated*, budgetTruncated*: bool

proc loadNodes*(store: GraphStore; dataset: string; oids: seq[string]; limit = 500): WorkingGraph =
  validateDataset(dataset)
  if limit < 1 or limit > 10000 or oids.len > limit:
    raise newException(ValueError, "Requested nodes exceed working graph limit")
  var records: GraphRecords
  var seen = initHashSet[string]()
  for oid in oids:
    if oid notin seen:
      let node = store.getNode(dataset, oid)
      if node.isNone: raise newException(ValueError, "Node is absent from dataset: " & oid)
      records.nodes.add(node.get)
      seen.incl(oid)
  toGrim(records)

proc loadSubgraph*(store: GraphStore; dataset, rootOid: string; depth = 1;
    limits = defaultLimits()): LoadedSubgraph =
  limits.validate()
  if depth < 0 or depth > limits.maxDepth: raise newException(ValueError, "Depth exceeds configured maximum")
  let root = store.getNode(dataset, rootOid)
  if root.isNone: raise newException(ValueError, "Node is absent from dataset")
  var records = GraphRecords(nodes: @[root.get])
  var knownNodes = [rootOid].toHashSet
  var knownEdges = initHashSet[string]()
  var frontier = @[rootOid]
  result.depth = depth
  for level in 0..<depth:
    var next: seq[string]
    for oid in frontier:
      let page = store.getEdgesForNode(dataset, oid, limits.neighborLimit)
      var expansion = ExpansionInfo(oid: oid, total: page.total)
      for edge in page.edges:
        if edge.oid in knownEdges:
          inc expansion.returned
          continue
        var needed = 0
        if edge.source notin knownNodes: inc needed
        if edge.target notin knownNodes and edge.target != edge.source: inc needed
        if records.nodes.len + needed > limits.maxNodes or records.edges.len >= limits.maxEdges:
          result.budgetTruncated = true
          continue
        for other in [edge.source, edge.target]:
          if other notin knownNodes:
            knownNodes.incl(other)
            records.nodes.add(store.getNode(dataset, other).get)
            next.add(other)
        records.edges.add(edge)
        knownEdges.incl(edge.oid)
        inc expansion.returned
      expansion.truncated = expansion.returned < expansion.total
      result.truncated = result.truncated or expansion.truncated
      result.expansions.add(expansion)
    frontier = next
    if frontier.len == 0: break
  result.graph = records.toGrim()

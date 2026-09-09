import std/json
import ../storage/sqlite
import ../graph/[adapter, loader, traversal]
import ../config
import dto

proc neighborhoodDto*(store: GraphStore; dataset, oid: string; limit, offset: int): JsonNode =
  let neighborhood = store.getNeighbors(dataset, oid, limit, offset)
  let graph = neighborhood.records.toGrim()
  discard graph.traverse(oid) # Validates/traverses the actual bounded Grim graph.
  result = graphDto(graph.records())
  result["meta"] = pageDto(graph.edgeCount, neighborhood.total, offset, limit)
  result["meta"]["unit"] = %"relationships"

proc edgesDto*(store: GraphStore; dataset, oid: string; limit, offset: int): JsonNode =
  let page = store.getEdgesForNode(dataset, oid, limit, offset)
  result = %*{"links": [], "meta": pageDto(page.edges.len, page.total, offset, limit)}
  for edge in page.edges: result["links"].add(edgeDto(edge))
  result["meta"]["unit"] = %"relationships"

proc subgraphDto*(store: GraphStore; dataset, oid: string; depth: int; limits: GraphLimits): JsonNode =
  let loaded = store.loadSubgraph(dataset, oid, depth, limits)
  discard loaded.graph.traverse(oid, depth)
  result = graphDto(loaded.graph.records())
  result["meta"] = %*{"returned": {"nodes": loaded.graph.nodeCount, "links": loaded.graph.edgeCount},
    "total": newJNull(), "truncated": loaded.truncated, "depth": depth,
    "budgetTruncated": loaded.budgetTruncated, "maxNodes": limits.maxNodes,
    "maxEdges": limits.maxEdges, "expansions": []}
  for expansion in loaded.expansions:
    result["meta"]["expansions"].add(%*{"id": expansion.oid,
      "returned": expansion.returned, "total": expansion.total, "truncated": expansion.truncated})

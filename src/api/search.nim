import std/json
import ../storage/[sqlite, search]
import dto

proc searchDto*(store: GraphStore; dataset, query: string; limit, offset: int; labels: seq[string]): JsonNode =
  let page = store.searchNodes(dataset, query, limit, labels, offset)
  result = %*{"nodes": [], "meta": pageDto(page.nodes.len, page.total, offset, limit)}
  for node in page.nodes: result["nodes"].add(nodeDto(node))

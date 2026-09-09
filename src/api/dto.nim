import std/json
import ../model/graph_record

proc nodeDto*(node: NodeRecord): JsonNode =
  %*{"id": node.oid, "label": node.label, "properties": canonicalJson(node.properties)}

proc edgeDto*(edge: EdgeRecord): JsonNode =
  %*{"id": edge.oid, "source": edge.source, "target": edge.target,
    "label": edge.label, "properties": canonicalJson(edge.properties)}

proc graphDto*(records: GraphRecords): JsonNode =
  result = %*{"nodes": [], "links": []}
  for node in records.nodes: result["nodes"].add(nodeDto(node))
  for edge in records.edges: result["links"].add(edgeDto(edge))

proc pageDto*(returned, total, offset, limit: int): JsonNode =
  %*{"returned": returned, "total": total, "offset": offset, "limit": limit,
    "truncated": returned < total,
    "hasMore": offset + returned < total,
    "nextOffset": (if offset + returned < total: %(offset + returned) else: newJNull())}

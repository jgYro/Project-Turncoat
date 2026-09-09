## Framework-independent API behavior, status mapping and validation.
import std/[json, tables, strutils, uri]
import ../storage/[sqlite, search]
import ../config
import dto, graph, search as searchApi

type
  Operation* = enum healthOp, datasetsOp, searchOp, nodeOp, neighborsOp, edgesOp, subgraphOp
  ApiResponse* = object
    status*: int
    body*: JsonNode
  NotFound = object of CatchableError

proc errorResponse*(status: int; message: string): ApiResponse =
  ApiResponse(status: status, body: %*{"error": {"status": status, "message": message}})

proc queryParams(query: string): Table[string, string] =
  if query.len > 4096: raise newException(ValueError, "Query string exceeds 4096 bytes")
  for key, value in decodeQuery(query):
    if key in result: raise newException(ValueError, "Duplicate query parameter: " & key)
    result[key] = value

proc integer(params: Table[string, string]; key: string; default, minimum, maximum: int): int =
  result = if key in params: parseInt(params[key]) else: default
  if result < minimum or result > maximum:
    raise newException(ValueError, key & " must be " & $minimum & ".." & $maximum)

proc executeOperation(store: GraphStore; config: AppConfig; op: Operation;
    dataset, oid, query: string): JsonNode =
  if op == healthOp:
    return %*{"status": "ok", "fts5": store.ftsEnabled, "limits": {
      "neighborLimit": config.limits.neighborLimit, "maxNeighborLimit": config.limits.maxNeighborLimit,
      "defaultDepth": config.limits.defaultDepth, "maxDepth": config.limits.maxDepth,
      "maxNodes": config.limits.maxNodes, "maxEdges": config.limits.maxEdges}}
  if op == datasetsOp:
    result = %*{"datasets": []}
    for dataset in store.datasets():
      result["datasets"].add(%*{"id": dataset.id, "nodes": dataset.nodes, "edges": dataset.edges})
    return
  validateDataset(dataset)
  if not store.datasetExists(dataset): raise newException(NotFound, "Dataset not found")
  let params = queryParams(query)
  if op == searchOp:
    let labels = if params.getOrDefault("labels").len > 0: params["labels"].split(',') else: @[]
    return store.searchDto(dataset, params.getOrDefault("q"),
      params.integer("limit", 30, 1, config.limits.maxNeighborLimit),
      params.integer("offset", 0, 0, 1_000_000), labels)
  validateOid(oid)
  let node = store.getNode(dataset, oid)
  if node.isNone: raise newException(NotFound, "Node not found in dataset")
  if op == nodeOp: return nodeDto(node.get)
  if op == subgraphOp:
    return store.subgraphDto(dataset, oid,
      params.integer("depth", config.limits.defaultDepth, 0, config.limits.maxDepth), config.limits)
  let limit = params.integer("limit", config.limits.neighborLimit, 1, config.limits.maxNeighborLimit)
  let offset = params.integer("offset", 0, 0, 1_000_000)
  if op == neighborsOp: return store.neighborhoodDto(dataset, oid, limit, offset)
  store.edgesDto(dataset, oid, limit, offset)

proc handleRequest*(store: GraphStore; config: AppConfig; op: Operation;
    dataset = ""; oid = ""; query = ""): ApiResponse =
  try:
    result.status = 200
    store.snapshot:
      result.body = executeOperation(store, config, op, dataset, oid, query)
  except NotFound as error: result = errorResponse(404, error.msg)
  except SearchUnavailable as error: result = errorResponse(503, error.msg)
  except ValueError as error: result = errorResponse(400, error.msg)
  except CatchableError as error:
    stderr.writeLine("Graph API error: " & error.msg)
    result = errorResponse(500, "Internal server error")

proc decodeSegment(segment: string): string =
  var i = 0
  while i < segment.len:
    if segment[i] == '%':
      if i + 2 >= segment.len or segment[i+1] notin HexDigits or segment[i+2] notin HexDigits:
        raise newException(ValueError, "Malformed URL encoding")
      i += 2
    inc i
  decodeUrl(segment, false)

proc handlePathRequest*(store: GraphStore; config: AppConfig; rawPath, query: string): ApiResponse =
  # HappyX decodes the whole path before route matching. Split the original
  # request path first, then decode individual segments exactly once so OIDs
  # containing '/', '+', or literal percent escapes retain their identity.
  try:
    if rawPath.len > 2048 or query.len > 4096:
      return errorResponse(400, "Request URL exceeds configured size limit")
    let parts = rawPath.split('/')
    if parts.len == 3 and parts[1] == "api":
      case parts[2]
      of "health": return handleRequest(store, config, healthOp)
      of "datasets": return handleRequest(store, config, datasetsOp)
      else: discard
    if parts.len >= 4 and parts[1] == "api":
      let dataset = decodeSegment(parts[2])
      if parts.len == 4 and parts[3] == "search":
        return handleRequest(store, config, searchOp, dataset, query = query)
      if parts.len == 5 and parts[3] == "subgraph":
        return handleRequest(store, config, subgraphOp, dataset, decodeSegment(parts[4]), query)
      if parts.len in [5, 6] and parts[3] == "node":
        let oid = decodeSegment(parts[4])
        if parts.len == 5: return handleRequest(store, config, nodeOp, dataset, oid, query)
        case parts[5]
        of "neighbors": return handleRequest(store, config, neighborsOp, dataset, oid, query)
        of "edges": return handleRequest(store, config, edgesOp, dataset, oid, query)
        else: discard
    errorResponse(404, "Route not found")
  except ValueError as error: errorResponse(400, error.msg)

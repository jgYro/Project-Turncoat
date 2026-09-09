import std/[os, strutils, parseopt]

type
  GraphLimits* = object
    neighborLimit*, maxNeighborLimit*, defaultDepth*, maxDepth*: int
    maxNodes*, maxEdges*: int
  AppConfig* = object
    dbPath*, host*: string
    port*: int
    fts*: bool
    batchSize*: int
    limits*: GraphLimits
  CommandLine* = object
    config*: AppConfig
    args*: seq[string]

proc defaultLimits*(): GraphLimits =
  GraphLimits(neighborLimit: 100, maxNeighborLimit: 1000, defaultDepth: 1,
    maxDepth: 3, maxNodes: 500, maxEdges: 1000)

proc validate*(limits: GraphLimits) =
  if limits.neighborLimit < 1 or limits.neighborLimit > limits.maxNeighborLimit or
      limits.maxNeighborLimit > 1000 or limits.maxDepth < 1 or limits.maxDepth > 10 or
      limits.defaultDepth < 0 or limits.defaultDepth > limits.maxDepth or
      limits.maxNodes < 2 or limits.maxNodes > 10000 or
      limits.maxEdges < 1 or limits.maxEdges > 20000:
    raise newException(ValueError, "Invalid graph limits (depth <= 10, nodes <= 10000, edges <= 20000, neighbors <= 1000)")

proc defaultConfig*(): AppConfig =
  AppConfig(dbPath: "data/app.db", host: "127.0.0.1", port: 5000,
    fts: true, batchSize: 500, limits: defaultLimits())

proc parseCommandLine*(args: seq[string]): CommandLine =
  result.config = defaultConfig()
  result.config.dbPath = getEnv("TURNCOAT_DB", getEnv("GRAPHAPP_DB", result.config.dbPath))
  result.config.host = getEnv("HOST", getEnv("GRAPHAPP_HOST", result.config.host))
  result.config.port = parseInt(getEnv("PORT", getEnv("GRAPHAPP_PORT", "5000")))
  var parser = initOptParser(args)
  for kind, key, value in parser.getopt():
    case kind
    of cmdArgument: result.args.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "db": result.config.dbPath = value
      of "host": result.config.host = value
      of "port": result.config.port = parseInt(value)
      of "neighbor-limit": result.config.limits.neighborLimit = parseInt(value)
      of "max-neighbors": result.config.limits.maxNeighborLimit = parseInt(value)
      of "depth": result.config.limits.defaultDepth = parseInt(value)
      of "max-depth": result.config.limits.maxDepth = parseInt(value)
      of "max-nodes": result.config.limits.maxNodes = parseInt(value)
      of "max-edges": result.config.limits.maxEdges = parseInt(value)
      of "batch-size": result.config.batchSize = parseInt(value)
      of "no-fts": result.config.fts = false
      of "help", "h": result.args = @["help"]
      else: raise newException(ValueError, "Unknown option: " & key)
    of cmdEnd: discard
  result.config.limits.validate()
  if result.config.port < 1 or result.config.port > 65535:
    raise newException(ValueError, "Port must be 1..65535")
  if result.config.host.len == 0 or result.config.dbPath.len == 0:
    raise newException(ValueError, "Host and database path must not be empty")
  if result.config.batchSize < 1 or result.config.batchSize > 10000:
    raise newException(ValueError, "Batch size must be 1..10000")

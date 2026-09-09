import std/[os, json]
import config
import storage/[sqlite, jsonl]
import arxiv_search

const Usage = """Project Turncoat
Usage: turncoat [--db:PATH] COMMAND [arguments]
  init                         Initialize SQLite
  serve                        Start papers, patents, institutions and graph (default)
  import DATASET FILE.jsonl     Stream/upsert canonical records
  export DATASET FILE.jsonl     Export to a new file
  stats DATASET                Show node and edge counts
Options: --host:127.0.0.1 --port:5000 --neighbor-limit:100 --max-neighbors:1000
         --depth:1 --max-depth:3 --max-nodes:500 --max-edges:1000
         --batch-size:500 --no-fts --help
Environment overrides: TURNCOAT_DB, HOST, PORT (GRAPHAPP_* also accepted)
"""

proc main() =
  let command = parseCommandLine(commandLineParams())
  let args = if command.args.len == 0: @["serve"] else: command.args
  if args[0] == "help":
    echo Usage
    return
  if args[0] notin ["init", "serve", "import", "export", "stats"]:
    raise newException(ValueError, "Unknown command. Use --help")
  let expected = case args[0]
    of "import", "export": 3
    of "stats": 2
    else: 1
  if args.len != expected: raise newException(ValueError, "Incorrect arguments. Use --help")
  if args[0] == "serve":
    serveProject(command.config)
    return
  let store = openStore(command.config.dbPath, command.config.fts)
  defer: store.close()
  case args[0]
  of "init": echo "Initialized " & command.config.dbPath & "; FTS5: " & $store.ftsEnabled
  of "import":
    let report = store.importGraph(args[1], args[2], command.config.batchSize)
    echo "Imported " & $report.nodes & " nodes and " & $report.edges & " edges into " & args[1]
  of "export":
    store.exportGraph(args[1], args[2])
    echo "Exported " & args[1] & " to " & args[2]
  of "stats":
    if not store.datasetExists(args[1]): raise newException(ValueError, "Dataset not found")
    echo $(%*{"dataset": args[1], "nodes": store.countNodes(args[1]), "edges": store.countEdges(args[1])})
  else: discard

when isMainModule:
  try: main()
  except CatchableError as error:
    stderr.writeLine("Error: " & error.msg)
    quit(1)

import std/[strutils, streams, os, json, tempfiles]
import sqlite

type
  ImportReport* = object
    nodes*, edges*: int
  ImportError* = object of CatchableError
    line*: int
    committed*: ImportReport

iterator recordsWithLines*(path: string): tuple[line: int, record: GraphRecord] =
  let input = newFileStream(path, fmRead)
  if input.isNil: raise newException(IOError, "Cannot open JSONL file: " & path)
  defer: input.close()
  var number = 0
  while not input.atEnd:
    inc number
    var line = ""
    # Bound allocation even for malformed files containing an enormous line.
    while not input.atEnd:
      let ch = input.readChar()
      if ch == '\n': break
      line.add(ch)
      if line.len > MaxRecordBytes:
        var error = newException(ImportError, "Line " & $number & ": record exceeds 1 MiB")
        error.line = number
        raise error
    if line.endsWith("\r"): line.setLen(line.len - 1)
    try:
      if line.len == 0: raise newException(ValueError, "Blank records are not allowed")
      yield (number, parseRecord(line))
    except ImportError: raise
    except CatchableError as cause:
      var error = newException(ImportError, "Line " & $number & ": " & cause.msg)
      error.line = number
      raise error

iterator streamNodes*(path: string): NodeRecord =
  for entry in recordsWithLines(path):
    if entry.record.kind == nodeKind: yield entry.record.node

iterator streamEdges*(path: string): EdgeRecord =
  for entry in recordsWithLines(path):
    if entry.record.kind == edgeKind: yield entry.record.edge

proc writeNode*(output: Stream; node: NodeRecord) =
  let line = $node.toJson()
  if line.len > MaxRecordBytes: raise newException(ValueError, "Record exceeds 1 MiB")
  output.writeLine(line)

proc writeEdge*(output: Stream; edge: EdgeRecord) =
  let line = $edge.toJson()
  if line.len > MaxRecordBytes: raise newException(ValueError, "Record exceeds 1 MiB")
  output.writeLine(line)

proc exportGraph*(store: GraphStore; dataset: string; path: string) =
  if not store.datasetExists(dataset): raise newException(ValueError, "Dataset does not exist")
  if fileExists(path) or dirExists(path) or symlinkExists(path):
    raise newException(ValueError, "Export destination already exists; choose a new path")
  let (file, temporary) = createTempFile("graph-export-", ".jsonl", path.absolutePath.parentDir)
  let output = newFileStream(file)
  try:
    store.snapshot:
      for node in store.streamStoredNodes(dataset): output.writeNode(node)
      for edge in store.streamStoredEdges(dataset): output.writeEdge(edge)
    output.flush()
    output.close()
    if fileExists(path) or dirExists(path) or symlinkExists(path):
      raise newException(ValueError, "Export destination appeared during export")
    moveFile(temporary, path)
  except:
    output.close()
    if fileExists(temporary): removeFile(temporary)
    raise

proc importGraph*(store: GraphStore; dataset, path: string; batchSize = 500): ImportReport =
  validateDataset(dataset)
  if batchSize < 1 or batchSize > 10000: raise newException(ValueError, "batchSize must be 1..10000")
  if not fileExists(path): raise newException(IOError, "Cannot open JSONL file: " & path)
  # Also cap bytes in each batch, so large properties cannot multiply memory use.
  var batch: seq[tuple[line: int, record: GraphRecord]]
  var bytes = 0
  var currentLine = 0
  var committed: ImportReport
  proc flush() =
    if batch.len == 0: return
    store.transaction:
      store.ensureDataset(dataset)
      for entry in batch:
        currentLine = entry.line
        case entry.record.kind
        of nodeKind: store.upsertNode(dataset, entry.record.node)
        of edgeKind: store.upsertEdge(dataset, entry.record.edge)
    for entry in batch:
      if entry.record.kind == nodeKind: inc committed.nodes
      else: inc committed.edges
    batch.setLen(0)
    bytes = 0
  try:
    for pass in [nodeKind, edgeKind]:
      for entry in recordsWithLines(path):
        currentLine = entry.line
        if entry.record.kind != pass: continue
        batch.add(entry)
        bytes += (if pass == nodeKind: ($entry.record.node.toJson()).len else: ($entry.record.edge.toJson()).len)
        if batch.len >= batchSize or bytes >= 8 * 1024 * 1024: flush()
      flush()
    store.ensureDataset(dataset) # Empty files still establish a dataset.
    result = committed
  except CatchableError as cause:
    let failedLine = if cause of ImportError: (ref ImportError)(cause).line else: currentLine
    let detail = if cause of ImportError: cause.msg else: "Line " & $failedLine & ": " & cause.msg
    var error = newException(ImportError, detail &
      "; committed " & $committed.nodes & " nodes, " & $committed.edges & " edges")
    error.line = failedLine
    error.committed = committed
    raise error

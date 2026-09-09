## Internal SQLite binding boundary. Statements always finalize, including errors
## and early iterator exits. SQL text is supplied only by storage modules.
import std/strutils
import db_connector/sqlite3 as sqliteC

type
  StorageError* = object of CatchableError
  Connection* = ref object
    handle: PSqlite3
  Row* = seq[string]

proc fail(db: Connection) {.noreturn.} =
  raise newException(StorageError, $sqliteC.errmsg(db.handle))

proc connect*(path: string): Connection =
  new(result)
  if sqliteC.open(path.cstring, result.handle) != SQLITE_OK:
    let message = $sqliteC.errmsg(result.handle)
    discard sqliteC.close(result.handle)
    raise newException(StorageError, message)

proc close*(db: Connection) =
  if not db.isNil and not db.handle.isNil:
    if sqliteC.close(db.handle) != SQLITE_OK: db.fail()
    db.handle = nil

proc prepare(db: Connection; sql: string; args: openArray[string]): PStmt =
  if db.handle.isNil: raise newException(StorageError, "Database is closed")
  if prepare_v2(db.handle, sql.cstring, sql.len.cint, result, nil) != SQLITE_OK:
    discard sqliteC.finalize(result)
    db.fail()
  try:
    if bind_parameter_count(result).int != args.len:
      raise newException(StorageError, "Incorrect SQL parameter count")
    for i, value in args:
      if bind_text(result, (i + 1).int32, value.cstring, value.len.int32,
          SQLITE_TRANSIENT) != SQLITE_OK: db.fail()
  except:
    discard sqliteC.finalize(result)
    raise

iterator rows*(db: Connection; sql: string; args: seq[string] = @[]): Row =
  let statement = db.prepare(sql, args)
  try:
    while true:
      let code = step(statement)
      if code == SQLITE_DONE: break
      if code != SQLITE_ROW: db.fail()
      var row = newSeq[string](column_count(statement))
      for i in 0..<row.len:
        let data = column_text(statement, i.int32)
        let size = column_bytes(statement, i.int32).int
        row[i] = newString(size)
        if size > 0: copyMem(addr row[i][0], data, size)
      yield row
  finally:
    discard sqliteC.finalize(statement)

proc execute*(db: Connection; sql: string; args: seq[string] = @[]) =
  for row in db.rows(sql, args): discard

proc scalar*(db: Connection; sql: string; args: seq[string] = @[]): string =
  for row in db.rows(sql, args): return row[0]

proc scalarInt*(db: Connection; sql: string; args: seq[string] = @[]): int =
  parseInt(db.scalar(sql, args))

template transaction*(db: Connection; body: untyped) =
  db.execute("BEGIN IMMEDIATE")
  try:
    body
    db.execute("COMMIT")
  except:
    db.execute("ROLLBACK")
    raise

template snapshot*(db: Connection; body: untyped) =
  db.execute("BEGIN")
  try:
    body
    db.execute("COMMIT")
  except:
    db.execute("ROLLBACK")
    raise

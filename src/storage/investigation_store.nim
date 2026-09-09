## Investigation metadata lives in canonical nodes; no parallel graph schema.
import std/json
import sqlite, driver

proc runningInvestigationIds*(store: GraphStore; schema: string): seq[string] =
  for row in store.db.rows("SELECT dataset FROM nodes WHERE label='Investigation' AND json_extract(properties,'$.schema')=? AND json_extract(properties,'$.state')='running'", @[schema]):
    result.add(row[0])

proc recentInvestigations*(store: GraphStore; schema: string): JsonNode =
  result = newJArray()
  for row in store.db.rows("SELECT dataset,properties FROM nodes WHERE label='Investigation' AND json_extract(properties,'$.schema')=? ORDER BY json_extract(properties,'$.createdAt') DESC LIMIT 30", @[schema]):
    result.add(%*{"id": row[0], "job": parseJson(row[1])})

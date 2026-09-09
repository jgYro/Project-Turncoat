import std/json
import node

type EdgeRecord* = object
  oid*: string
  source*: string
  target*: string
  label*: string
  properties*: JsonNode

proc validate*(edge: EdgeRecord) =
  validate(NodeRecord(oid: edge.oid, label: edge.label, properties: edge.properties))
  validateOid(edge.source)
  validateOid(edge.target)

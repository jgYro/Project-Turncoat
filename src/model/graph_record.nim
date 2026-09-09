import std/[json, algorithm, unicode, math]
import node, edge
export node, edge

const MaxRecordBytes* = 1024 * 1024

type
  RecordKind* = enum nodeKind, edgeKind
  GraphRecord* = object
    case kind*: RecordKind
    of nodeKind: node*: NodeRecord
    of edgeKind: edge*: EdgeRecord
  GraphRecords* = object
    nodes*: seq[NodeRecord]
    edges*: seq[EdgeRecord]

proc canonicalJson*(value: JsonNode; depth = 0): JsonNode =
  if value.isNil or depth > 64:
    raise newException(ValueError, "JSON properties exceed maximum nesting depth 64")
  case value.kind
  of JObject:
    result = newJObject()
    var keys: seq[string]
    for key in value.keys: keys.add(key)
    keys.sort()
    for key in keys:
      if validateUtf8(key) != -1: raise newException(ValueError, "Invalid UTF-8 JSON key")
      result[key] = canonicalJson(value[key], depth + 1)
  of JArray:
    result = newJArray()
    for item in value: result.add(canonicalJson(item, depth + 1))
  of JFloat:
    if classify(value.getFloat) in {fcNan, fcInf, fcNegInf}:
      raise newException(ValueError, "JSON numbers must be finite")
    result = value.copy
  of JString:
    if validateUtf8(value.getStr) != -1: raise newException(ValueError, "Invalid UTF-8 JSON string")
    result = value.copy
  else: result = value.copy

proc toJson*(node: NodeRecord): JsonNode =
  node.validate()
  result = %*{"type": "node", "oid": node.oid, "label": node.label,
    "properties": canonicalJson(node.properties)}

proc toJson*(edge: EdgeRecord): JsonNode =
  edge.validate()
  result = %*{"type": "edge", "oid": edge.oid, "source": edge.source,
    "target": edge.target, "label": edge.label,
    "properties": canonicalJson(edge.properties)}

proc requiredString(value: JsonNode; key: string): string =
  if not value.hasKey(key) or value[key].kind != JString:
    raise newException(ValueError, "Missing or non-string field: " & key)
  value[key].getStr

proc parseRecord*(line: string): GraphRecord =
  if line.len > MaxRecordBytes: raise newException(ValueError, "Record exceeds 1 MiB")
  if validateUtf8(line) != -1: raise newException(ValueError, "Record is not valid UTF-8")
  let value = parseJson(line)
  if value.kind != JObject: raise newException(ValueError, "Record must be a JSON object")
  let kind = requiredString(value, "type")
  let oid = requiredString(value, "oid")
  let label = requiredString(value, "label")
  if not value.hasKey("properties") or value["properties"].kind != JObject:
    raise newException(ValueError, "properties must be a JSON object")
  let properties = canonicalJson(value["properties"])
  case kind
  of "node":
    let node = NodeRecord(oid: oid, label: label, properties: properties)
    node.validate()
    result = GraphRecord(kind: nodeKind, node: node)
  of "edge":
    let edge = EdgeRecord(oid: oid, label: label, properties: properties,
      source: requiredString(value, "source"), target: requiredString(value, "target"))
    edge.validate()
    result = GraphRecord(kind: edgeKind, edge: edge)
  else: raise newException(ValueError, "Unknown record type: " & kind)

import std/[json, unicode]

type NodeRecord* = object
  oid*: string
  label*: string
  properties*: JsonNode

proc validateOid*(oid: string) =
  if oid.len == 0 or oid.len > 512 or validateUtf8(oid) != -1:
    raise newException(ValueError, "OID must be valid UTF-8, 1..512 bytes")
  for ch in oid:
    if ch <= ' ' or ch == '\x7f':
      raise newException(ValueError, "OID must not contain whitespace or control characters")

proc validateDataset*(dataset: string) =
  if dataset.len == 0 or dataset.len > 64:
    raise newException(ValueError, "Dataset must contain 1..64 characters")
  for ch in dataset:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      raise newException(ValueError, "Dataset allows only letters, digits, '_' and '-'")

proc validateLabel*(label: string) =
  if label.len == 0 or label.len > 128 or label.strip.len == 0 or
      validateUtf8(label) != -1:
    raise newException(ValueError, "Label must be valid UTF-8, 1..128 bytes")
  for ch in label:
    if ch < ' ' or ch == '\x7f':
      raise newException(ValueError, "Label must not contain control characters")

proc validate*(node: NodeRecord) =
  validateOid(node.oid)
  validateLabel(node.label)
  if node.properties.isNil or node.properties.kind != JObject:
    raise newException(ValueError, "properties must be a JSON object")

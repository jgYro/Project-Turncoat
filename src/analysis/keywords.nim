## Literal evidence matching; tags do not establish an application or end user.
import std/[json, strutils, unicode]

const KeywordCatalogText* = staticRead("keywords.json")
const MaxHits* = 500
const ExampleText = staticRead("example.json")

proc keywordCatalog*(): JsonNode = parseJson(KeywordCatalogText)

proc evidenceFields*(record: JsonNode; pdf = ""): JsonNode =
  result = %*{"title": record{"title"}.getStr, "abstract": record{"abstract"}.getStr}
  if pdf.len > 0: result["pdf"] = %pdf

proc wordRune(r: Rune): bool = r.isAlpha or r.int in 48..57 or r.int == 95

proc wordBefore(text: string; index: int): bool =
  if index == 0: return false
  var start = index - 1
  while start > 0 and (ord(text[start]) and 0xc0) == 0x80: dec start
  wordRune(text.runeAt(start))

proc literalPositions*(text, term: string): seq[int] =
  if term.len == 0: return
  let haystack = text.toLowerAscii
  let needle = term.toLowerAscii
  let latinStart = needle[0] in {'a'..'z', '0'..'9'}
  let latinEnd = needle[^1] in {'a'..'z', '0'..'9'}
  var offset = 0
  while offset <= haystack.len - needle.len:
    let found = haystack.find(needle, offset)
    if found < 0: break
    let after = found + needle.len
    if (not latinStart or not wordBefore(haystack,found)) and
        (not latinEnd or after == haystack.len or not wordRune(haystack.runeAt(after))):
      result.add(found)
    offset = after

proc excerptStart(text: string; start: int): int =
  result = max(0, start - 100)
  while result > 0 and (ord(text[result]) and 0xc0) == 0x80: dec result

proc excerpt*(text: string; start, finish: int): string =
  let a = excerptStart(text,start)
  var b = min(text.len, finish + 140)
  while b < text.len and (ord(text[b]) and 0xc0) == 0x80: inc b
  text[a..<b]

proc scanKeywords*(fields: JsonNode; query = ""): JsonNode =
  if fields.kind != JObject: raise newException(ValueError, "Evidence must be an object of text fields.")
  if query.len > 160 or validateUtf8(query) >= 0 or '\0' in query:
    raise newException(ValueError, "Use a UTF-8 keyword or phrase up to 160 bytes.")
  let catalog = keywordCatalog()
  var rules = catalog["rules"]
  if query.strip.len > 0:
    rules.add(%*{"id":"custom", "tag":query.strip, "category":"Custom phrase", "bucket":"custom", "terms":[query.strip]})
  result = %*{"version":catalog["version"], "query":query, "hits":[], "tags":[], "totalMatches":0, "truncated":false}
  var totalBytes = 0
  for field, value in fields:
    if field notin ["title", "abstract", "pdf"] or value.kind != JString:
      raise newException(ValueError, "Unsupported evidence field.")
    if validateUtf8(value.getStr) >= 0: raise newException(ValueError,"Evidence must be valid UTF-8.")
    totalBytes += value.getStr.len
  if totalBytes > 128_000: raise newException(ValueError, "Evidence exceeds the scan limit.")
  var total = 0
  for rule in rules:
    var count = 0
    for term in rule["terms"]:
      for field, value in fields:
        let source = value.getStr
        for start in literalPositions(source, term.getStr):
          inc count; inc total
          if result["hits"].len < MaxHits:
            let finish = start + term.getStr.len
            result["hits"].add(%*{"rule":rule["id"], "tag":rule["tag"], "category":rule["category"],
              "bucket":rule["bucket"], "field":field, "startByte":start, "endByte":finish,
              "matched":source[start..<finish], "excerpt":excerpt(source,start,finish),
              "excerptStartByte":excerptStart(source,start)})
    if count > 0:
      result["tags"].add(%*{"id":rule["id"], "tag":rule["tag"], "category":rule["category"], "bucket":rule["bucket"], "count":count})
  result["totalMatches"] = %total
  result["truncated"] = %(total > MaxHits)

proc keywordExample*(): JsonNode =
  result = parseJson(ExampleText)
  result["scan"] = scanKeywords(%*{"title":result["title"],"abstract":result["abstractExcerpt"]})

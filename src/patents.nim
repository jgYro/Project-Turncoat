## Google Patents website adapter. All upstream markup becomes plain text.
import std/[json, strutils, uri, times, xmltree]
import pkg/htmlparser
import api_errors

type PatentOptions* = object
  query*, country*, assignee*, inventor*, after*, before*, sort*: string
  page*, pageSize*: int

const
  PatentSorts* = [("relevance", "Most relevant"), ("newest", "Newest filed"),
    ("oldest", "Oldest filed")]
  PatentCountries* = [("", "All offices"), ("US", "US · United States"),
    ("EP", "EP · European patents"), ("WO", "WO · WIPO"), ("GB", "GB · United Kingdom"),
    ("CN", "CN · China"), ("JP", "JP · Japan"), ("KR", "KR · South Korea"),
    ("DE", "DE · Germany"), ("CA", "CA · Canada"), ("AU", "AU · Australia")]

proc defaultPatentOptions*(): PatentOptions =
  PatentOptions(sort: "relevance", page: 1, pageSize: 10)

proc patentOptionsFromQuery*(query: string): PatentOptions =
  result = defaultPatentOptions()
  for key, rawValue in decodeQuery(query):
    let value = rawValue.strip()
    case key
    of "q": result.query = value
    of "country": result.country = value.toUpperAscii()
    of "assignee": result.assignee = value
    of "inventor": result.inventor = value
    of "after": result.after = value
    of "before": result.before = value
    of "sort": result.sort = value
    of "page", "size":
      try:
        let number = parseInt(value)
        if key == "page": result.page = number
        else: result.pageSize = number
      except ValueError:
        raise newException(ValueError, "Page and size must be whole numbers.")
    else:
      raise newException(ValueError, "Unknown patent search parameter: " & key)

proc hasSearch*(options: PatentOptions): bool =
  options.query.len > 0 or options.country.len > 0 or options.assignee.len > 0 or
    options.inventor.len > 0 or options.after.len > 0 or options.before.len > 0

proc validate*(options: PatentOptions) =
  if options.query.len > 1000 or options.assignee.len > 200 or options.inventor.len > 200:
    raise newException(ValueError, "Keep the query under 1,000 characters and names under 200.")
  if options.country.len > 0 and (options.country.len != 2 or
      not options.country.allCharsInSet({'A'..'Z'})):
    raise newException(ValueError, "Use a two-letter patent office code, such as US, EP, or WO.")
  if options.sort notin ["relevance", "newest", "oldest"]:
    raise newException(ValueError, "Sort must be relevance, newest, or oldest.")
  if options.pageSize notin [10, 25, 50] or options.page < 1 or
      options.page > 1000 div options.pageSize:
    raise newException(ValueError, "Use a size of 10, 25, or 50 and a page within the first 1,000 results.")
  for value in [options.after, options.before]:
    if value.len == 0: continue
    var valid = false
    try:
      valid = value.len == 10 and parse(value, "yyyy-MM-dd", utc()).format("yyyy-MM-dd") == value
    except TimeParseError, ValueError: discard
    if not valid:
      raise newException(ValueError, "Enter filing dates in YYYY-MM-DD format.")
  if options.after.len > 0 and options.before.len > 0 and options.after >= options.before:
    raise newException(ValueError, "The after date must precede the before date.")

proc searchParams(options: PatentOptions): seq[(string, string)] =
  if options.query.len > 0: result.add(("q", options.query))
  if options.country.len > 0: result.add(("country", options.country))
  if options.assignee.len > 0: result.add(("assignee", options.assignee))
  if options.inventor.len > 0: result.add(("inventor", options.inventor))
  result.add(("type", "PATENT"))
  if options.after.len > 0: result.add(("after", "filing:" & options.after.replace("-", "")))
  if options.before.len > 0: result.add(("before", "filing:" & options.before.replace("-", "")))
  if options.sort != "relevance":
    result.add(("sort", if options.sort == "newest": "new" else: "old"))
  result.add(("num", $options.pageSize))
  result.add(("page", $(options.page - 1)))

proc googleQuery(options: PatentOptions): string =
  var parts: seq[string]
  for (key, value) in options.searchParams():
    var encoded = encodeQuery([(key, value)])
    # The website parses the date-field separator before decoding the inner URL.
    # A double-encoded colon produces HTTP 500, even though other values need
    # both encoding layers. Keep just these separators literal in the inner URL.
    if key in ["after", "before"]: encoded = encoded.replace("filing%3A", "filing:")
    parts.add(encoded)
  parts.join("&")

proc patentSearchUrl*(options: PatentOptions): string =
  "https://patents.google.com/?" & options.googleQuery()

proc patentApiPath*(options: PatentOptions): string =
  options.validate()
  if not options.hasSearch:
    raise newException(ValueError, "Enter a patent search term or choose a filter.")
  "/xhr/query?" & encodeQuery([("url", options.googleQuery()), ("exp", "")])

proc patentPageUrl*(options: PatentOptions; page: int): string =
  "/patents?" & encodeQuery([("q", options.query), ("country", options.country),
    ("assignee", options.assignee), ("inventor", options.inventor),
    ("after", options.after), ("before", options.before), ("sort", options.sort),
    ("size", $options.pageSize), ("page", $page)]) & "#results"

proc publicationId*(value: string): string =
  result = value.toUpperAscii()
  if result.len < 5 or result.len > 32 or
      not result[0..1].allCharsInSet({'A'..'Z'}) or
      not result.allCharsInSet({'A'..'Z', '0'..'9'}) or
      not result.contains({'0'..'9'}):
    raise newException(ValueError, "Use a publication number such as US9014905B1, without spaces or a URL.")

proc patentUrl*(id: string): string =
  "https://patents.google.com/patent/" & publicationId(id) & "/en"

proc plainText(node: XmlNode): string =
  case node.kind
  of xnText, xnCData, xnEntity: result = node.innerText
  of xnElement:
    if node.tag.toLowerAscii() in ["script", "style", "noscript"]: return
    for child in node: result.add(plainText(child))
    if node.tag.toLowerAscii() in ["p", "div", "br", "li", "section"]: result.add(' ')
  else: discard

proc cleanText*(html: string): string =
  plainText(parseHtml(html)).splitWhitespace().join(" ")

proc safePdf(value: string; relative = false): string =
  if value.len == 0: return ""
  let url = if relative: "https://patentimages.storage.googleapis.com/" & value else: value
  try:
    let parsed = parseUri(url)
    if parsed.scheme == "https" and parsed.hostname == "patentimages.storage.googleapis.com" and
        parsed.username.len == 0 and parsed.password.len == 0 and parsed.port.len == 0 and
        parsed.query.len == 0 and parsed.anchor.len == 0 and parsed.path.endsWith(".pdf") and
        parsed.path.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '/', '.', '_', '-'}) and
        ".." notin parsed.path:
      return url
  except ValueError: discard

proc stringAt(node: JsonNode; key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    result = node[key].getStr()

proc parsePatentSearch*(body: string; options: PatentOptions): JsonNode =
  try:
    let root = parseJson(body)
    if root.kind != JObject or not root.hasKey("results") or root["results"].kind != JObject:
      raise apiError("Google Patents returned an unexpected search response.")
    let data = root["results"]
    for key in ["total_num_results", "total_num_pages", "num_page"]:
      if not data.hasKey(key) or data[key].kind != JInt or data[key].getBiggestInt() < 0:
        raise apiError("Google Patents returned incomplete search metadata.")
    if data["num_page"].getBiggestInt() != options.page - 1:
      raise apiError("Google Patents did not return the requested result page.")
    let total = data["total_num_results"].getBiggestInt()
    let pages = min(data["total_num_pages"].getBiggestInt(), 1000 div options.pageSize)
    var records = newJArray()
    if data.hasKey("cluster"):
      if data["cluster"].kind != JArray:
        raise apiError("Google Patents returned an unexpected result list.")
      for cluster in data["cluster"]:
        # Empty searches use cluster:[{}], rather than a result array.
        if cluster.kind == JObject and cluster.len == 0 and total == 0: continue
        if cluster.kind != JObject or not cluster.hasKey("result") or cluster["result"].kind != JArray:
          raise apiError("Google Patents returned an incomplete result list.")
        for item in cluster["result"]:
          if item.kind != JObject or not item.hasKey("patent") or item["patent"].kind != JObject:
            raise apiError("Google Patents returned an unexpected patent record.")
          let patent = item["patent"]
          let id = publicationId(patent.stringAt("publication_number"))
          let title = cleanText(patent.stringAt("title"))
          if title.len == 0: raise apiError("Google Patents returned a patent without a title.")
          records.add(%*{
            "publication_number": id, "title": title,
            "snippet": cleanText(patent.stringAt("snippet")),
            "inventor": cleanText(patent.stringAt("inventor")),
            "assignee": cleanText(patent.stringAt("assignee")),
            "priority_date": patent.stringAt("priority_date"),
            "filing_date": patent.stringAt("filing_date"),
            "publication_date": patent.stringAt("publication_date"),
            "grant_date": patent.stringAt("grant_date"),
            "url": patentUrl(id), "pdf_url": safePdf(patent.stringAt("pdf"), relative = true),
            "api_url": "/api/patents/" & id})
    if total > 0 and options.page <= pages and records.len == 0:
      raise apiError("Google Patents returned no records for an available page.")
    result = %*{"source": "Google Patents", "search_url": options.patentSearchUrl(),
      "total": total, "total_is_approximate": true, "page": options.page,
      "page_size": options.pageSize, "total_pages": pages,
      "has_next": records.len > 0 and options.page < pages, "results": records}
  except ApiError: raise
  except CatchableError:
    raise apiError("Google Patents returned an unreadable search response.")

proc parsePatentDetail*(body, requestedId: string): JsonNode =
  let id = publicationId(requestedId)
  let document = parseHtml(body)
  var title, abstractText, pdf, filing, published, publication: string
  var inventors, assignees: seq[string]
  var rawMetadata = newJArray()
  for meta in document.findAll("meta"):
    let value = meta.attr("content").splitWhitespace().join(" ")
    if meta.attr("name").startsWith("DC."):
      rawMetadata.add(%*{"name": meta.attr("name"), "scheme": meta.attr("scheme"),
        "content": meta.attr("content")})
    case meta.attr("name")
    of "DC.title": title = value
    of "DC.description": abstractText = value
    of "citation_pdf_url": pdf = safePdf(value)
    of "DC.date":
      if meta.attr("scheme") == "dateSubmitted": filing = value
      elif meta.attr("scheme") == "issue": published = value
    of "DC.contributor":
      if meta.attr("scheme") == "inventor": inventors.add(meta.attr("content"))
      elif meta.attr("scheme") == "assignee": assignees.add(meta.attr("content"))
    else: discard
  # Read the primary record, not publication numbers in its citation tables.
  for node in document.findAll("dd"):
    if node.attr("itemprop") == "publicationNumber":
      publication = plainText(node).strip()
      break
  if title.len == 0 or publication != id:
    raise apiError("Google Patents returned an unexpected patent document.")
  result = %*{"source": "Google Patents", "publication_number": id,
    "title": title, "abstract": abstractText, "inventors": inventors,
    "original_assignees": assignees, "filing_date": filing, "publication_date": published,
    "url": patentUrl(id), "pdf_url": pdf, "raw_metadata": rawMetadata}

proc patentErrorJson*(status: int; message: string): JsonNode =
  let code = case status
    of 400: "invalid_request"
    of 404: "not_found"
    of 503: "unavailable"
    of 504: "upstream_timeout"
    else: "upstream_error"
  %*{"error": {"code": code, "message": message}}

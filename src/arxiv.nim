## Query validation and Atom parsing are independent of the web framework.
import std/[strutils, uri, times, xmlparser, xmltree]
import api_errors
export api_errors

type
  SearchOptions* = object
    query*, field*, category*, author*, dateFrom*, dateTo*, sort*: string
    page*, pageSize*: int
  Paper* = object
    id*, title*, summary*, published*, updated*, primaryCategory*: string
    comment*, journal*, doi*: string
    authors*, categories*: seq[string]
  SearchResult* = object
    total*, start*, pageSize*: int
    papers*: seq[Paper]

const
  MaxResults* = 30000
  Categories* = [
    ("", "All disciplines"), ("cs.*", "Computer science"),
    ("cs.AI", "Artificial intelligence"), ("cs.LG", "Machine learning"),
    ("cs.CL", "Computation & language"), ("cs.CV", "Computer vision"),
    ("math.*", "Mathematics"), ("astro-ph.*", "Astrophysics"),
    ("quant-ph", "Quantum physics"), ("cond-mat.*", "Condensed matter"),
    ("physics.*", "Physics"), ("stat.*", "Statistics"),
    ("q-bio.*", "Quantitative biology"), ("q-fin.*", "Quantitative finance"),
    ("econ.*", "Economics")]
  Fields* = [("all", "All fields"), ("ti", "Title"), ("au", "Author"),
    ("abs", "Abstract"), ("id", "arXiv IDs"), ("raw", "Advanced query")]
  Sorts* = [("relevance", "Most relevant"), ("newest", "Newest first"),
    ("updated", "Recently updated"), ("oldest", "Oldest first")]

proc defaultOptions*(): SearchOptions =
  SearchOptions(field: "all", sort: "relevance", page: 1, pageSize: 10)

proc allowed(value: string; choices: openArray[(string, string)]): bool =
  for choice in choices:
    if value == choice[0]: return true

proc validDate(value: string): bool =
  if value.len != 10: return false
  try:
    result = parse(value, "yyyy-MM-dd", utc()).format("yyyy-MM-dd") == value
  except TimeParseError, ValueError:
    result = false

proc validate*(options: SearchOptions) =
  if options.query.len > 1000 or options.author.len > 200:
    raise newException(ValueError, "Keep the search under 1,000 characters and the author under 200.")
  if not allowed(options.field, Fields) or not allowed(options.sort, Sorts) or
      not allowed(options.category, Categories):
    raise newException(ValueError, "Choose a valid search field, discipline, and sort order.")
  if options.pageSize notin [10, 25, 50] or options.page < 1 or
      options.page > MaxResults div options.pageSize:
    raise newException(ValueError, "Choose a valid page within the first 30,000 results.")
  for value in [options.dateFrom, options.dateTo]:
    if value.len > 0 and not validDate(value):
      raise newException(ValueError, "Enter dates in YYYY-MM-DD format.")
  if options.dateFrom.len > 0 and options.dateTo.len > 0 and options.dateFrom > options.dateTo:
    raise newException(ValueError, "The start date must be on or before the end date.")

proc parseOptions*(params: openArray[(string, string)]): SearchOptions =
  result = defaultOptions()
  for (key, value) in params:
    let value = value.strip()
    case key
    of "q": result.query = value
    of "field": result.field = value
    of "category": result.category = value
    of "author": result.author = value
    of "from": result.dateFrom = value
    of "to": result.dateTo = value
    of "sort": result.sort = value
    of "page", "size":
      try:
        let number = parseInt(value)
        if key == "page": result.page = number
        else: result.pageSize = number
      except ValueError:
        raise newException(ValueError, "Page and page size must be whole numbers.")
    else: discard

proc optionsFromQuery*(query: string): SearchOptions =
  ## Decode the original form query exactly once, including '+' as a space.
  var params: seq[(string, string)]
  for key, value in decodeQuery(query): params.add((key, value))
  parseOptions(params)

proc hasSearch*(options: SearchOptions): bool =
  options.query.len > 0 or options.category.len > 0 or options.author.len > 0 or
    options.dateFrom.len > 0 or options.dateTo.len > 0

proc quoted(value: string): string =
  "\"" & value.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc keywordQuery(value, field: string): string =
  ## Unquoted words are ANDed; quoted phrases remain a single term.
  var terms: seq[string]
  var token = ""
  var inQuote = false
  for ch in value:
    if ch == '"':
      inQuote = not inQuote
    elif ch in Whitespace and not inQuote:
      if token.len > 0:
        terms.add(field & ":" & quoted(token))
        token = ""
    else:
      token.add(ch)
  if inQuote:
    raise newException(ValueError, "Close the quotation mark around your search phrase.")
  if token.len > 0: terms.add(field & ":" & quoted(token))
  if terms.len == 0:
    raise newException(ValueError, "Enter a keyword or a phrase inside the quotation marks.")
  terms.join(" AND ")

proc idList(options: SearchOptions): string =
  var ids: seq[string]
  for part in options.query.split(','):
    let id = part.strip()
    if id.len == 0 or id.len > 80:
      raise newException(ValueError, "Enter comma-separated arXiv IDs, such as 1706.03762.")
    for ch in id:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '-', '/'}:
        raise newException(ValueError, "Use arXiv IDs rather than full URLs, separated by commas.")
    ids.add(id)
  if ids.len > 50:
    raise newException(ValueError, "Look up at most 50 arXiv IDs at a time.")
  ids.join(",")

proc searchExpression*(options: SearchOptions): string =
  options.validate()
  var parts: seq[string]
  if options.query.len > 0 and options.field != "id":
    let expression = if options.field == "raw": options.query
      else: keywordQuery(options.query, options.field)
    parts.add("(" & expression & ")")
  if options.category.len > 0: parts.add("cat:" & options.category)
  if options.author.len > 0: parts.add("au:" & quoted(options.author))
  if options.dateFrom.len > 0 or options.dateTo.len > 0:
    let first = if options.dateFrom.len > 0: options.dateFrom.replace("-", "") else: "19910101"
    let last = if options.dateTo.len > 0: options.dateTo.replace("-", "") else: now().utc.format("yyyyMMdd")
    parts.add("submittedDate:[" & first & "0000 TO " & last & "2359]")
  parts.join(" AND ")

proc apiQuery*(options: SearchOptions): string =
  let expression = options.searchExpression()
  if not options.hasSearch:
    raise newException(ValueError, "Enter a search term or choose a filter to get started.")
  var params: seq[(string, string)]
  if expression.len > 0: params.add(("search_query", expression))
  if options.field == "id" and options.query.len > 0:
    params.add(("id_list", options.idList()))
  let sortBy = case options.sort
    of "newest", "oldest": "submittedDate"
    of "updated": "lastUpdatedDate"
    else: "relevance"
  params.add(("start", $((options.page - 1) * options.pageSize)))
  params.add(("max_results", $options.pageSize))
  params.add(("sortBy", sortBy))
  params.add(("sortOrder", if options.sort == "oldest": "ascending" else: "descending"))
  encodeQuery(params)

proc pageUrl*(options: SearchOptions; page: int): string =
  "/?" & encodeQuery(@[("q", options.query), ("field", options.field),
    ("category", options.category), ("author", options.author),
    ("from", options.dateFrom), ("to", options.dateTo),
    ("sort", options.sort), ("size", $options.pageSize), ("page", $page)]) & "#results"

proc localName(node: XmlNode): string =
  if node.kind == xnElement: node.tag.split(':')[^1] else: ""

proc childText(node: XmlNode; name: string): string =
  for child in node:
    if child.localName == name: return child.innerText.splitWhitespace.join(" ")

proc feedNumber(root: XmlNode; name: string): int =
  try:
    result = parseInt(root.childText(name))
    if result < 0: raise newException(ValueError, "negative number")
  except ValueError:
    raise apiError("arXiv returned an incomplete response. Please try again.")

proc parseFeed*(xml: string): SearchResult =
  var root: XmlNode
  try:
    root = parseXml(xml)
  except XmlError, ValueError:
    raise apiError("arXiv returned a response we could not read. Please try again.")
  if root.localName != "feed":
    raise apiError("arXiv returned a response we could not read. Please try again.")
  for entry in root:
    if entry.localName != "entry": continue
    let sourceId = entry.childText("id")
    if entry.childText("title").toLowerAscii == "error" or "/api/errors" in sourceId:
      raise apiError("arXiv could not complete this query: " & entry.childText("summary"), 422)
    let idUri = parseUri(sourceId)
    if idUri.hostname notin ["arxiv.org", "www.arxiv.org"] or not idUri.path.startsWith("/abs/"):
      raise apiError("arXiv returned a paper without a valid identifier. Please try again.")
    let id = idUri.path[5..^1]
    if id.len == 0: raise apiError("arXiv returned an empty paper identifier.")
    for ch in id:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '-', '/'}:
        raise apiError("arXiv returned an invalid paper identifier.")
    var paper = Paper(id: id, title: entry.childText("title"),
      summary: entry.childText("summary"), published: entry.childText("published"),
      updated: entry.childText("updated"), comment: entry.childText("comment"),
      journal: entry.childText("journal_ref"), doi: entry.childText("doi"))
    for child in entry:
      case child.localName
      of "author": paper.authors.add(child.childText("name"))
      of "category": paper.categories.add(child.attr("term"))
      of "primary_category": paper.primaryCategory = child.attr("term")
      else: discard
    result.papers.add(paper)
  result.total = root.feedNumber("totalResults")
  result.start = root.feedNumber("startIndex")
  result.pageSize = root.feedNumber("itemsPerPage")

import std/[unittest, strutils, uri, sequtils, xmltree, strtabs]
import pkg/htmlparser
import happyx/spa/tag
import arxiv, views

const fixture = staticRead("fixtures/results.xml")
const emptyFeed = """<feed xmlns="http://www.w3.org/2005/Atom" xmlns:o="http://a9.com/-/spec/opensearch/1.1/"><o:totalResults>0</o:totalResults><o:startIndex>0</o:startIndex><o:itemsPerPage>10</o:itemsPerPage></feed>"""

suite "arXiv query behavior":
  test "browser forms decode spaces, literal plus signs, and percent escapes once":
    let options = optionsFromQuery("q=C%2B%2B+and+%2520&author=Ashish+Vaswani&field=ti")
    check options.query == "C++ and %20"
    check options.author == "Ashish Vaswani"
    check options.field == "ti"
    check options.searchExpression == "(ti:\"C++\" AND ti:\"and\" AND ti:\"%20\") AND au:\"Ashish Vaswani\""

  test "keywords apply the field to each term and preserve quoted phrases":
    var options = defaultOptions()
    options.query = "graph \"neural networks\""
    options.field = "ti"
    check options.searchExpression == "(ti:\"graph\" AND ti:\"neural networks\")"

  test "advanced Boolean expressions are grouped before filters":
    var options = defaultOptions()
    options.query = "ti:electron OR ti:proton"
    options.field = "raw"
    options.category = "quant-ph"
    options.author = "Del Maestro"
    options.dateFrom = "2024-01-01"
    options.dateTo = "2024-12-31"
    check options.searchExpression == "(ti:electron OR ti:proton) AND cat:quant-ph AND au:\"Del Maestro\" AND submittedDate:[202401010000 TO 202412312359]"

  test "ID lookups use id_list, with filters as a separate search_query":
    var options = defaultOptions()
    options.query = "1706.03762v7, hep-ex/0307015"
    options.field = "id"
    var pairs = toSeq(decodeQuery(options.apiQuery()))
    check ("id_list", "1706.03762v7,hep-ex/0307015") in pairs
    check not pairs.anyIt(it[0] == "search_query")
    options.category = "cs.CL"
    pairs = toSeq(decodeQuery(options.apiQuery()))
    check ("search_query", "cat:cs.CL") in pairs

  test "pagination, sorting, URL encoding, and filter round trips":
    var options = defaultOptions()
    options.query = "C++ & Schrödinger"
    options.author = "A & B"
    options.pageSize = 25
    options.page = 3
    options.sort = "oldest"
    let pairs = toSeq(decodeQuery(options.apiQuery()))
    check ("start", "50") in pairs
    check ("max_results", "25") in pairs
    check ("sortBy", "submittedDate") in pairs
    check ("sortOrder", "ascending") in pairs
    let roundTrip = parseOptions(toSeq(decodeQuery(parseUri(options.pageUrl(3)).query)))
    check roundTrip == options

  test "rejects invalid date ranges and dates":
    var options = defaultOptions()
    options.dateFrom = "2024-02-30"
    expect ValueError: options.validate()
    options.dateFrom = "2025-01-01"
    options.dateTo = "2024-12-31"
    expect ValueError: options.validate()
    options.dateFrom = "2024-02-29"
    options.validate()

  test "rejects invalid paging, fields, sort, oversized and incomplete queries":
    expect ValueError: discard parseOptions(@[("page", "hello")])
    for params in [@[("page", "0")], @[("size", "2000")], @[("page", "3001")],
        @[("field", "unknown")], @[("category", "cs.* OR all:*")], @[("sort", "unknown")]]:
      expect ValueError: parseOptions(params).validate()
    var options = defaultOptions()
    options.query = repeat("x", 1001)
    expect ValueError: discard options.apiQuery()
    options.query = "\"unclosed phrase"
    expect ValueError: discard options.apiQuery()
    options.query = "\"\""
    expect ValueError: discard options.apiQuery()
    options.query = ""
    expect ValueError: discard options.apiQuery()

suite "Atom feeds and rendering":
  test "parses authors, namespaces, Unicode, entities, and optional metadata":
    let data = parseFeed(fixture)
    check data.total == 21
    check data.start == 0
    check data.papers.len == 2
    let first = data.papers[0]
    check first.title == "Attention Is All You Need"
    check first.authors == @["Ashish Vaswani", "Noam Shazeer"]
    check first.categories == @["cs.CL", "cs.LG"]
    check first.primaryCategory == "cs.CL"
    check "Schrödinger" in first.summary
    check "A & B < C" in first.summary
    check first.doi == "10.0000/test-fixture"
    check data.papers[1].id == "hep-ex/0307015v1"
    check data.papers[1].doi == ""

  test "handles empty results and rejects malformed or incomplete responses":
    check parseFeed(emptyFeed).papers.len == 0
    for xml in ["<html>Unavailable</html>", "<feed>", "<feed/>", "not XML"]:
      expect ApiError: discard parseFeed(xml)

  test "recognizes API errors even in successful HTTP responses":
    expect ApiError:
      discard parseFeed("""<feed><entry><id>http://arxiv.org/api/errors#incorrect_id_format</id><title>Error</title><summary>Incorrect id format</summary></entry></feed>""")

  test "blocks untrusted paper link hosts":
    expect ApiError: discard parseFeed(fixture.replace("http://arxiv.org/abs/1706.03762v7", "javascript:alert(1)"))

  test "escapes query, paper, and upstream error content":
    var options = defaultOptions()
    options.query = "<script>alert(1)</script>"
    var data = parseFeed(fixture)
    data.papers[0].title = "<img src=x onerror=alert(1)>"
    let page = $renderPage(options, data)
    check "<script>alert(1)</script>" notin page
    check "&lt;script&gt;alert(1)&lt;/script&gt;" in page
    check "<img src=x" notin page
    check "&lt;img src=x" in page
    check "https://arxiv.org/pdf/1706.03762v7" in page
    check "Next →" in page
    check "<img src=x" notin $renderPage(options, error = "<img src=x>")

  test "empty state, page boundaries, and homepage do not invent results":
    let home = $renderPage(defaultOptions())
    check "Where will your next idea begin?" in home
    check "class=\"paper\"" notin home
    var options = defaultOptions()
    options.query = "nothing"
    let empty = parseHtml($renderPage(options, parseFeed(emptyFeed)))
    check "No papers found" in empty.innerText
    check not empty.findAll("a").anyIt(it.innerText.strip == "Next →")
    check "reached the end" in $renderPage(options, SearchResult(total: 2))

  test "HTML trees preserve document structure, form attributes, and literal entities":
    var options = defaultOptions()
    options.query = "literal &quot; <angle> \"quote\" + C++"
    options.author = "A & B"
    options.field = "ti"
    options.category = "cs.CL"
    options.sort = "oldest"
    options.pageSize = 25
    let html = $renderPage(options, parseFeed(fixture))
    check html.strip.startsWith("<!DOCTYPE html>")
    let tree = parseHtml(html)
    check tree.findAll("head").len == 1
    check tree.findAll("body").len == 1
    let input = tree.findAll("input").filterIt(it.attr("id") == "q")[0]
    check input.attr("value") == options.query
    check input.attr("type") == "search"
    check input.attr("aria-describedby") == "query-hint"
    for select in tree.findAll("select"):
      let selected = select.findAll("option").filterIt("selected" in it.attrs)
      check selected.len == 1
      let expected = case select.attr("id")
        of "field": "ti"
        of "category": "cs.CL"
        of "sort": "oldest"
        else: "25"
      check selected[0].attr("value") == expected
    check tree.findAll("label").anyIt(it.attr("for") == "q")
    let next = tree.findAll("a").filterIt(it.innerText.strip == "Next →")
    # There are 21 fixture matches and 25 per page, so no next link is rendered.
    check next.len == 0

import std/[unittest, json, uri, strutils, tables, xmltree, sequtils, strtabs]
import pkg/htmlparser
import happyx/spa/tag
import api_errors, patents, patent_views

const
  fixture = staticRead("fixtures/patents.json")
  detail = staticRead("fixtures/patent.html")

proc params(query: string): Table[string, string] =
  for key, value in decodeQuery(query): result[key] = value

suite "Patent queries and provider responses":
  test "decodes form input once and preserves literal plus signs and nested encoding":
    let options = patentOptionsFromQuery("q=neural+network%2BC%2B%2B%26x%3D1%2520&country=us&assignee=A%26B&page=2&size=25&sort=oldest&after=2020-02-29&before=2025-01-01")
    let outer = params(parseUri(options.patentApiPath()).query)
    check "after=filing:20200229" in outer["url"]
    check "before=filing:20250101" in outer["url"]
    let inner = params(outer["url"])
    check inner["q"] == "neural network+C++&x=1%20"
    check inner["country"] == "US"
    check inner["assignee"] == "A&B"
    check inner["after"] == "filing:20200229"
    check inner["before"] == "filing:20250101"
    check inner["sort"] == "old"
    check inner["type"] == "PATENT"
    check inner["page"] == "1"
    check inner["num"] == "25"
    let next = params(parseUri(options.patentPageUrl(3)).query)
    check next["page"] == "3"
    check next["q"] == options.query
    check next["assignee"] == "A&B"

  test "rejects bad parameters before contacting the provider":
    for query in ["", "q=x&page=0", "q=x&page=101", "q=x&size=11", "q=x&page=abc",
        "q=x&sort=invalid", "q=x&country=USA", "q=x&after=2025-02-29",
        "q=x&after=2020-01-01&before=2020-01-01", "q=x&unknown=1",
        "q=" & repeat('a', 1001)]:
      expect ValueError: discard patentOptionsFromQuery(query).patentApiPath()
    check "assignee" in patentOptionsFromQuery("assignee=Google").patentApiPath()

  test "normalizes highlighted search snippets and optional metadata":
    let data = parsePatentSearch(fixture, patentOptionsFromQuery("q=neural"))
    check data["total"].getInt() == 23
    check data["total_is_approximate"].getBool()
    check data["has_next"].getBool()
    check data["results"].len == 2
    let patent = data["results"][0]
    check patent["title"].getStr() == "Synthetic neural device & sensor …"
    check patent["inventor"].getStr() == "Renée Example"
    check patent["assignee"].getStr() == "Research & Development"
    check patent["snippet"].getStr() == "A synthetic fixture with <untrusted> text."
    check patent["url"].getStr() == "https://patents.google.com/patent/US1234567B1/en"
    check patent["pdf_url"].getStr().startsWith("https://patentimages.storage.googleapis.com/")
    check data["results"][1]["pdf_url"].getStr() == ""
    check data["results"][1]["inventor"].getStr() == ""

  test "handles empty results, provider page limits, and schema changes":
    let options = patentOptionsFromQuery("q=neural")
    let empty = parsePatentSearch("""{"results":{"total_num_results":0,"total_num_pages":0,"num_page":0,"cluster":[{}]}}""", options)
    check empty["results"].len == 0
    check not empty["has_next"].getBool()
    let limited = parsePatentSearch(fixture.replace("\"total_num_results\": 23", "\"total_num_results\": 100000").replace("\"total_num_pages\": 3", "\"total_num_pages\": 1"), options)
    check not limited["has_next"].getBool()
    for invalid in ["not JSON", "{}", "[]", "{\"results\":{}}", "<html>Challenge</html>",
        fixture.replace("\"num_page\": 0", "\"num_page\": 1"),
        fixture.replace("US1234567B1", "../../outside")]:
      expect ApiError: discard parsePatentSearch(invalid, options)

  test "lookup accepts publication identifiers and rejects URLs or traversal":
    check publicationId("us9014905b1") == "US9014905B1"
    check publicationId("USRE12345E") == "USRE12345E"
    for invalid in ["https://example.com", "../secret", "US123/other", "US123?x", "US 123 A1", "ABCD", "123456"]:
      expect ValueError: discard publicationId(invalid)

  test "extracts full document metadata and verifies the primary publication":
    let data = parsePatentDetail(detail, "US1234567B1")
    check data["title"].getStr() == "Synthetic device & sensor"
    check data["abstract"].getStr() == "A synthetic abstract with <untrusted> text."
    check data["inventors"] == %*["Renée Example", "Alex Example"]
    check data["original_assignees"] == %*["Research & Development"]
    check data["filing_date"].getStr() == "2020-03-01"
    expect ApiError: discard parsePatentDetail(detail, "US7654321B2")
    expect ApiError: discard parsePatentDetail("<html>Consent required</html>", "US1234567B1")
    let unsafe = detail.replace("https://patentimages.storage.googleapis.com/", "https://evil.example/")
    check parsePatentDetail(unsafe, "US1234567B1")["pdf_url"].getStr() == ""

  test "renders escaped HappyX forms, source navigation, links, and empty states":
    var options = patentOptionsFromQuery("q=%3Cimg+src%3Dx%3E%26quot%3B&country=US&assignee=A%26B&sort=newest")
    let data = parsePatentSearch(fixture, options)
    let html = $renderPatentPage(options, data)
    let tree = parseHtml(html)
    check tree.findAll("head").len == 1
    check tree.findAll("body").len == 1
    check "<img src=x>" notin html
    check "<untrusted>" notin html
    check tree.findAll("input").filterIt(it.attr("id") == "q")[0].attr("value") == options.query
    check tree.findAll("input").filterIt(it.attr("id") == "assignee")[0].attr("form") == "search-form"
    check tree.findAll("a").anyIt(it.attr("href") == "/" and it.innerText.strip == "Papers")
    check tree.findAll("a").anyIt(it.innerText.strip == "Next →")
    let pdfLinks = tree.findAll("a").filterIt(it.innerText.strip == "Read PDF →")
    check pdfLinks.len == 1
    check pdfLinks[0].attr("href") == "/document?source=patents&id=US1234567B1&view=pdf"
    check pdfLinks[0].attr("target") == ""
    let analyses = tree.findAll("button").filterIt(it.attr("data-analysis-source") == "patents")
    check analyses.len == data["results"].len
    check analyses[0].attr("data-analysis-id") == "US1234567B1"
    for select in tree.findAll("select"):
      check select.findAll("option").filterIt("selected" in it.attrs).len == 1
    check "class=\"paper\"" notin $renderPatentPage(defaultPatentOptions())
    let error = $renderPatentPage(options, error = "<img src=x>")
    check "role=\"alert\"" in error
    check "<img src=x>" notin error

  test "uses stable JSON error codes":
    check patentErrorJson(400, "Bad query")["error"]["code"].getStr() == "invalid_request"
    check patentErrorJson(503, "Busy")["error"]["code"].getStr() == "unavailable"

## Uses only the built executable, temporary files and a loopback server.
import std/[unittest, os, osproc, tempfiles, httpclient, json, net, strutils, streams]

let directory = createTempDir("graph-http-", "")
let executable = absolutePath("bin/turncoat")
let dbPath = directory / "app.db"
let socket = newSocket()
socket.bindAddr(Port(0), "127.0.0.1")
let port = socket.getLocalAddr()[1].int
socket.close()
let origin = "http://127.0.0.1:" & $port

proc cli(args: seq[string]; database = dbPath): tuple[output: string, code: int] =
  let process = startProcess(executable, args = @["--db:" & database] & args,
    options = {poStdErrToStdOut})
  defer: process.close()
  result.output = process.outputStream.readAll()
  result.code = process.waitForExit()

proc jsonResponse(client: HttpClient; path: string; expected = 200): JsonNode =
  let response = client.get(origin & path)
  check response.code.int == expected
  check response.headers["Content-Type"].startsWith("application/json")
  parseJson(response.body)

try:
  suite "Graph executable and HappyX HTTP integration":
    test "CLI init, import, stats, export and re-import":
      check cli(@["init"]).code == 0
      check cli(@["import", "demo", "tests/fixtures/graph/demo.jsonl"]).code == 0
      check cli(@["import", "demo", "tests/fixtures/graph/demo.jsonl"]).code == 0
      check parseJson(cli(@["stats", "demo"]).output)["nodes"].getInt == 4
      let output = directory / "export.jsonl"
      check cli(@["export", "demo", output]).code == 0
      check cli(@["import", "copy", output], directory / "copy.db").code == 0
      check parseJson(cli(@["stats", "copy"], directory / "copy.db").output)["edges"].getInt == 3
      check cli(@["stats", "absent"]).code != 0
      check cli(@["export", "demo", dbPath]).code != 0
      check cli(@["--port:70000", "serve"]).code != 0

  # Includes slashes, literal percent escapes and '+' to verify URL decoding once.
  let unusual = directory / "unusual.jsonl"
  writeFile(unusual, """{"type":"node","oid":"test:a/b+%2F","label":"Unusual","properties":{"name":"Odd identifier"}}""" & "\n")
  doAssert cli(@["import", "other", unusual]).code == 0
  let server = startProcess(executable, args = @["--db:" & dbPath, "--port:" & $port, "--neighbor-limit:1", "serve"],
    options = {poParentStreams})
  let client = newHttpClient(timeout = 1500)
  try:
    var ready = false
    for attempt in 0..<100:
      try:
        if client.get(origin & "/api/health").code == Http200:
          ready = true
          break
      except CatchableError: discard
      sleep(50)
    doAssert ready, "HappyX failed to start"
    suite "Live read-only graph API":
      test "health, datasets and locally bundled assets":
        check client.jsonResponse("/api/health")["fts5"].getBool
        check client.jsonResponse("/api/datasets")["datasets"].len == 2
        check "Project Turncoat" in client.getContent(origin & "/")
        check "Project Turncoat" in client.getContent(origin & "/graph")
        check client.get(origin & "/assets/d3.v7.min.js").code == Http200
        check client.get(origin & "/assets/graph.js").code == Http200
        check client.get(origin & "/assets/app.css").code == Http200
        for path in ["/chat", "/chat/guide", "/document", "/assets/chat.js", "/assets/chat.css", "/assets/chat-markdown.js", "/assets/markdown.css", "/assets/markdown-it.min.js", "/assets/document.js", "/assets/json-tree.js", "/assets/json-tree.css", "/assets/pdf-context.js", "/docs/llm-chat.md", "/settings", "/assets/research.css", "/assets/research-ui.js", "/assets/settings.js", "/assets/drilldowns.js", "/docs/graph-drilldowns.md"]:
          check client.get(origin & path).code == Http200
        check cli(@["--port:" & $port, "serve"]).code != 0
      test "search, selected node and URL-encoded OIDs":
        let found = client.jsonResponse("/api/demo/search?q=Example&labels=Person")
        check found["nodes"].len == 1
        check found["nodes"][0]["id"].getStr == "demo:person:1"
        check client.jsonResponse("/api/demo/node/demo%3Aperson%3A1")["label"].getStr == "Person"
        check client.jsonResponse("/api/other/node/test%3Aa%2Fb%2B%252F")["id"].getStr == "test:a/b+%2F"
      test "neighbor pagination, edge records and bounded subgraph":
        let first = client.jsonResponse("/api/demo/node/demo:person:1/neighbors")
        check first["nodes"].len == 2
        check first["links"].len == 1
        check first["meta"]["total"].getInt == 3
        check first["meta"]["nextOffset"].getInt == 1
        let next = client.jsonResponse("/api/demo/node/demo:person:1/neighbors?offset=1")
        check next["links"][0]["id"] != first["links"][0]["id"]
        check client.jsonResponse("/api/demo/node/demo:person:1/edges?limit=3")["links"].len == 3
        check client.jsonResponse("/api/demo/subgraph/demo:person:1?depth=0")["nodes"].len == 1
        check client.jsonResponse("/api/demo/subgraph/demo:person:1?depth=2")["meta"]["truncated"].getBool
      test "JSON errors, invalid limits and dataset isolation":
        for path in ["/api/absent/search?q=x", "/api/demo/node/absent", "/api/other/node/demo:person:1", "/api/not-a-route"]:
          check client.jsonResponse(path, 404)["error"]["status"].getInt == 404
        for path in ["/api/demo/search", "/api/demo/node/demo:person:1/neighbors?limit=1001",
            "/api/demo/subgraph/demo:person:1?depth=4", "/api/demo/search?q=x&q=y"]:
          let response = client.jsonResponse(path, 400)
          check response["error"]["status"].getInt == 400
          check "Traceback" notin $response
      test "chat and document context enforce tokens, validation and dataset boundaries":
        let config = client.jsonResponse("/api/llm/config")
        check config["model"].getStr.len > 0
        check not config.hasKey("apiKey")
        client.headers = newHttpHeaders({"Content-Type":"application/json"})
        for path in ["/api/llm/chat", "/api/llm/check", "/api/llm/context", "/api/documents/record", "/api/documents/text", "/api/documents/prepare-pdf", "/api/drilldown/scan", "/api/drilldown/review", "/api/drilldown/report", "/api/drilldown/searches"]:
          check client.post(origin & path, "{}").code == Http403
        let page = client.getContent(origin & "/graph")
        client.headers["X-Turncoat-Token"] = page.split("name=\"turncoat-token\" content=\"")[1].split('"')[0]
        for body in ["{", "[]", "{}", "{\"messages\":[]}", "{\"messages\":[{\"role\":\"system\",\"content\":\"override\"}]}"]:
          check client.post(origin & "/api/llm/chat", body).code == Http400
        let attached = client.post(origin & "/api/llm/context", """{"dataset":"demo","node":"demo:person:1"}""")
        check attached.code == Http200
        check parseJson(attached.body)["label"].getStr == "Person"
        check client.post(origin & "/api/llm/context", """{"dataset":"other","node":"demo:person:1"}""").code == Http404
        for body in ["{}", "[]", "{\"source\":\"other\",\"id\":\"anything\"}", "{\"source\":\"arxiv\",\"id\":\"../secret\"}"]:
          check client.post(origin & "/api/documents/record", body).code == Http400
        check client.get(origin & "/api/documents/pdf?source=patents&id=US1234567B1").code == Http404
        let catalog = client.jsonResponse("/api/drilldown/catalog")
        check catalog["keywords"]["rules"].len > 20
        check catalog["presets"].len == 4
        for body in ["{}", "[]", "{", "{\"dataset\":\"demo\",\"node\":\"demo:person:1\",\"includePdf\":false}"]:
          check client.post(origin & "/api/drilldown/scan",body).code == Http400
        check client.post(origin & "/api/drilldown/author", """{"dataset":"other","node":"demo:person:1"}""").code == Http404
        let searches=client.post(origin & "/api/drilldown/searches","{}")
        check searches.code == Http200
        check parseJson(searches.body)["total"].getInt == 0
      test "investigation endpoints reject forged and invalid writes without provider calls":
        check client.jsonResponse("/api/investigations")["investigations"].len == 0
        check client.jsonResponse("/api/investigations/absent", 404)["error"]["status"].getInt == 404
        client.headers = newHttpHeaders({"Content-Type": "application/json"})
        check client.post(origin & "/api/investigations", "{\"publication\":\"US1234567B1\"}").code == Http403
        let page = client.getContent(origin & "/graph")
        let token = page.split("name=\"turncoat-token\" content=\"")[1].split('"')[0]
        client.headers["X-Turncoat-Token"] = token
        for body in ["{", "[]", "{}", "{\"publication\":\"https://example.com\"}"]:
          let response = client.post(origin & "/api/investigations", body)
          check response.code == Http400
          check parseJson(response.body)["error"]["status"].getInt == 400
        check client.jsonResponse("/api/investigations")["investigations"].len == 0
      test "read-only sharing links preserve a snapshot and can be revoked":
        let file=directory/"share-root.jsonl"
        writeFile(file,"""{"type":"node","oid":"demo:investigation","label":"Investigation","properties":{"schema":"turncoat/investigation/v1","seed":"demo:paper:1","publicationNumber":"Synthetic share"}}""" & "\n")
        check cli(@["import","demo",file]).code==0
        client.headers=newHttpHeaders({"Content-Type":"application/json"})
        check client.post(origin & "/api/shares/create","{}").code==Http403
        let page=client.getContent(origin & "/graph")
        client.headers["X-Turncoat-Token"]=page.split("name=\"turncoat-token\" content=\"")[1].split('"')[0]
        check client.post(origin & "/api/shares/create","[]").code==Http400
        let created=client.post(origin & "/api/shares/create","""{"dataset":"demo","includeReports":true}""")
        check created.code==Http200
        let share=parseJson(created.body)
        let sharedPage=client.get(origin & share["path"].getStr)
        check sharedPage.code==Http200
        check "turncoat-token" notin sharedPage.body
        check sharedPage.headers["Referrer-Policy"]=="no-referrer"
        let data=client.get(origin & share["path"].getStr & "/data")
        check data.code==Http200
        check parseJson(data.body)["nodes"].len==5
        check data.headers["Cache-Control"]=="no-store"
        check client.post(origin & "/api/shares/revoke",$(%*{"dataset":"demo","token":share["token"]})).code==Http200
        check client.get(origin & share["path"].getStr & "/data").code==Http404
        check client.jsonResponse("/api/documents/config")["pageLimit"].getInt==40
  finally:
    client.close()
    server.terminate()
    discard server.waitForExit()
    server.close()
finally:
  removeDir(directory)

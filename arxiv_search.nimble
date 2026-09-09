version = "0.1.0"
author = "arXiv Explorer contributors"
description = "Project Turncoat: papers, patents, and local graph investigations in Nim"
license = "MIT"
srcDir = "src"
binDir = "bin"
bin = @["turncoat"]
requires "nim >= 2.2.0"
requires "happyx == 4.7.4"
requires "htmlparser == 0.1.0"
requires "checksums == 0.2.2"
requires "grim == 0.3.1"
requires "db_connector == 0.1.0"
# Grim 0.3.1 expects NimYAML's pre-1.0 top-level hint API.
requires "yaml == 0.16.0"

proc runFacultyTests() =
  for name in ["hit", "nuaa", "npu", "faculty", "http_client"]:
    exec "nim c -r --path:src --out:bin/test_faculty_" & name & " tests/faculty/test_" & name & ".nim"

task test, "Test research queries, provider parsing, rendering, and API behavior":
  exec "nim c -r --nimblePath:.nimble/pkgs2 --path:src --out:bin/test_arxiv tests/test_arxiv.nim"
  exec "nim c -r --path:src --out:bin/test_client tests/test_client.nim"
  exec "nim c -r --nimblePath:.nimble/pkgs2 --path:src --out:bin/test_patents tests/test_patents.nim"
  exec "nim c -r --path:src --out:bin/test_patents_client tests/test_patents_client.nim"
  exec "nim c -r --path:src --out:bin/test_institutions tests/test_institutions.nim"
  runFacultyTests()
  exec "nim c -r --path:src --out:bin/test_graph tests/test_graph.nim"
  exec "nim c -r --path:src --out:bin/test_investigations tests/test_investigations.nim"

task testFaculty, "Run faculty fixture and loopback HTTP tests (no university traffic)":
  runFacultyTests()

task testInvestigations, "Test bounded discovery against SQLite and local provider fixtures":
  exec "nim c -r --path:src --out:bin/test_investigations tests/test_investigations.nim"

task testFacultyLive, "Opt-in limited requests to public university sites":
  exec "nim c -r --path:src --out:bin/test_faculty_live tests/faculty/test_live.nim"

task testGraph, "Test local graph models, storage, JSONL, traversal and API":
  exec "nim c -r --path:src --out:bin/test_graph tests/test_graph.nim"

task testGraphHttp, "Build and exercise graph CLI and loopback HappyX API":
  exec "nim c --out:bin/turncoat src/turncoat.nim"
  exec "nim c -r --path:src --out:bin/test_graph_http tests/test_graph_http.nim"

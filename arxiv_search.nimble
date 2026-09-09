version = "0.1.0"
author = "arXiv Explorer contributors"
description = "A Nim and HappyX interface for discovering arXiv papers and Google Patents"
license = "MIT"
srcDir = "src"
binDir = "bin"
bin = @["arxiv_search"]
requires "nim >= 2.2.0"
requires "happyx == 4.7.4"
requires "htmlparser == 0.1.0"

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

task testFaculty, "Run faculty fixture and loopback HTTP tests (no university traffic)":
  runFacultyTests()

task testFacultyLive, "Opt-in limited requests to public university sites":
  exec "nim c -r --path:src --out:bin/test_faculty_live tests/faculty/test_live.nim"

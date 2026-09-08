version = "0.1.0"
author = "arXiv Explorer contributors"
description = "A Nim and HappyX interface for discovering arXiv papers"
license = "MIT"
srcDir = "src"
binDir = "bin"
bin = @["arxiv_search"]
requires "nim >= 2.2.0"
requires "happyx == 4.7.4"

task test, "Test query construction, Atom parsing, rendering, and API behavior":
  exec "nim c -r --nimblePath:.nimble/pkgs2 --path:src --out:bin/test_arxiv tests/test_arxiv.nim"
  exec "nim c -r --path:src --out:bin/test_client tests/test_client.nim"

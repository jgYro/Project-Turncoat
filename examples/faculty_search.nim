## A bounded library example, independent of the HappyX application.
## nim c -r --path:src --out:bin/faculty_search examples/faculty_search.nim HIT 张昊春
import std/[asyncdispatch, json, os, strutils]
import faculty/faculty

if paramCount() != 2:
  quit("Usage: faculty_search HIT|NUAA|NPU|all QUERY", 1)

let client = newFacultyClient()
let limits = CrawlLimits(maxPages: 1, maxProfiles: 3)
let provider = paramStr(1).toLowerAscii()
let data = if provider == "all":
    waitFor searchAllFaculty(paramStr(2), client, limits)
  else:
    waitFor searchFaculty(parseEnum[Institution](provider), paramStr(2), client, limits)
echo data.toJson().pretty()

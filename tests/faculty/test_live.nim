## Explicitly opt-in: makes a small number of real public university requests.
## Normal `nimble test` never runs this file.
import std/[asyncdispatch, unittest, options]
import faculty/[types, http_client]
import faculty/institutions/HIT
import faculty/institutions/NUAA
import faculty/institutions/NPU

proc checks() {.async.} =
  let client = newFacultyClient(maxRetries = 0)
  let limits = CrawlLimits(maxPages: 1, maxProfiles: 1)
  let hitResult = await HIT.searchFaculty("张昊春", client, limits)
  check hitResult.records.len == 1
  if hitResult.records.len > 0:
    check hitResult.records[0].name == "张昊春"
    echo "HIT: ", hitResult.records[0].name
  for issue in hitResult.issues: check issue.status == 206

  let nuaaResult = await NUAA.searchFaculty("刘长江", client, limits)
  check nuaaResult.records.len == 1
  if nuaaResult.records.len > 0:
    check nuaaResult.records[0].name == "刘长江"
    echo "NUAA: ", nuaaResult.records[0].name
  for issue in nuaaResult.issues: check issue.status == 206

  let npuResult = await NPU.enumerateFaculty(client, limits, @[NpuDirectories[0]])
  check npuResult.records.len == 1
  if npuResult.records.len > 0:
    check npuResult.records[0].name.len > 0
    echo "NPU Mathematics: ", npuResult.records[0].name
  for issue in npuResult.issues: check issue.status == 206
  # Check the public Management table without requesting its challenged portal links.
  let management = NPU.parseDirectory(
    await client.fetchProfileHtml(NpuDirectories[1], NpuHosts), NpuDirectories[1], limits)
  check management.profiles.len == 1
  if management.profiles.len > 0:
    check management.profiles[0].directoryRecord.title.isSome
    echo "NPU Management: ", management.profiles[0].directoryRecord.name

suite "Opt-in live faculty smoke test":
  test "public search, directory discovery, and profile retrieval": waitFor checks()

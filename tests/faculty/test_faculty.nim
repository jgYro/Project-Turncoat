import std/[unittest, asyncdispatch, strutils, json, uri]
import faculty/faculty

const
  hitDirectory = staticRead("../fixtures/hit/directory.json")
  hitProfile = staticRead("../fixtures/hit/profile.html")
  hitBody = staticRead("../fixtures/hit/body.json")
  npuDirectory = staticRead("../fixtures/npu/directory_math.html")
  npuProfile = staticRead("../fixtures/npu/profile_math.html")

proc concurrentChecks() {.async.} =
  var hosts: seq[string]
  let gate = newFuture[void]("three institutions started")
  let transport: FacultyTransport = proc(url, body: string): Future[FacultyHttpResponse] {.async, gcsafe.} =
    let host = parseUri(url).hostname
    if host notin hosts: hosts.add(host)
    if hosts.len == 3 and not gate.finished: gate.complete()
    await gate
    if host == "faculty.nuaa.edu.cn": return FacultyHttpResponse(status: 500)
    if "findTeachersByName" in url: return FacultyHttpResponse(status: 200, body: hitDirectory)
    if "teacherBody" in url: return FacultyHttpResponse(status: 200, body: hitBody)
    if host == "homepage.hit.edu.cn": return FacultyHttpResponse(status: 200, body: hitProfile)
    if "/jsfc/" in url: return FacultyHttpResponse(status: 200, body: npuDirectory)
    return FacultyHttpResponse(status: 200, body: npuProfile)
  let client = newFacultyClient(intervalMs = 0, maxRetries = 0, transport = transport)
  let pending = searchAllFaculty("", client, CrawlLimits(maxPages: 1, maxProfiles: 1))
  let completed = await withTimeout(pending, 2000)
  check completed
  if not completed: return
  let data = await pending
  check hosts.len == 3
  check data.records.len == 2
  check data.records[0].institution == "HIT"
  check data.records[1].institution == "NPU"
  check not data.complete
  var nuaaFailed = false
  for issue in data.issues:
    if issue.institution == "NUAA": nuaaFailed = true
  check nuaaFailed
  check data.toJson()["records"].len == 2

suite "Generic faculty dispatcher":
  test "pure parsing dispatches without HTTP and retains unknown raw fields":
    let record = parseFaculty(hit, hitProfile, "https://homepage.hit.edu.cn/zhc")
    check record.institution == "HIT"
    check record.toJson()["rawHtml"].getStr() == hitProfile
    check record.toJson()["name"].getStr() == "张昊春"
  test "search-all starts concurrently and survives an institution failure":
    waitFor concurrentChecks()

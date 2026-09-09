import std/[unittest, options, tables, json, strutils, asyncdispatch]
import faculty/[types, http_client]
import faculty/institutions/NPU
import api_errors

const
  profile = staticRead("../fixtures/npu/profile_math.html")
  mathDirectory = staticRead("../fixtures/npu/directory_math.html")
  management = staticRead("../fixtures/npu/directory_management.html")
  url = "https://math.nwpu.edu.cn/info/1502/37427.htm"

suite "NPU school-specific faculty parsing":
  test "Chinese biography and complete research paragraphs remain unaltered":
    let record = NPU.parseFaculty(profile, url)
    check record.institution == "NPU"
    check record.name == "高娅莉"
    check record.nameZh.get() == "高娅莉"
    check record.title.isNone # The narrative is not used to infer a structured title.
    check record.researchAreas.len == 1
    check "研究方向为偏微分方程数值解" in record.researchAreas[0]
    check record.rawFields.hasKey("个人简介")
    check "https://teacher.nwpu.edu.cn/gaoyalimath.html" in record.rawFields["个人教师主页"]
    check record.profileUrl == url
    check record.rawHtml == profile

  test "management table has explicit titles, departments, and research text":
    let page = NPU.parseDirectory(management, NpuDirectories[1])
    check page.profiles.len == 10
    let record = page.profiles[0].directoryRecord
    check record.name == "赵嵩正"
    check record.title.get() == "教授"
    check record.department.get() == "信息管理系"
    check record.researchAreas == @["信息管理与信息系统、设备管理、项目管理"]
    check record.profileUrl == "https://teacher.nwpu.edu.cn/zhaosongzheng.html"
    check record.sourceUrl == NpuDirectories[1]
    check page.nextPages[0].endsWith("/js/3.htm")
    check record.toJson()["school"].kind == JNull

  test "mathematics discovery excludes navigation and uses the actual next link":
    let page = NPU.parseDirectory(mathDirectory, NpuDirectories[0])
    check page.profiles.len == 12
    check page.profiles[0].directoryRecord.name.len > 0
    check page.nextPages[0] == "https://math.nwpu.edu.cn/jsfc/jsfc/2.htm"
    check NPU.profileUrl("https://evil.test/info/1502/1.htm", url) == ""
    check NPU.profileUrl("../1502/37427.htm", url) == url
    expect ApiError: discard NPU.parseDirectory("<html>error</html>", NpuDirectories[0])

  test "explicit metadata, duplicate labels, missing fields, and partial HTML":
    let html = """<div class="danpian-h1">张三</div><div class="v_news_content">
      <p>英文名：San Zhang</p><p>职称：教授</p><p>学院：航空学院</p><p>系别：工程系</p>
      <p>实验室：实验室甲</p><p>学术职务：主任</p><p>学术职务：委员</p>
      <p>研究方向：高超声速飞行器</p><p>邮箱：faculty@example.edu"""
    let record = NPU.parseFaculty(html, url)
    check record.nameEn.get() == "San Zhang"
    check record.title.get() == "教授"
    check record.school.get() == "航空学院"
    check record.department.get() == "工程系"
    check record.laboratory.get() == "实验室甲"
    check record.email.get() == "faculty@example.edu"
    check "主任" in record.rawFields["学术职务"] and "委员" in record.rawFields["学术职务"]
    check record.researchAreas == @["高超声速飞行器"]
    check parseJson($record.toJson())["rawHtml"].getStr() == html
    let english = NPU.parseFaculty("""<div class="danpian-h1">Jane Doe</div>""", url)
    check english.name == "Jane Doe"
    check english.nameZh.isNone
    expect ApiError: discard NPU.parseFaculty("<html><script>$_ts=window['$_ts'];</script></html>", url)

proc checks() {.async.} =
  var centralCalls = 0
  let transport: FacultyTransport = proc(target, payload: string): Future[FacultyHttpResponse] {.async, gcsafe.} =
    if "teacher.nwpu.edu.cn" in target:
      inc centralCalls
      return FacultyHttpResponse(status: 403)
    if "som.nwpu.edu.cn" in target: return FacultyHttpResponse(status: 200, body: management)
    if "/jsfc/" in target: return FacultyHttpResponse(status: 200, body: mathDirectory)
    return FacultyHttpResponse(status: 200, body: profile)
  let client = newFacultyClient(intervalMs = 0, transport = transport)
  let records = await NPU.enumerateFaculty(client, CrawlLimits(maxPages: 1, maxProfiles: 3), @[NpuDirectories[1]])
  check records.records.len == 3
  check records.records[0].title.get() == "教授"
  check not records.complete
  check records.issues.len > 0
  check centralCalls == 1 # No repeated attempts against an access restriction.
  let matches = await NPU.searchFaculty("信息管理", client, CrawlLimits(maxPages: 1, maxProfiles: 3), @[NpuDirectories[1]])
  check matches.records.len > 0
  check matches.records[0].name == "赵嵩正"

suite "NPU collection without live HTTP":
  test "directory data survives blocked profile retrieval; exact substring search": waitFor checks()

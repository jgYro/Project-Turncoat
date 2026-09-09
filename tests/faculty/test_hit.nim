import std/[unittest, options, tables, json, strutils, asyncdispatch]
import faculty/[types, http_client]
import faculty/institutions/HIT
import api_errors

const
  profile = staticRead("../fixtures/hit/profile.html")
  english = staticRead("../fixtures/hit/profile_en.html")
  directory = staticRead("../fixtures/hit/directory.json")
  body = staticRead("../fixtures/hit/body.json")
  url = "https://homepage.hit.edu.cn/zhc"

suite "HIT raw faculty parsing":
  test "Chinese fields, comma-separated research text, and source HTML survive":
    let record = HIT.parseFaculty(profile, url)
    check record.institution == "HIT"
    check record.name == "张昊春"
    check record.nameZh.get() == "张昊春"
    check record.title.get() == "教授"
    check record.unit.get() == "能源科学与工程学院"
    check record.school.isNone
    check record.researchAreas == @["新型光电对抗技术,先进核能系统,热学超材料"]
    check "动力工程及工程热物理,核科学与技术" in record.rawFields["学科"]
    check record.rawHtml == profile
    check record.profileUrl == url
    check record.email.isNone
    check "moc.anis.piv@hzch" in record.rawFields["邮箱"]

  test "English spelling and internal nonbreaking space are preserved":
    let record = HIT.parseFaculty(english, url & "?lang=en")
    check record.nameEn.get() == "Haochun                         Zhang"
    check record.nameZh.isNone
    check record.title.get() == "Professor"

  test "optional body sections preserve research text without publications":
    var record = HIT.parseFaculty(profile, url)
    record.parseBody(parseJson(body).getStr())
    check record.rawFields.hasKey("研究领域")
    check "工程热力学；传热传质学" in record.researchAreas[^1]
    check not record.rawFields.hasKey("论文")

  test "partial DOM, duplicate labels, plain email, and missing values":
    let html = """<div id="teacher_info"><h3 class="chineseName">张三</h3>
      <ul class="part4"><li><em>研究方向</em><span>高超声速飞行器</span></li>
      <li><em>实验室</em><span>实验室 A</span></li><li><em>实验室</em><span>实验室 B</span></li>
      <li><em>邮箱</em><span>faculty@example.edu</span></li><li><em>学科</em><span></span></li>"""
    let record = HIT.parseFaculty(html, url)
    check record.name == "张三"
    check record.title.isNone
    check record.laboratory.get() == "实验室 A"
    check "实验室 B" in record.rawFields["实验室"]
    check record.email.get() == "faculty@example.edu"
    check record.researchAreas == @["高超声速飞行器"]
    check record.rawFields.hasKey("学科")
    let encoded = record.toJson()
    check encoded["title"].kind == JNull
    check encoded["researchAreas"][0].getStr() == "高超声速飞行器"
    check parseJson($encoded)["rawHtml"].getStr() == html

  test "directory URLs, explicit English names, and unreliable counts":
    let data = HIT.parseDirectory(directory, HitDirectory)
    check data.profiles.len == 1
    check data.profiles[0].url == url
    check data.profiles[0].directoryRecord.nameEn.get() == "Zhang Haochun"
    check HIT.profileUrl("javascript:alert(1)") == ""
    check HIT.profileUrl("https://homepage.hit.edu.cn.evil.test/zhc") == ""
    expect ApiError: discard HIT.parseDirectory("{}", HitDirectory)
    expect ApiError: discard HIT.parseDirectory("\xFF", HitDirectory)
    check not HIT.parseDirectory("""{"code":200,"rows":[{"userName":"张三"}]}""", HitDirectory).complete
    expect ApiError: discard HIT.parseFaculty("<html>login</html>", url)

proc integration() {.async.} =
  var calls = 0
  let transport: FacultyTransport = proc(target, payload: string): Future[FacultyHttpResponse] {.async, gcsafe.} =
    inc calls
    if target == HitDirectory:
      check "userName=" in payload
      return FacultyHttpResponse(status: 200, body: directory)
    if target.endsWith("teacherBody.do"):
      check payload == "id=630"
      return FacultyHttpResponse(status: 200, body: body)
    check target == url
    return FacultyHttpResponse(status: 200, body: profile)
  let client = newFacultyClient(intervalMs = 0, transport = transport)
  let data = await HIT.enumerateFaculty(client)
  check data.complete
  check data.records.len == 1
  check calls == 3
  check data.records[0].rawFields.hasKey("研究领域")
  check data.records[0].nameEn.get() == "Zhang Haochun"
  check data.toJson()["records"][0]["sourceUrl"].getStr() == url
  let found = await HIT.searchFaculty("张昊春", client)
  check found.records.len == 1

suite "HIT discovery and retrieval without live HTTP":
  test "enumeration, retrieval, supplemental parsing, search, and JSON":
    waitFor integration()

import std/[unittest, options, tables, json, strutils, asyncdispatch]
import faculty/[types, http_client]
import faculty/institutions/NUAA
import api_errors

const
  profile = staticRead("../fixtures/nuaa/profile.html")
  modern = staticRead("../fixtures/nuaa/profile_modern.html")
  directory = staticRead("../fixtures/nuaa/directory.html")
  search = staticRead("../fixtures/nuaa/search.html")
  url = "https://faculty.nuaa.edu.cn/lcj1/zh_CN/index.htm"

suite "NUAA raw faculty parsing":
  test "classic template, bilingual metadata, source labels, and plaintext contact":
    let record = NUAA.parseFaculty(profile, url)
    check record.name == "刘长江"
    check record.nameZh.get() == "刘长江"
    check record.nameEn.get() == "Liu Changjiang"
    check record.title.get() == "教授"
    check record.unit.get() == "国际教育学院"
    check record.email.get() == "liucj@nuaa.edu.cn"
    check "校学术委员会委员" in record.rawFields["主要任职"]
    check record.researchAreas == @["外国语言学及应用语言学（二语习得，外语教学，跨文化交际）", "课程与教学论", "教育管理"]
    check record.rawFields.hasKey("电子邮箱")
    check record.warnings.len > 0
    check record.rawHtml == profile

  test "modern template uses its own position and unit markup":
    let record = NUAA.parseFaculty(modern, "https://faculty.nuaa.edu.cn/all/zh_CN/index.htm")
    check record.name == "安鲁陵"
    check record.title.get() == "教授"
    check record.unit.get() == "机电学院"
    check record.nameEn.isNone

  test "missing fields, English names, repeated labels, and malformed fragments":
    let fragment = """<meta name="keywords" content="Jane Example,"><div class="t_jbxx_nr">
      <p>所属院系：工程系</p><p>研究所：研究所 A</p><p>学科：甲</p><p>学科：乙</p>
      <p>邮箱：</p><p>电子邮箱：encrypted-text</p><h4>研究方向：</h4><p>高超声速飞行器"""
    let record = NUAA.parseFaculty(fragment, url)
    check record.name == "Jane Example"
    check record.nameEn.get() == "Jane Example"
    check record.nameZh.isNone
    check record.title.isNone
    check record.department.get() == "工程系"
    check record.laboratory.get() == "研究所 A"
    check record.email.isNone
    check "甲" in record.rawFields["学科"] and "乙" in record.rawFields["学科"]
    check record.researchAreas == @["高超声速飞行器"]
    check record.toJson()["email"].kind == JNull
    check parseJson($record.toJson())["rawHtml"].getStr() == fragment
    expect ApiError: discard NUAA.parseFaculty("<html>Login required</html>", url)

  test "alphabetic links and native search pagination stay on the institution":
    let page = NUAA.parseDirectory(directory, NUAA.directoryUrl('a'))
    check page.profiles.len == 8
    check page.profiles[0].url == "https://faculty.nuaa.edu.cn/all/zh_CN/index.htm"
    check "PAGENUM=2" in page.nextPages[0]
    let results = NUAA.parseDirectory(search, NUAA.searchUrl("人工智能"))
    check results.profiles.len == 9 # One homepage appears in two research hits.
    check results.profiles[0].url == "https://faculty.nuaa.edu.cn/liweiwei/zh_CN/index.htm"
    check "currentnum=2" in results.nextPages[0]
    check "kw=5Lq65bel5pm66IO9" in results.nextPages[0]
    check NUAA.profileUrl("https://evil.test/person/zh_CN/index.htm") == ""
    check NUAA.profileUrl("javascript:alert(1)") == ""

proc checks() {.async.} =
  let transport: FacultyTransport = proc(target, payload: string): Future[FacultyHttpResponse] {.async, gcsafe.} =
    if "result.jsp" in target: return FacultyHttpResponse(status: 200, body: search)
    if "pinyin_list" in target: return FacultyHttpResponse(status: 200, body: directory)
    return FacultyHttpResponse(status: 200, body: profile)
  let client = newFacultyClient(intervalMs = 0, transport = transport)
  let data = await NUAA.searchFaculty("人工智能", client, CrawlLimits(maxPages: 1, maxProfiles: 3))
  check data.records.len == 3
  check not data.complete
  check data.issues.len > 0
  let all = await NUAA.enumerateFaculty(client, CrawlLimits(maxPages: 1, maxProfiles: 2))
  check all.records.len == 2
  check not all.complete

suite "NUAA collection without live HTTP":
  test "search, enumeration, retrieval, and explicit limit reporting": waitFor checks()

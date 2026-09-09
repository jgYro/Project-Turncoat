## HIT's public teacher portal: structured header, JSON directory, optional body HTML.
import std/[asyncdispatch, json, options, strutils, uri]
from std/unicode import validateUtf8
import ../[types, dom, http_client, collection]
import ../../api_errors

const
  HitHosts* = ["homepage.hit.edu.cn"]
  HitOrigin* = "https://homepage.hit.edu.cn"
  HitDirectory* = HitOrigin & "/hompage/findTeachersByName.do"

proc profileUrl*(href: string; source = HitOrigin & "/"): string =
  result = safeUrl(href, source, HitHosts)
  if result.len == 0: return
  let path = parseUri(result).path.strip(chars = {'/'})
  let parts = path.split('/')
  if not ((parts.len == 1 and parts[0].len > 0 and
      parts[0].allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '-'})) or
      (parts.len == 2 and parts[0] == "pages" and parts[1].len > 0)) or
      path in ["home-index", "web-home", "search-teacher-by-phoneticize", "login", "logout", "admin"]:
    result = ""

proc capture(record: var FacultyRecord; label, raw: string) =
  record.addRaw(label, raw)
  let value = raw.strip()
  if value.len == 0: return
  case label
  of "职称", "Academic title", "Title":
    if record.title.isNone: record.title = some(value)
  of "目前就职", "Department":
    if record.unit.isNone: record.unit = some(value)
  of "学院", "School":
    if record.school.isNone: record.school = some(value)
  of "部门", "系", "所在系":
    if record.department.isNone: record.department = some(value)
  of "实验室", "研究所", "Laboratory":
    if record.laboratory.isNone: record.laboratory = some(value)
  of "研究方向", "研究领域", "Research", "Research Interests":
    record.researchAreas.add(value)
  of "邮箱", "Email", "E-mail":
    if plainEmail(value) and record.email.isNone: record.email = some(value)
  else: discard

proc parseBody*(record: var FacultyRecord; html: string) =
  let document = checkedHtml(html)
  for part in document.byClass("con_parts"):
    let label = part.firstClass("part_t_l").nodeText()
    if label notin ["研究领域", "研究方向", "实验室", "研究所", "研究团队", "团队组成",
        "主要任职", "学术兼职", "学科", "部门", "学院", "Research Interests", "Laboratory"]:
      continue
    for content in part.byClass("editor_content"):
      record.capture(label, content.sourceText())

proc parseFaculty*(html, sourceUrl: string): FacultyRecord =
  let document = checkedHtml(html)
  let zh = document.firstClass("chineseName")
  let en = document.firstClass("englishName")
  if zh == nil and en == nil and document.byId("teacher_info") == nil:
    raise apiError("Unrecognized HIT faculty profile markup.")
  result = newRecord("HIT", sourceUrl, html)
  result.nameZh = present(zh.nodeText())
  result.nameEn = present(en.nodeText())
  result.name = if result.nameZh.isSome: result.nameZh.get() else: en.nodeText()
  if zh != nil: result.addRaw("chineseName", zh.sourceText())
  if en != nil: result.addRaw("englishName", en.sourceText())
  let title = document.firstClass("user-post")
  if title != nil: result.capture("职称", title.sourceText())
  let honors = document.byId("teacher-honor")
  if honors != nil: result.capture("teacher-honor", honors.sourceText())
  for class in ["part4", "ul-cont"]:
    for section in document.byClass(class):
      for item in section.findAll("li"):
        let labelNode = item.firstTag("em")
        if labelNode == nil: continue
        let label = labelNode.nodeText()
        var value = ""
        for child in item:
          if child != labelNode and (child.kind != xnElement or child.tag != "a"):
            value.add(child.sourceText())
        if item.firstClass("EmailText") != nil:
          # This class is reversed by the site's JS. Keep its source unchanged.
          result.addRaw(label, value)
          result.warnings.add("HIT EmailText is source-obfuscated; email was not decoded.")
        else: result.capture(label, value)
  let summary = document.firstClass("user-describe")
  if summary != nil: result.addRaw("user-describe", summary.sourceText())
  result.parseBody(html)
  if result.name.len == 0: result.warnings.add("Profile template recognized, but no name was present.")

proc parseDirectory*(body, sourceUrl: string; limits = defaultCrawlLimits()): DiscoveryResult =
  limits.validate()
  if validateUtf8(body) != -1: raise apiError("HIT directory response is not valid UTF-8.")
  result = DiscoveryResult(complete: true, scope: "HIT public portal directory response")
  try:
    let data = parseJson(body)
    if data.kind != JObject or not data.hasKey("rows") or data["rows"].kind != JArray or
        not data.hasKey("code") or $data["code"] notin ["200", "\"200\""]:
      raise apiError("Unrecognized HIT directory response.")
    for row in data["rows"]:
      if row.kind != JObject or not row.hasKey("url") or row["url"].kind != JString:
        result.addIssue("HIT", sourceUrl, "HIT directory row has no profile URL.")
        continue
      let url = profileUrl(row["url"].getStr(), HitOrigin & "/")
      if url.len == 0:
        result.addIssue("HIT", sourceUrl, "HIT directory row has an unsupported profile URL.")
        continue
      var record = newRecord("HIT", sourceUrl, "")
      record.profileUrl = url
      for key, value in row:
        if value.kind == JString: record.addRaw(key, value.getStr())
        else: record.addRaw(key, $value)
      record.additionalSources.add(SourceDocument(url: sourceUrl, body: body))
      if row.hasKey("userName"):
        record.name = row["userName"].getStr()
        record.nameZh = present(record.name)
      if row.hasKey("englishName"): record.nameEn = present(row["englishName"].getStr())
      if row.hasKey("department"): record.unit = present(row["department"].getStr())
      if not result.addProfile(ProfileReference(url: url, directoryRecord: record), limits): break
  except ApiError: raise
  except CatchableError: raise apiError("Could not parse HIT directory JSON.")

proc discoverProfiles*(query = ""; client: FacultyClient = nil;
    limits = defaultCrawlLimits()): Future[DiscoveryResult] {.async.} =
  limits.validate()
  if query.len > 1000: raise newException(ValueError, "Faculty query must be at most 1,000 bytes.")
  let body = encodeQuery([("userName", query), ("userChina", ""), ("deptId", ""),
    ("userTitle", ""), ("orderByCause", "u.modify_time desc")], omitEq = false)
  let response = await facultyClient(client).fetchProfileHtml(HitDirectory, HitHosts, body)
  return parseDirectory(response, HitDirectory & "?" & body, limits)

proc fetchFaculty*(url: string; client: FacultyClient = nil): Future[FacultyRecord] {.async.} =
  let url = profileUrl(url)
  if url.len == 0: raise newException(ValueError, "Expected a public HIT faculty profile URL.")
  let client = facultyClient(client)
  let html = await client.fetchProfileHtml(url, HitHosts)
  result = parseFaculty(html, url)
  let bodyNode = checkedHtml(html).firstClass("teacher-body")
  if bodyNode == nil: return
  let id = bodyNode.htmlAttr("data-tid")
  if id.len == 0 or not id.allCharsInSet({'0'..'9', 'a'..'z', 'A'..'Z'}): return
  let endpoint = HitOrigin & "/TeacherHome/teacherBody.do"
  let payload = encodeQuery([("id", id)])
  try:
    let raw = await client.fetchProfileHtml(endpoint, HitHosts, payload)
    result.additionalSources.add(SourceDocument(url: endpoint & "?" & payload, body: raw))
    let data = parseJson(raw)
    if data.kind != JString: raise apiError("Unexpected HIT profile body response.")
    result.parseBody(data.getStr())
  except CatchableError as error:
    result.warnings.add("Supplementary HIT profile body unavailable: " & error.msg)

proc searchFaculty*(query: string; client: FacultyClient = nil;
    limits = defaultCrawlLimits()): Future[FacultyResult] {.async.} =
  let client = facultyClient(client)
  let discovery = await discoverProfiles(query, client, limits)
  return await collect(discovery, client, fetchFaculty)

proc enumerateFaculty*(client: FacultyClient = nil;
    limits = defaultCrawlLimits()): Future[FacultyResult] =
  searchFaculty("", client, limits)

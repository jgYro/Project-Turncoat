## NPU school-directory adapters. The central teacher portal may require a challenge.
import std/[asyncdispatch, options, strutils, uri]
from std/unicode import runes
import ../[types, dom, http_client, collection]
import ../../api_errors

const
  NpuHosts* = ["math.nwpu.edu.cn", "som.nwpu.edu.cn", "teacher.nwpu.edu.cn"]
  NpuDirectories* = [
    "https://math.nwpu.edu.cn/jsfc/jsfc.htm",
    "https://som.nwpu.edu.cn/guanlixy/szdw/jsml1/zc/js.htm",
    "https://som.nwpu.edu.cn/guanlixy/szdw/jsml1/zc/fjs.htm",
    "https://som.nwpu.edu.cn/guanlixy/szdw/jsml1/zc/js1.htm"]
  NpuScope* = "NPU Mathematics & Statistics faculty features and Management title directories; not university-wide"

proc chineseName(value: string): Option[string] =
  for rune in value.runes:
    if int(rune) in 0x3400..0x9FFF: return some(value)

proc profileUrl*(href, source: string): string =
  result = safeUrl(href, source, NpuHosts)
  if result.len == 0: return
  var url = parseUri(result)
  url.scheme = "https"
  let path = url.path
  if url.hostname == "math.nwpu.edu.cn":
    if not path.startsWith("/info/1502/") or not path.endsWith(".htm"):
      return ""
  elif url.hostname == "teacher.nwpu.edu.cn":
    let slug = path.strip(chars = {'/'})
    if not slug.endsWith(".html") or not slug.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-'}):
      return ""
  else: return ""
  url.query = ""
  result = $url

proc capture(record: var FacultyRecord; label, raw: string) =
  record.addRaw(label, raw)
  let value = raw.strip()
  if value.len == 0: return
  case label
  of "姓名", "Name":
    if record.name.len == 0: record.name = value
  of "中文名": record.nameZh = some(value)
  of "英文名", "English name": record.nameEn = some(value)
  of "职称", "专业技术职务", "Professional title":
    if record.title.isNone: record.title = some(value)
  of "学院", "School": record.school = some(value)
  of "系别", "部门", "Department": record.department = some(value)
  of "所在单位", "Unit": record.unit = some(value)
  of "实验室", "研究所", "Laboratory": record.laboratory = some(value)
  of "邮箱", "电子邮箱", "Email", "E-mail":
    if plainEmail(value) and record.email.isNone: record.email = some(value)
  of "研究方向", "研究领域", "Research interests", "Research field":
    record.researchAreas.add(value)
  else: discard

proc parseFaculty*(html, sourceUrl: string): FacultyRecord =
  let document = checkedHtml(html)
  let name = document.firstClass("danpian-h1")
  let content = document.firstClass("v_news_content")
  if name == nil and content == nil: raise apiError("Unrecognized NPU school faculty profile template.")
  result = newRecord("NPU", sourceUrl, html)
  result.name = name.nodeText()
  result.addRaw("profile heading", name.sourceText())
  # Only classify explicitly displayed text; never generate a name variant.
  result.nameZh = chineseName(result.name)
  if content != nil:
    result.addRaw("个人简介", content.sourceText())
    for paragraph in content.findAll("p"):
      let raw = paragraph.sourceText()
      let pair = labelValue(raw)
      if pair.label in ["姓名", "中文名", "英文名", "职称", "专业技术职务", "学院", "系别", "部门",
          "所在单位", "实验室", "研究所", "邮箱", "电子邮箱", "研究方向", "研究领域", "学术职务",
          "个人教师主页", "学科", "学术职位", "职务", "研究团队", "科研团队",
          "Name", "English name", "Professional title", "School", "Department",
          "Unit", "Laboratory", "Email", "E-mail", "Research interests", "Research field"]:
        result.capture(pair.label, pair.value)
      elif "研究方向" in raw or "研究领域" in raw or "研究兴趣" in raw:
        # Preserve the complete source paragraph, including surrounding context.
        # Do not turn free-form biographies into inferred job titles or topics.
        result.researchAreas.add(paragraph.nodeText())
        result.addRaw("research paragraph", raw)
  if result.name.len == 0: result.warnings.add("NPU profile had no explicit name.")

proc parseDirectory*(html, sourceUrl: string; limits = defaultCrawlLimits()): DiscoveryResult =
  limits.validate()
  let document = checkedHtml(html)
  result = DiscoveryResult(complete: true, scope: NpuScope)
  let host = parseUri(sourceUrl).hostname
  if host == "som.nwpu.edu.cn":
    let table = document.firstClass("m-table-lb").firstTag("table")
    if table == nil: raise apiError("Unrecognized NPU Management faculty directory.")
    var labels: seq[string]
    for th in table.findAll("th"): labels.add(th.nodeText())
    if labels != @["姓名", "职称", "系别", "研究方向", "个人主页"]:
      raise apiError("NPU Management directory columns changed.")
    for row in table.findAll("tr"):
      let cells = row.findAll("td")
      if cells.len == 0: continue
      if cells.len != labels.len: raise apiError("Incomplete NPU Management faculty row.")
      let url = profileUrl(cells[^1].firstTag("a").htmlAttr("href"), sourceUrl)
      if url.len == 0: continue
      var record = newRecord("NPU", sourceUrl, html)
      record.profileUrl = url
      for index, cell in cells:
        if index < cells.len - 1: record.capture(labels[index], cell.sourceText())
      record.nameZh = chineseName(record.name)
      record.addRaw("个人主页", cells[^1].firstTag("a").htmlAttr("href"))
      if not result.addProfile(ProfileReference(url: url, directoryRecord: record), limits): break
  elif host == "math.nwpu.edu.cn":
    let content = document.firstClass("erji-content-div")
    if content == nil: raise apiError("Unrecognized NPU Mathematics faculty directory.")
    for item in content.byClass("pic-item"):
      let url = profileUrl(item.firstTag("a").htmlAttr("href"), sourceUrl)
      if url.len == 0: continue
      var record = newRecord("NPU", sourceUrl, html)
      record.profileUrl = url
      record.name = item.firstTag("h1").nodeText()
      record.nameZh = chineseName(record.name)
      if not result.addProfile(ProfileReference(url: url, directoryRecord: record), limits): break
  else: raise newException(ValueError, "Unsupported NPU school directory host.")
  let next = nextLink(document, sourceUrl, NpuHosts)
  if next.len > 0 and parseUri(next).hostname == host: result.nextPages.add(next)

proc discoverProfiles*(client: FacultyClient = nil; limits = defaultCrawlLimits();
    seeds: seq[string] = @NpuDirectories): Future[DiscoveryResult] {.async.} =
  limits.validate()
  let client = facultyClient(client)
  result = DiscoveryResult(complete: true, scope: NpuScope)
  var pending = seeds
  var visited: seq[string]
  while pending.len > 0:
    if visited.len >= limits.maxPages or result.profiles.len >= limits.maxProfiles:
      result.addIssue("NPU", pending[0], "Crawl limit reached; more school directory pages remain.", 206)
      break
    let url = pending[0]
    pending.delete(0)
    if url in visited: continue
    visited.add(url)
    let parsed = parseUri(url)
    if not ((parsed.hostname == "math.nwpu.edu.cn" and parsed.path.startsWith("/jsfc/")) or
        (parsed.hostname == "som.nwpu.edu.cn" and parsed.path.startsWith("/guanlixy/szdw/jsml1/zc/"))):
      result.addIssue("NPU", url, "Only supported public NPU school directory paths are accepted.", 400)
      continue
    try:
      let page = parseDirectory(await client.fetchProfileHtml(url, NpuHosts), url, limits)
      for profile in page.profiles: discard result.addProfile(profile, limits)
      result.issues.add(page.issues)
      result.complete = result.complete and page.complete
      for next in page.nextPages:
        if next notin visited and next notin pending: pending.add(next)
    except CatchableError as error:
      result.addIssue("NPU", url, error.msg, if error of ApiError: (ref ApiError)(error).status else: 502)

proc fetchFaculty*(url: string; client: FacultyClient = nil): Future[FacultyRecord] {.async.} =
  let url = profileUrl(url, "https://math.nwpu.edu.cn/")
  if url.len == 0: raise newException(ValueError, "Expected a supported public NPU faculty profile URL.")
  return parseFaculty(await facultyClient(client).fetchProfileHtml(url, NpuHosts), url)

proc enumerateFaculty*(client: FacultyClient = nil; limits = defaultCrawlLimits();
    seeds: seq[string] = @NpuDirectories): Future[FacultyResult] {.async.} =
  let client = facultyClient(client)
  return await collect(await discoverProfiles(client, limits, seeds), client, fetchFaculty)

proc searchFaculty*(query: string; client: FacultyClient = nil;
    limits = defaultCrawlLimits(); seeds: seq[string] = @NpuDirectories): Future[FacultyResult] {.async.} =
  if query.len > 1000: raise newException(ValueError, "Faculty query must be at most 1,000 bytes.")
  result = await enumerateFaculty(client, limits, seeds)
  var matches: seq[FacultyRecord]
  for record in result.records:
    if record.containsQuery(query): matches.add(record)
  result.records = matches
  result.scope.add("; exact source-text substring search")

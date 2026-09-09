## NUAA Tsites templates, native text search, and alphabetic directory pagination.
import std/[asyncdispatch, options, strutils, uri, base64]
from std/unicode import runes
import ../[types, dom, http_client, collection]
import ../../api_errors

const
  NuaaHosts* = ["faculty.nuaa.edu.cn"]
  NuaaOrigin* = "https://faculty.nuaa.edu.cn"

proc hasChinese(value: string): bool =
  for rune in value.runes:
    if int(rune) in 0x3400..0x9FFF: return true

proc profileUrl*(href: string; source = NuaaOrigin & "/"): string =
  let resolved = safeUrl(href, source, NuaaHosts)
  if resolved.len == 0: return
  var url = parseUri(resolved)
  let parts = url.path.strip(chars = {'/'}).split('/')
  if parts.len < 3 or parts[1] notin ["zh_CN", "en"] or parts[0].len == 0 or
      not parts[0].allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.'}): return
  # Search hits may be profile subpages; their first two segments identify the
  # containing public homepage. No person-name comparisons are involved.
  url.scheme = "https"
  url.path = "/" & parts[0] & "/" & parts[1] & "/index.htm"
  url.query = ""
  result = $url

proc capture(record: var FacultyRecord; label, raw: string) =
  record.addRaw(label, raw)
  let value = raw.strip()
  if value.len == 0: return
  case label
  of "姓名", "Name":
    if record.name.len == 0: record.name = value
  of "英文名", "English name": record.nameEn = some(value)
  of "职称", "Professional Title", "Title":
    if record.title.isNone: record.title = some(value)
  of "所在单位", "单位", "Unit":
    if record.unit.isNone: record.unit = some(value)
  of "学院", "School": record.school = some(value)
  of "所属院系", "系", "部门", "Department": record.department = some(value)
  of "研究所", "实验室", "Laboratory": record.laboratory = some(value)
  of "电子邮箱", "邮箱", "联系方式", "Email", "E-mail":
    if plainEmail(value) and record.email.isNone: record.email = some(value)
  else: discard
  if label in ["研究方向", "研究领域", "Research Focus", "Research Interests"] or
      label.startsWith("学科研究方向"):
    record.researchAreas.add(value)

proc researchSections(record: var FacultyRecord; node: XmlNode) =
  if node.kind != xnElement or node.tag in ["script", "style"]: return
  var inResearch = false
  for child in node:
    if child.kind != xnElement: continue
    if child.tag in ["h1", "h2", "h3", "h4", "h5", "h6"]:
      let heading = child.nodeText().strip(chars = {' ', ':', '\n', '\r'})
      inResearch = heading in ["研究方向", "研究方向：", "研究领域", "研究领域：", "Research Interests", "Research Focus"]
    elif inResearch and child.tag in ["p", "li"]:
      let pair = labelValue(child.sourceText())
      if pair.label.startsWith("学科研究方向"): record.capture(pair.label, pair.value)
      elif child.nodeText().len > 0: record.capture("研究方向", child.sourceText())
    record.researchSections(child)
  if node.hasClass("slideTxtBox2"):
    let heading = node.firstClass("hd").firstTag("li").nodeText()
    if heading.startsWith("研究方向"):
      let list = node.firstClass("bd").firstTag("ul")
      if list != nil:
        for item in list.findAll("li"):
          if item.nodeText().len > 0: record.capture("研究方向", item.sourceText())

proc parseFaculty*(html, sourceUrl: string): FacultyRecord =
  let document = checkedHtml(html)
  let classic = document.firstClass("t_jbxx_nr")
  let modern = document.firstClass("PersonalIntroduction")
  if classic == nil and modern == nil and document.firstClass("t_photo") == nil:
    raise apiError("Unrecognized NUAA faculty profile template.")
  result = newRecord("NUAA", sourceUrl, html)
  let keywords = document.metadata("keywords")
  let names = keywords.split(',')
  if keywords.len > 0:
    result.addRaw("meta/keywords", keywords)
    result.name = names[0].strip()
    if hasChinese(result.name): result.nameZh = present(result.name)
    elif result.name.len > 0: result.nameEn = present(result.name)
    if names.len == 2 and names[1].strip().len > 0 and not hasChinese(names[1]):
      result.nameEn = present(names[1].strip())
  if result.name.len == 0:
    let photoName = document.firstClass("t_photo").firstTag("span").nodeText()
    result.name = photoName
    if hasChinese(photoName): result.nameZh = present(photoName)
    else: result.nameEn = present(photoName)
  for section in [classic, document.firstClass("PersonalIntroductionMore")]:
    if section == nil: continue
    for tag in ["p", "li"]:
      for item in section.findAll(tag):
        let raw = item.sourceText()
        let pair = labelValue(raw)
        if pair.label.len > 0:
          result.capture(pair.label, pair.value)
          if pair.label == "电子邮箱" and not plainEmail(pair.value):
            result.warnings.add("NUAA email field is not plaintext; it was preserved without decoding.")
        elif item.nodeText().len > 0:
          result.addRaw("unlabelled/position", raw)
          let words = item.nodeText().splitWhitespace()
          if words.len > 0 and result.title.isNone and words[0] in ["教授", "副教授", "讲师", "研究员", "副研究员", "助理研究员", "Professor"]:
            result.title = some(words[0])
  if modern != nil:
    let personal = modern.firstClass("PersonalContent")
    if personal != nil:
      if result.name.len == 0:
        result.name = personal.firstTag("strong").nodeText()
        if hasChinese(result.name): result.nameZh = present(result.name)
        else: result.nameEn = present(result.name)
      for item in personal.findAll("li"):
        if item.firstTag("strong") == nil: continue
        var position = ""
        for child in item:
          if child.kind != xnElement or child.tag notin ["strong", "span", "p"]:
            position.add(child.sourceText())
        result.addRaw("unlabelled/position", position)
        for line in position.splitLines():
          if line.strip() in ["教授", "副教授", "讲师", "研究员", "副研究员", "助理研究员", "Professor"]:
            result.capture("职称", line)
      for span in personal.findAll("span"):
        let value = span.nodeText()
        if value in ["教授", "副教授", "讲师", "研究员", "副研究员", "助理研究员", "Professor"]:
          result.capture("职称", span.sourceText())
  result.researchSections(document)
  if result.name.len == 0: result.warnings.add("NUAA profile had no explicit name.")

proc directoryUrl*(letter: char): string =
  NuaaOrigin & "/pinyin_list.jsp?" & encodeQuery([("urltype", "tsites.PinYinTeacherList"),
    ("wbtreeid", "1001"), ("py", $letter), ("lang", "zh_CN")])

proc searchUrl*(query: string; page = 1): string =
  NuaaOrigin & "/result.jsp?" & encodeQuery([("wbtreeid", "1001"), ("searchType", "All"),
    ("currentnum", $page), ("kw", base64.encode(query)),
    ("tsites_search_content", base64.encode(query)), ("_tsites_search_current_language_", "zh_CN")])

proc parseDirectory*(html, sourceUrl: string; limits = defaultCrawlLimits()): DiscoveryResult =
  limits.validate()
  let document = checkedHtml(html)
  result = DiscoveryResult(complete: true, scope: "NUAA public Tsites directory/search")
  var sections = document.byClass("rwjj")
  sections.add(document.byClass("result"))
  if sections.len == 0: raise apiError("Unrecognized NUAA directory/search markup.")
  for section in sections:
    for item in section.findAll("li"):
      for link in item.findAll("a"):
        let url = profileUrl(link.htmlAttr("href"), sourceUrl)
        if url.len == 0: continue
        var record = newRecord("NUAA", sourceUrl, html)
        record.profileUrl = url
        let text = item.firstClass("text")
        if text != nil:
          record.name = text.firstTag("h2").firstTag("span").nodeText()
          if hasChinese(record.name): record.nameZh = present(record.name)
          else: record.nameEn = present(record.name)
          for p in text.findAll("p"):
            let pair = labelValue(p.sourceText())
            if pair.label.len > 0: record.capture(pair.label, pair.value)
        if not result.addProfile(ProfileReference(url: url, directoryRecord: record), limits): break
  let next = nextLink(document, sourceUrl, NuaaHosts)
  if next.len > 0:
    result.nextPages.add(next)
  elif parseUri(sourceUrl).path.endsWith("result.jsp"):
    var current = 1
    var query = ""
    for key, value in decodeQuery(parseUri(sourceUrl).query):
      if key == "currentnum": current = parseInt(value)
      if key in ["kw", "tsites_search_content"]: query = base64.decode(value)
    for pagination in document.byClass("pagination"):
      for span in pagination.findAll("span"):
        let text = span.nodeText()
        if text.startsWith("共") and text.endsWith("页"):
          try:
            let total = parseInt(text["共".len..<text.len - "页".len])
            if current < total: result.nextPages.add(searchUrl(query, current + 1))
          except ValueError: raise apiError("NUAA pagination format changed.")

proc discoverProfiles*(query = ""; client: FacultyClient = nil;
    limits = defaultCrawlLimits()): Future[DiscoveryResult] {.async.} =
  limits.validate()
  if query.len > 1000: raise newException(ValueError, "Faculty query must be at most 1,000 bytes.")
  let client = facultyClient(client)
  result = DiscoveryResult(complete: true, scope: "NUAA public Tsites directory/search")
  var pending: seq[string]
  if query.len > 0: pending.add(searchUrl(query))
  else:
    for letter in 'a'..'z': pending.add(directoryUrl(letter))
  var visited: seq[string]
  while pending.len > 0:
    if visited.len >= limits.maxPages or result.profiles.len >= limits.maxProfiles:
      result.addIssue("NUAA", pending[0], "Crawl limit reached; more directory pages remain.", 206)
      break
    let url = pending[0]
    pending.delete(0)
    if url in visited: continue
    visited.add(url)
    try:
      let page = parseDirectory(await client.fetchProfileHtml(url, NuaaHosts), url, limits)
      for profile in page.profiles: discard result.addProfile(profile, limits)
      for next in page.nextPages:
        if next notin visited and next notin pending: pending.add(next)
      result.issues.add(page.issues)
      result.complete = result.complete and page.complete
    except CatchableError as error:
      let status = if error of ApiError: (ref ApiError)(error).status else: 502
      result.addIssue("NUAA", url, error.msg, status)
      if status == 503: break

proc fetchFaculty*(url: string; client: FacultyClient = nil): Future[FacultyRecord] {.async.} =
  let url = profileUrl(url)
  if url.len == 0: raise newException(ValueError, "Expected a public NUAA faculty profile URL.")
  return parseFaculty(await facultyClient(client).fetchProfileHtml(url, NuaaHosts), url)

proc searchFaculty*(query: string; client: FacultyClient = nil;
    limits = defaultCrawlLimits()): Future[FacultyResult] {.async.} =
  let client = facultyClient(client)
  return await collect(await discoverProfiles(query, client, limits), client, fetchFaculty)

proc enumerateFaculty*(client: FacultyClient = nil;
    limits = defaultCrawlLimits()): Future[FacultyResult] =
  searchFaculty("", client, limits)

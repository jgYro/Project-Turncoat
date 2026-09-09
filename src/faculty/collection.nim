## Collection bookkeeping shared by institutions; contains no website selectors.
import std/[asyncdispatch, options, strutils]
import types, http_client
import ../api_errors

type FacultyFetcher* = proc(url: string; client: FacultyClient): Future[FacultyRecord] {.closure.}

proc addProfile*(data: var DiscoveryResult; reference: ProfileReference; limits: CrawlLimits): bool =
  for existing in data.profiles.mitems:
    if existing.url == reference.url:
      # Image and text anchors can point to the same profile. Keep the name
      # from the text anchor if the image appeared first.
      if existing.directoryRecord.name.len == 0 and reference.directoryRecord.name.len > 0:
        existing.directoryRecord = reference.directoryRecord
      return true
  if data.profiles.len >= limits.maxProfiles:
    if data.complete: data.addIssue(reference.directoryRecord.institution, reference.url,
      "Profile limit reached; discovery is incomplete.", 206)
    return false
  data.profiles.add(reference)
  true

proc collect*(discovery: DiscoveryResult; client: FacultyClient;
    fetch: FacultyFetcher): Future[FacultyResult] {.async.} =
  result = FacultyResult(issues: discovery.issues, complete: discovery.complete, scope: discovery.scope)
  for reference in discovery.profiles:
    try:
      var record = await fetch(reference.url, client)
      let seed = reference.directoryRecord
      if seed.sourceUrl.len > 0:
        # This is metadata on an explicit directory link, not researcher matching.
        if record.nameEn.isNone: record.nameEn = seed.nameEn
        if record.nameZh.isNone: record.nameZh = seed.nameZh
        if record.name.len == 0: record.name = seed.name
        for entry in seed.rawFieldEntries: record.addRaw("directory/" & entry.label, entry.value)
        if seed.rawHtml.len > 0: record.additionalSources.add(SourceDocument(url: seed.sourceUrl, body: seed.rawHtml))
        record.additionalSources.add(seed.additionalSources)
      result.records.add(record)
    except CatchableError as error:
      let status = if error of ApiError: (ref ApiError)(error).status else: 502
      result.issues.add(FacultyIssue(institution: reference.directoryRecord.institution,
        sourceUrl: reference.url, message: error.msg, status: status))
      result.complete = false
      # A directory row is still valid raw data when a linked profile is unavailable.
      if reference.directoryRecord.name.len > 0:
        var record = reference.directoryRecord
        record.warnings.add("Linked profile could not be retrieved: " & error.msg)
        result.records.add(record)

proc containsQuery*(record: FacultyRecord; query: string): bool =
  ## Exact substring only; no transliteration, case folding, stemming or semantics.
  if query.len == 0: return true
  if query in record.name: return true
  for value in [record.nameZh, record.nameEn, record.title, record.unit, record.school,
      record.department, record.laboratory]:
    if value.isSome and query in value.get(): return true
  for area in record.researchAreas:
    if query in area: return true
  for field in record.rawFieldEntries:
    if query in field.value: return true

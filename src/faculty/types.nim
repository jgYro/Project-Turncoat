## Raw institutional records. Text is neither translated nor normalized.
import std/[options, tables, json]

type
  Institution* = enum
    hit, nuaa, npu
  RawField* = object
    label*, value*: string
  SourceDocument* = object
    url*, body*: string
  FacultyRecord* = object
    institution*, sourceUrl*, profileUrl*, name*: string
    nameZh*, nameEn*, title*, unit*, school*, department*, laboratory*, email*: Option[string]
    researchAreas*: seq[string]
    rawFields*: Table[string, string]
    rawFieldEntries*: seq[RawField]
    rawHtml*: string
    additionalSources*: seq[SourceDocument]
    warnings*: seq[string]
  FacultyIssue* = object
    institution*, sourceUrl*, message*: string
    status*: int
  FacultyResult* = object
    records*: seq[FacultyRecord]
    issues*: seq[FacultyIssue]
    complete*: bool
    scope*: string
  ProfileReference* = object
    url*: string
    directoryRecord*: FacultyRecord
  DiscoveryResult* = object
    profiles*: seq[ProfileReference]
    nextPages*: seq[string]
    issues*: seq[FacultyIssue]
    complete*: bool
    scope*: string
  CrawlLimits* = object
    maxPages*, maxProfiles*: int

proc institutionCode*(institution: Institution): string =
  case institution
  of hit: "HIT"
  of nuaa: "NUAA"
  of npu: "NPU"

proc defaultCrawlLimits*(): CrawlLimits = CrawlLimits(maxPages: 30, maxProfiles: 100)

proc validate*(limits: CrawlLimits) =
  if limits.maxPages < 1 or limits.maxProfiles < 1:
    raise newException(ValueError, "Faculty crawl limits must be positive.")

proc newRecord*(institution, sourceUrl, html: string): FacultyRecord =
  FacultyRecord(institution: institution, sourceUrl: sourceUrl, profileUrl: sourceUrl,
    rawHtml: html, rawFields: initTable[string, string]())

proc addRaw*(record: var FacultyRecord; label, value: string) =
  ## Retain even repeated and empty labels/values in ordered entries.
  record.rawFieldEntries.add(RawField(label: label, value: value))
  if record.rawFields.hasKey(label): record.rawFields[label].add("\n" & value)
  else: record.rawFields[label] = value

proc present*(value: string): Option[string] =
  if value.len == 0: none(string) else: some(value)

proc toJson*(record: FacultyRecord): JsonNode =
  result = %*{"institution": record.institution, "sourceUrl": record.sourceUrl,
    "profileUrl": record.profileUrl, "name": record.name,
    "researchAreas": record.researchAreas, "rawFields": record.rawFields,
    "rawFieldEntries": record.rawFieldEntries, "rawHtml": record.rawHtml,
    "additionalSources": record.additionalSources, "warnings": record.warnings}
  for (key, value) in [("nameZh", record.nameZh), ("nameEn", record.nameEn),
      ("title", record.title), ("unit", record.unit), ("school", record.school), ("department", record.department),
      ("laboratory", record.laboratory), ("email", record.email)]:
    result[key] = if value.isSome: %value.get() else: newJNull()

proc toJson*(data: FacultyResult): JsonNode =
  var records = newJArray()
  for record in data.records: records.add(record.toJson())
  %*{"records": records, "issues": data.issues, "complete": data.complete, "scope": data.scope}

proc addIssue*(data: var DiscoveryResult; institution, url, message: string; status = 502) =
  data.complete = false
  data.issues.add(FacultyIssue(institution: institution, sourceUrl: url, message: message, status: status))

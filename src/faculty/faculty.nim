## Deliberately small dispatcher. Add an enum member and module for BUAA later.
import std/[asyncdispatch, strutils]
import types, http_client
import institutions/HIT as hitParser
import institutions/NUAA as nuaaParser
import institutions/NPU as npuParser
import ../api_errors
export types, http_client

proc parseFaculty*(institution: Institution; html, sourceUrl: string): FacultyRecord =
  case institution
  of hit: hitParser.parseFaculty(html, sourceUrl)
  of nuaa: nuaaParser.parseFaculty(html, sourceUrl)
  of npu: npuParser.parseFaculty(html, sourceUrl)

proc fetchFaculty*(institution: Institution; url: string;
    client: FacultyClient = nil): Future[FacultyRecord] =
  case institution
  of hit: hitParser.fetchFaculty(url, client)
  of nuaa: nuaaParser.fetchFaculty(url, client)
  of npu: npuParser.fetchFaculty(url, client)

proc searchFaculty*(institution: Institution; query: string; client: FacultyClient = nil;
    limits = defaultCrawlLimits()): Future[FacultyResult] =
  case institution
  of hit: hitParser.searchFaculty(query, client, limits)
  of nuaa: nuaaParser.searchFaculty(query, client, limits)
  of npu: npuParser.searchFaculty(query, client, limits)

proc enumerateFaculty*(institution: Institution; client: FacultyClient = nil;
    limits = defaultCrawlLimits()): Future[FacultyResult] =
  case institution
  of hit: hitParser.enumerateFaculty(client, limits)
  of nuaa: nuaaParser.enumerateFaculty(client, limits)
  of npu: npuParser.enumerateFaculty(client, limits)

proc searchAllFaculty*(query: string; client: FacultyClient = nil;
    limits = defaultCrawlLimits()): Future[FacultyResult] {.async.} =
  limits.validate()
  if query.len > 1000: raise newException(ValueError, "Faculty query must be at most 1,000 bytes.")
  let client = facultyClient(client)
  var requests: seq[Future[FacultyResult]]
  # Creating all futures before awaiting starts independent institutions together.
  for institution in Institution: requests.add(searchFaculty(institution, query, client, limits))
  result.complete = true
  var scopes: seq[string]
  for institution in Institution:
    try:
      let data = await requests[ord(institution)]
      result.records.add(data.records)
      result.issues.add(data.issues)
      result.complete = result.complete and data.complete
      scopes.add(data.scope)
    except CatchableError as error:
      result.complete = false
      result.issues.add(FacultyIssue(institution: institution.institutionCode(),
        message: error.msg, status: if error of ApiError: (ref ApiError)(error).status else: 502))
  result.scope = scopes.join("; ")

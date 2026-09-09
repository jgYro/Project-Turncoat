# Raw faculty collection in Nim

This library collects public institutional metadata into JSON. It is independent of the HappyX paper/patent routes and performs no identity resolution, name matching, scoring, translation, topic normalization, publication/patent extraction, or cross-provider enrichment.

## Repository fit and files

The existing project uses Nim 2.2, HappyX, `std/AsyncHttpClient`, `Future[T]`/`asyncdispatch`, explicit JSON construction, the shared `ApiError` type, and standalone `unittest` programs. The faculty library follows those patterns. The existing provider clients have provider-specific caches and request validation, so faculty has a small transport using the same HTTP implementation and queue conventions. HTML parsing uses the maintained `pkg/htmlparser` 0.1.0 package. There was no application CLI to extend when faculty collection was implemented.

New implementation files:

| File | Responsibility |
| --- | --- |
| `src/faculty/types.nim` | Permissive records, provenance, issues, crawl limits, explicit JSON serialization |
| `src/faculty/dom.nim` | DOM traversal, source text, labels, UTF-8 validation and URL helpers |
| `src/faculty/http_client.nim` | Async retrieval, per-host pacing, concurrency, timeout, retries and access restrictions |
| `src/faculty/collection.nim` | Collection bookkeeping, exact URL deduplication, directory fallback |
| `src/faculty/institutions/HIT.nim` | HIT directory JSON, profile header and supplementary body |
| `src/faculty/institutions/NUAA.nim` | NUAA search, alphabetical directories and two profile templates |
| `src/faculty/institutions/NPU.nim` | NPU Mathematics and Management directories and Mathematics profiles |
| `src/faculty/faculty.nim` | Small enum-based dispatcher and concurrent search across institutions |
| `examples/faculty_search.nim` | Bounded JSON library example |

Tests are in `tests/faculty/test_{hit,nuaa,npu,faculty,http_client}.nim`. `test_live.nim` is a separate opt-in live smoke test. The eleven public-source fixtures and their provenance are documented in [SOURCES.md](../tests/fixtures/SOURCES.md). The faculty library itself adds no provider routes or views. The later [Institutions UI](../README.md#institution-search-presets) uses saved Google Patents/arXiv search strings and never invokes faculty collection.

## API

```nim
import std/[asyncdispatch, json]
import faculty/faculty

let client = newFacultyClient(
  userAgent = "MyResearchTool/1.0 (contact: research@example.org)")
let limits = CrawlLimits(maxPages: 2, maxProfiles: 5)
let found = waitFor searchFaculty(hit, "张昊春", client, limits)
echo found.toJson().pretty()

# Also available:
# waitFor enumerateFaculty(nuaa, client, limits)
# waitFor searchAllFaculty("人工智能", client, limits)
# waitFor fetchFaculty(hit, "https://homepage.hit.edu.cn/zhc", client)
# parseFaculty(hit, readFile("saved.html"), "https://homepage.hit.edu.cn/zhc")
```

Compile callers with `--path:src` from the repository root. Each institution also exposes `parseFaculty`, `fetchFaculty`, `searchFaculty`, `enumerateFaculty`, `discoverProfiles`, `parseDirectory`, and `profileUrl`. `fetchProfileHtml` belongs to the shared HTTP client; institution functions supply their allowed hosts. `HIT.parseBody` parses the optional body independently. NPU discovery/enumeration/search additionally accept a `seeds: seq[string]` restricted to supported school-directory paths.

Search and enumeration return `Future[FacultyResult]` rather than a bare sequence, so partial collection cannot be mistaken for a successful empty result:

```text
FacultyResult
  records: seq[FacultyRecord]
  issues: seq[FacultyIssue]  # institution, sourceUrl, message, status
  complete: bool
  scope: string
```

`complete` describes discovery and primary-profile retrieval within the stated scope, not every member of a university. Reaching a page/profile limit, failing a directory/profile, or encountering an unsupported HIT directory row marks it false. Issues use status 206 for truncation. Supplemental HIT body failures and missing/obfuscated fields appear in record `warnings`; they do not invalidate a usable primary profile. A single-institution discovery can raise `ApiError` for an unusable initial response; `searchAllFaculty` catches institution failures and retains other results. Programmer errors such as invalid limits raise `ValueError`.

`searchAllFaculty` starts all three searches before awaiting them. One shared client enforces transport limits across those searches. There is no ranking, deduplication across people/institutions, or comparison of names. Multiple directory anchors to the same explicit profile URL are deduplicated structurally.

## Record and text preservation

`FacultyRecord` contains `institution`, `sourceUrl`, `profileUrl`, `name`, optional `nameZh`, `nameEn`, `title`, `unit`, `school`, `department`, `laboratory`, `email`, `researchAreas`, `rawFields`, `rawFieldEntries`, `rawHtml`, `additionalSources`, and `warnings`. Missing optional values serialize as JSON `null`; empty research arrays remain arrays.

`unit` preserves ambiguous organizational labels such as HIT's `目前就职` and NUAA's `所在单位`. A value that happens to end in 学院 is not automatically reclassified as a school. Only explicit school/department/laboratory labels populate those fields.

`rawHtml` retains exactly the HTML passed to the parser. Live retrieval keeps the response body without browser rendering. `rawFields` retains original label values, including unknown fields and empty values inside recognized metadata blocks. Duplicate labels are joined with a newline in that convenience table; `rawFieldEntries` also retains each separate label/value in order. `additionalSources` retains directory responses and HIT's JSON-encoded body response. HIT POST source URLs include the form parameters as a query for provenance; these are not assertions that the endpoint supports GET.

DOM parsing decodes HTML entities. Common fields remove surrounding ASCII layout whitespace; labels tolerate surrounding Unicode whitespace and Chinese/ASCII colons. Internal spacing, Chinese punctuation, name order and research wording are preserved. No comma/semicolon topic splitting is performed: one source field or paragraph produces one research entry. Exact original markup and whitespace remain available in the source documents. Invalid UTF-8 is rejected instead of silently transcoded.

Names are copied only from explicit page or directory text. HIT's directory spells one English name `Zhang Haochun`, while its English profile uses `Haochun` followed by a nonbreaking space, 24 spaces, and `Zhang`. Those differences are retained. Plain email text is accepted when present; source-obfuscated email fields are retained without reversing or decrypting them.

A successfully retrieved profile retains its directory metadata under `directory/` labels and its directory source in `additionalSources`. When a linked profile cannot be fetched, a named directory row remains a valid record: `sourceUrl` is the directory, `profileUrl` is the linked profile, and the retrieval failure is reported. Unnamed search hits cannot yield a fabricated faculty record.

## Public endpoints and parsing evidence

Inspected on 2026-09-09. These are university website endpoints, not guaranteed stable public APIs. Fixture assertions cover the captured structures rather than hypothetical university-wide templates.

### HIT

The [public portal](https://homepage.hit.edu.cn/home-index?lang=zh) links to [teacher search](https://homepage.hit.edu.cn/search-teacher-by-phoneticize). Its public frontend posts form data to:

```text
POST https://homepage.hit.edu.cn/hompage/findTeachersByName.do
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
userName=<query>&userChina=&deptId=&userTitle=&orderByCause=u.modify_time+desc
```

The `hompage` spelling is the site's actual path. `userName` is the native name search; an empty value enumerates the returned directory. It is not implemented as a general research-topic search. `userChina` is the frontend's surname-letter filter. The adapter uses the returned `rows` directly. The frontend does not actually paginate this request: both a one-result name search and a fourteen-row letter query reported the same `totalCount=13` and `totalPage=2`. Those counters cannot establish completeness and are not used to synthesize requests.

Profiles use `/{slug}`, with `/pages/{slug}` also observed. Captured examples: [Chinese profile](https://homepage.hit.edu.cn/zhc) and [English profile](https://homepage.hit.edu.cn/zhc?lang=en). DOM anchors include `.chineseName`, `.englishName`, `.user-post`, `#teacher-honor`, `.user-describe`, and label/value list items inside `.part4`/`.ul-cont`. Missing fields are allowed.

When `.teacher-body[data-tid]` is present, retrieval also posts its public identifier to `https://homepage.hit.edu.cn/TeacherHome/teacherBody.do` (`id=630` in the fixture). The response is a JSON string containing HTML. Recognized `.con_parts` sections use `.part_t_l` headings and `.editor_content` values. Only research, laboratory/team and related profile metadata sections are extracted; the raw response is retained in full during live collection.

Observed fields: Chinese name, an explicit English directory name/English-page name, academic title, current unit, discipline, research directions/fields, doctoral-supervisor text and descriptive text. Laboratory and explicit school/department labels are supported when present. The sampled email uses `.EmailText` with reversed source text; `email` is null and its exact value remains raw. Discovery does not automatically fetch both language versions.

### NUAA

The [faculty portal](https://faculty.nuaa.edu.cn/) exposes an [alphabetical directory](https://faculty.nuaa.edu.cn/pinyin_list.jsp?urltype=tsites.PinYinTeacherList&wbtreeid=1001&py=a&lang=zh_CN) for `py=a` through `z`. The adapter reads `.rwjj` list items and follows actual next-page anchors containing `PAGENUM`; it does not guess reverse-numbered filenames.

Native search uses:

```text
GET https://faculty.nuaa.edu.cn/result.jsp
  ?wbtreeid=1001&searchType=All&currentnum=<page>
  &kw=<base64 UTF-8 query>
  &tsites_search_content=<base64 UTF-8 query>
  &_tsites_search_current_language_=zh_CN
```

Both query parameter names are used by the site's frontend. Search `.result` links may point to a research subpage such as `/liweiwei/zh_CN/yjgk/101393/content/3236.htm`; its explicit path identifies the containing `/liweiwei/zh_CN/index.htm` homepage. The pagination text `共73页` was observed for `人工智能`, and a request using `currentnum=2` was verified. Native search searches site content; the parser extracts faculty metadata from the containing homepage, not the linked publication/project content.

Two captured profile layouts are supported:

* [Classic: 刘长江](https://faculty.nuaa.edu.cn/lcj1/zh_CN/index.htm): `meta[name=keywords]`, `.t_photo`, `.t_jbxx_nr`, research-heading paragraphs, and research tabs under `.slideTxtBox2`. HTML attribute names are matched case-insensitively because the source uses uppercase `Name` and `Content`.
* [Modern: 安鲁陵](https://faculty.nuaa.edu.cn/all/zh_CN/index.htm): `.PersonalIntroduction`, `.PersonalIntroductionMore`, `.PersonalContent`, explicit name and position text, and labeled list items.

Observed fields include bilingual name metadata, title, unit, degree, education, graduation institution, office, academic appointments and research directions. Plain `联系方式` supplies an email in the classic fixture even though its `电子邮箱` field contains encrypted source text. That encrypted field is retained without decoding. Research topics may be enumerated paragraphs, empty homepage tabs, or separate pages. Only research already present in the homepage is parsed; additional research pages are not crawled. A school's unobserved custom template may require a new parser branch.

### NPU

The [central teacher portal](https://teacher.nwpu.edu.cn/) returned a JavaScript bot challenge during inspection. It was not executed or bypassed, and its profile template could not be verified. Coverage is explicitly limited to these accessible school directories:

| Directory | Discovery and available information |
| --- | --- |
| [Mathematics & Statistics faculty features](https://math.nwpu.edu.cn/jsfc/jsfc.htm) | `.erji-content-div` profile anchors to `/info/1502/*.htm`; actual next-page link `jsfc/2.htm` resolves to `/jsfc/jsfc/2.htm` |
| [Management professors](https://som.nwpu.edu.cn/guanlixy/szdw/jsml1/zc/js.htm) | `.m-table-lb` table columns `姓名`, `职称`, `系别`, `研究方向`, `个人主页` |
| [Management associate professors](https://som.nwpu.edu.cn/guanlixy/szdw/jsml1/zc/fjs.htm) | Same public directory family, discovered from school navigation |
| [Management lecturers](https://som.nwpu.edu.cn/guanlixy/szdw/jsml1/zc/js1.htm) | Same public directory family, discovered from school navigation |

Management's professor pagination uses reverse-numbered links such as `js/3.htm`; the adapter follows the actual link. The captured fixture is the professor table; the adjacent directory templates are not separately fixture-covered. This is not an exhaustive school-discovery crawler or a university-wide faculty roster.

The [captured Mathematics profile](https://math.nwpu.edu.cn/info/1502/37427.htm) uses `.danpian-h1` for its name and `.v_news_content` for its biography. Research can be embedded in prose. The entire source paragraph is retained as a research entry and biography raw field. An apparent job title in a biography is not converted into a structured title. Explicit label/value paragraphs are captured when present, including academic positions, discipline and a teacher-homepage URL. A plaintext central homepage reference in the biography is preserved without automatically following it.

Management records have explicit titles, departments and research text directly in the directory. Their profile links target the central teacher host. An access challenge stops retrieval and starts a five-minute host cooldown; directory records survive with warnings and issues. Direct `NPU.fetchFaculty` supports the observed Mathematics template and rejects unsupported central markup. NPU search is an exact, case-sensitive source-text substring filter over the bounded collected records; it is not a verified native portal search.

## Differences to retain for the next phase

| Concern | HIT | NUAA | NPU |
| --- | --- | --- | --- |
| Search meaning | Native name search | Native site-content search | Local exact substring over collected records |
| Name forms | Chinese header, English directory/alternate page; order and spacing can differ | Bilingual keywords or explicit template name; foreign names occur | Chinese feature heading/table name in captured sources; no verified English alias in live fixture |
| Organizational label | `目前就职`/English `Department` is retained as `unit` | `所在单位`/`单位` is retained as `unit` | Management explicitly supplies `系别` as `department` |
| Title | Separate header | Unlabelled position block or explicit label | Explicit Management column; Mathematics prose stays prose |
| Research granularity | Comma-delimited header or long supplementary field | Numbered paragraphs, tabs, sometimes absent from homepage | Management field or full Mathematics biography paragraph |
| Other metadata | `学科`, supervisor text, descriptive text | Degree, education, main/other appointments, office, contact | Biography, personal teacher link, school-specific fields |
| Email | Sample source is obfuscated | Encrypted field and a separate plaintext contact | Not present in captured Mathematics/Management excerpts |
| Coverage evidence | Rows returned by native portal, unreliable count metadata | Public A–Z directory and content search, bounded pagination | Two schools only; central portal access restricted |

These differences remain visible in the data. They are not reconciled into an ontology. A field supported by a parser is not evidence that every institution or profile actually provides it.

## HTTP and limits

Defaults: 20-second timeout per request, three seconds between completion and the next request on the same host, one retry (configurable 0–2), at most three active requests globally (configurable 1–8), at most 32 pending/active requests, and an 8 MB response limit. Transient network/server errors have bounded retries. HTTP 401, 403, 429 and recognized access challenges are not retried; the host cools down for five minutes. Redirects produce explicit failures rather than being followed to login or challenge pages. URLs are restricted to supported public hosts and paths. No browser automation, authentication, CAPTCHA handling or protection bypass is used.

Default discovery limits are 30 directory pages and 100 profile URLs per institution. HIT's response has no verified request-side pagination, so its profile cap applies after retrieving the single bounded-size response. NPU exact-text searching may be slow because it retrieves the bounded directory/profile set before filtering. Increase budgets explicitly and inspect `complete`, `scope`, `issues` and `warnings`. Search does not imply all institution data was searched.

The default client and its queues are process-local and intended for a single `asyncdispatch` event loop. Reuse one client across related operations to retain pacing and cooldown state; multiple processes/independent clients do not coordinate. There is no new faculty response cache. JSON retains raw bodies, so output can be large and contain repeated directory snapshots; persisting/deduplicating source blobs is left to callers. This library performs no automatic disk writes.

## Verification and example

```sh
# All fixture and local HTTP tests; no university requests:
nimble --nimbleDir:.nimble --offline testFaculty

# Full existing application regression suite plus faculty tests:
nimble --nimbleDir:.nimble --offline test

# Explicit opt-in, small live request budget:
nimble --nimbleDir:.nimble --offline testFacultyLive

# Standalone example; one directory page / three profiles per institution:
nim c -r --path:src --out:bin/faculty_search examples/faculty_search.nim HIT 张昊春
```

Nimble's `--offline` controls dependency resolution; it does not prevent the explicitly live task/example from using the network. Normal tests use static fixtures, injected Nim transports and a loopback HTTP server. They verify Chinese/English names, UTF-8, optional fields, titles, units/departments, research, plaintext/obfuscated email, duplicate/empty labels, malformed HTML, raw sources, JSON, safe URLs, directory pagination, truncation, concurrent search, partial failures, request pacing/retries, queue/concurrency limits, timeouts, oversized responses and challenge handling. The loopback tests need permission to bind a local port.

The following is an excerpt from the first captured NPU Management directory record. Raw fields, source HTML, ordered entries and warnings are omitted from this excerpt only; `toJson()` includes them.

```json
{
  "institution": "NPU",
  "sourceUrl": "https://som.nwpu.edu.cn/guanlixy/szdw/jsml1/zc/js.htm",
  "profileUrl": "https://teacher.nwpu.edu.cn/zhaosongzheng.html",
  "name": "赵嵩正",
  "nameZh": "赵嵩正",
  "nameEn": null,
  "title": "教授",
  "unit": null,
  "school": null,
  "department": "信息管理系",
  "laboratory": null,
  "email": null,
  "researchAreas": ["信息管理与信息系统、设备管理、项目管理"]
}
```

To add BUAA later, add one institution module with independent directory/profile fixtures, add the enum member and dispatcher branches, and reuse the same transport and result types. No plugin framework or normalization changes are necessary.

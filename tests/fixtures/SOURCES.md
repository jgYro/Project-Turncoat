# Faculty fixture provenance

Public pages were retrieved on **2026-09-09**. These are static, sanitized excerpts of real university responses, not invented faculty records. Synthetic edge cases appear inline in the Nim tests and are separate from these files.

HTML excerpts retain the relevant DOM hierarchy, names, classes, identifiers, links, metadata and source text. A temporary Nim utility using `std/htmlparser` selected the relevant elements and removed scripts, comments, styles, images, buttons, external assets and unrelated page sections. Serialization standardizes tag/attribute quoting and decodes entities; the fixtures are therefore not byte-for-byte copies of the original HTTP responses. The production parser separately retains its exact input in `rawHtml`. Original text is not translated, transliterated or rewritten.

## HIT

| Fixture | Public source and retained content |
| --- | --- |
| `hit/profile.html` | [张昊春 Chinese profile](https://homepage.hit.edu.cn/zhc), identity/header metadata and the supplementary-body identifier |
| `hit/profile_en.html` | [English version](https://homepage.hit.edu.cn/zhc?lang=en), explicit English name, title and metadata; internal NBSP/spacing is intentional |
| `hit/directory.json` | `POST https://homepage.hit.edu.cn/hompage/findTeachersByName.do`, form `userName=张昊春&userChina=&deptId=&userTitle=&orderByCause=u.modify_time+desc`; original one-row JSON response, including unreliable pagination metadata |
| `hit/body.json` | `POST https://homepage.hit.edu.cn/TeacherHome/teacherBody.do`, form `id=630`; JSON-string response reduced to its 研究领域 section, with unrelated publication/patent sections excluded |

The public request shapes were read from the portal's `scripts/homepage/search-teacher-by-phoneticize.js`, `scripts/base.js`, and `scripts/homepage/home-teacher-show.js`. No private endpoint, credential or challenge response was used. The source-obfuscated email in the profile is deliberately preserved unchanged.

## NUAA

| Fixture | Public source and retained content |
| --- | --- |
| `nuaa/profile.html` | [刘长江](https://faculty.nuaa.edu.cn/lcj1/zh_CN/index.htm), classic identity/metadata blocks, keywords and the three research-direction paragraphs |
| `nuaa/profile_modern.html` | [安鲁陵](https://faculty.nuaa.edu.cn/all/zh_CN/index.htm), modern introduction/metadata blocks and keywords |
| `nuaa/directory.html` | [Alphabetical A directory](https://faculty.nuaa.edu.cn/pinyin_list.jsp?urltype=tsites.PinYinTeacherList&wbtreeid=1001&py=a&lang=zh_CN), faculty list and pagination anchors |
| `nuaa/search.html` | [Native search for 人工智能](https://faculty.nuaa.edu.cn/result.jsp?wbtreeid=1001&tsites_search_content=5Lq65bel5pm66IO9&_tsites_search_current_language_=zh_CN), first-page result links and pagination |

The public `system/resource/tsites/com/search/tsitesearch.js` explains UTF-8/base64 query submission. A second result-page request using `currentnum=2` and `kw` was inspected to verify pagination. The encrypted email source field is retained without decoding. The classic profile also independently exposes a plaintext contact address.

## NPU

| Fixture | Public source and retained content |
| --- | --- |
| `npu/profile_math.html` | [高娅莉 Mathematics feature](https://math.nwpu.edu.cn/info/1502/37427.htm), heading and biography block |
| `npu/directory_math.html` | [Mathematics faculty features](https://math.nwpu.edu.cn/jsfc/jsfc.htm), profile link container and pagination |
| `npu/directory_management.html` | [Management professor directory](https://som.nwpu.edu.cn/guanlixy/szdw/jsml1/zc/js.htm), faculty table and pagination |

The central `https://teacher.nwpu.edu.cn/` returned a bot-protection script and was not bypassed. No central-portal profile fixture is claimed. The two other configured Management title-directory seeds come from public navigation links; only the professor table is represented by a static fixture. All NPU coverage is limited to the stated school directories, not a complete university roster.

## Updating

Retrieve a small public sample using the documented request shape and conservative pacing. Stop on authentication, CAPTCHA or bot protection. Preserve exact source text, record the date/URL and any new sanitization steps here, and update selectors only after inspecting the changed DOM. Keep normal tests offline and explicitly identify any synthetic fixture additions.

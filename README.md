# Research Explorer: arXiv & Google Patents

A responsive research search interface written in **Nim 2.2** with **HappyX 4.7.4**. HappyX renders HTML on the server and searches arXiv papers and Google Patents. There is no API key, account, JavaScript framework, or frontend build step.

The page and reusable sections in `src/views.nim` use HappyX's `return buildHtml:` syntax with nested `tHtml`, `tHead`, `tBody`, and other tags. Helpers return `TagRef` values and compose through `{helper(...)}` expressions. The route returns the HTML tree directly, with the appropriate response status and headers. Dynamic text is escaped by HappyX; dynamic attribute values are escaped before they enter the tree.

## Run

Install [Nim and Nimble](https://nim-lang.org/install.html), a C compiler, and OpenSSL. On macOS, Homebrew's `nim` and `openssl@3` packages work.

From this directory:

```sh
nimble --nimbleDir:.nimble --accept install --depsOnly
nimble --nimbleDir:.nimble setup
nimble --nimbleDir:.nimble build
./bin/arxiv_search
```

Open **http://127.0.0.1:5000** for papers or **http://127.0.0.1:5000/patents** for patents. Dependencies stay in the project's `.nimble` directory. The checked-in lockfile pins dependency revisions; it records numeric versions for HappyX's commit-based dependencies so Nimble correctly resolves their installed source directories.

To use a different local port:

```sh
PORT=8080 ./bin/arxiv_search
```

`HOST` defaults to `127.0.0.1`. Set `HOST=0.0.0.0` explicitly to listen on all interfaces. `ARXIV_API_URL` defaults to `https://export.arxiv.org/api/query`; override it only when testing against a local fixture server. CSS, JavaScript, and the favicon are embedded in the executable at compile time, so rebuild after editing them.

## Search

- **All fields, title, author, or abstract:** unquoted words are combined with AND. Quote a phrase, for example `"graph neural networks"`.
- **Advanced query:** pass arXiv syntax directly, such as `au:del_maestro AND ti:checkerboard` or `(ti:electron OR ti:proton) ANDNOT cat:cond-mat.*`.
- **arXiv IDs:** look up `1706.03762`, a version such as `1706.03762v7`, or comma-separated IDs. These use `id_list`, preserving version selection. Other filters narrow the ID lookup.
- Filter by discipline, author, and submission date. Date boundaries are inclusive in UTC.
- Sort by relevance, submission date in either direction, or last update. Choose 10, 25, or 50 papers per page.
- Expand abstracts, inspect all authors and categories, and open the original paper, PDF, or DOI.
- Share or bookmark any search URL. Press `/` to focus the search box. Forms, pagination, and abstracts also work with JavaScript disabled; use **Update** to apply sorting without JavaScript.

The homepage offers starter searches and does not fetch or invent results. Unavailable services, invalid queries, and empty results have dedicated states.

## Patent search and JSON API

The **Patents** tab searches by topic, assignee, inventor, patent office, and filing date. Results link to Google Patents and available PDFs. Sorting, filters, pagination, and shareable URLs work without JavaScript, using HappyX `buildHtml` just like the paper interface.

```sh
curl --get 'http://127.0.0.1:5000/api/patents/search' \
  --data-urlencode 'q=neural network' --data-urlencode 'country=US'
curl 'http://127.0.0.1:5000/api/patents/US9014905B1'
```

See [the API reference](docs/patents-api.md) for parameters, response fields, pagination, errors, caching, and testing overrides. The adapter uses Google Patents' **undocumented website endpoints**, which may change or become unavailable. It is an independent integration, not an official Google API. Google's [published patent datasets](https://github.com/google/patents-public-data) offer a separate BigQuery option for bulk data access.

## Institution search presets

Open **http://127.0.0.1:5000/institutions**, or select **Institutions** in the navigation. HIT, NUAA, NPU and Beihang are included as starting presets. **Add institution** saves a name, optional original-language name, and optional patent assignee name. The assignee defaults to the institution name; custom entries can be removed. Saved entries persist across app restarts in `data/institutions.json` (ignored by Git). Set `INSTITUTIONS_FILE` to use another local file. One running app instance owns the file.

**Search patents** submits the card's assignee through the existing Google Patents adapter. Add topic keywords or other filters on the results page. **arXiv name mentions** searches the quoted institution name in arXiv metadata; arXiv provides no affiliation search filter, and this is not a complete list of that university's papers. These presets contact Google Patents or arXiv only. They do not call university websites or the faculty collectors. Adding or removing an institution makes no provider request.

The page and forms use Nim/HappyX `buildHtml` and work without JavaScript. Form tokens protect changes, duplicate entries and invalid text are rejected, and failed submissions retain entered values. The preset names are explicit search strings; alternate assignee spellings are not automatically merged.

## Raw faculty collection

The independent Nim library in `src/faculty/` collects public faculty metadata from HIT, NUAA, and supported NPU school directories. It preserves Chinese/English source text, missing fields, institution-specific metadata, original response bodies and source URLs in JSON. Search and enumeration report partial results and crawl limits explicitly. NPU coverage is limited to Mathematics and Management; its central teacher portal returned an access challenge.

See [the faculty library reference](docs/faculty.md) for endpoints, per-institution field differences, parsing limitations, async usage, HTTP settings and JSON examples, and [fixture provenance](tests/fixtures/SOURCES.md) for captured public sources. Faculty data is not connected to arXiv or Google Patents.

```sh
nimble --nimbleDir:.nimble --offline testFaculty
nim c -r --path:src --out:bin/faculty_search examples/faculty_search.nim HIT 张昊春
```

The example makes live requests with a one-page/three-profile budget. The normal tests use static fixtures and a local Nim HTTP server. `testFacultyLive` is a separate, explicitly opt-in task for a small live smoke test.

## arXiv API behavior

Following the [arXiv API manual](https://info.arxiv.org/help/api/user-manual.html#detailed_examples), the application parses Atom metadata, honors pagination and sort parameters, and handles API errors returned inside Atom feeds as well as HTTP failures.

The standard HappyX async server runs one process-local request queue. Requests to arXiv are serialized with at least **three seconds between completed requests and the next request**, have a **20-second upstream timeout**, and are cached in memory for **24 hours** (up to 128 searches/pages). Queued identical searches reuse the preceding response. At most eight searches can wait or run at once; overflow receives an actionable 503 response. Cache hits return immediately. The UI caps pagination at arXiv's first 30,000 matches and encourages refining broad searches.

Cache and pacing are process-local. Run a single instance for this standalone application; multiple production replicas would need shared rate limiting and caching. Restarting the process clears the cache. The application performs live network requests only after a search is submitted.

## Verify

```sh
nimble --nimbleDir:.nimble test
```

Tests cover query fields and phrases, Boolean grouping, ID versions, dates, URL encoding, pagination, Atom namespaces and metadata, empty/error feeds, HTML escaping, and safe paper links. A local HTTP fixture server verifies caching, concurrent duplicate searches, request pacing, upstream failures, timeout, and recovery without depending on arXiv availability. These integration tests require permission to bind a loopback port.

Patent tests cover nested URL encoding, filters, publication identifiers, search and document parsing, optional metadata, empty results, schema changes, safe links, and the HappyX page. A second local HTTP fixture server checks both patent endpoints' transport, including redirects, rate limits, oversized responses, queue limits, timeout, and recovery.

`GET /health` returns `ok` without contacting either provider.

For browser checks without contacting Google, run the **Nim fixture provider** in one terminal:

```sh
nim c -r --out:bin/patents_fixture tests/patents_fixture_server.nim
```

Start a separate app instance in another terminal:

```sh
PORT=5010 PATENTS_ORIGIN=http://127.0.0.1:5011 ./bin/arxiv_search
```

Open `http://127.0.0.1:5010/patents`. This instance uses synthetic test data: search `empty` for no results, `busy` for a rate-limit error, or any other query for the sample records. Lookup `US1234567B1` returns the synthetic document. Stop both processes when finished. The application and test providers are Nim; Python is not required.

## Files

| Path | Purpose |
| --- | --- |
| `src/arxiv_search.nim` | HappyX routes and HTTP responses |
| `src/arxiv.nim` | Query validation, URLs, models, Atom parsing |
| `src/arxiv_client.nim` | Async HTTP, caching, pacing, and errors |
| `src/views.nim` | Escaped, accessible server-rendered page |
| `src/patents.nim` | Patent queries, URLs, provider parsing, and JSON responses |
| `src/patents_client.nim` | Google Patents HTTP adapter, cache, and request queue |
| `src/patent_views.nim` | HappyX patent search page |
| `src/api_errors.nim` | Shared provider error type |
| `src/institutions.nim` | Persistent local institution search presets and provider URLs |
| `src/institution_views.nim` | HappyX institution cards and add/remove forms |
| `docs/patents-api.md` | Patent JSON API reference |
| `src/faculty/` | Independent raw faculty parsers, async collection and JSON |
| `docs/faculty.md` | Faculty endpoints, API, source differences and limitations |
| `public/` | Responsive styles and small progressive enhancements |
| `tests/` | Unit/HTTP tests, synthetic fixtures, and documented public faculty excerpts |

Framework reference: [HappyX documentation](https://hapticx.github.io/happyx/). This is an independent interface and is not affiliated with arXiv or Google.

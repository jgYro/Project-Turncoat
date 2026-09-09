# Project Turncoat

One Nim/HappyX application for arXiv papers, Google Patents, institution search
presets, and a local SQLite/D3 investigation graph. Search pages use HappyX's
`buildHtml` syntax; graph assets are bundled locally with no frontend build step.

All screens share the dark cyan theme in `public/theme.css`, with locally bundled
IBM Plex Sans and IBM Plex Mono. Page layouts live in `public/style.css` and
`src/web/static/app.css`; typography, colors and navigation share the same tokens.
See [font sources and license](public/fonts/README.md).

Click **Investigate** on a patent to save its metadata, extract its inventor
names, and search those names through Google Patents and arXiv. The graph updates
as responses arrive. Select a patent, paper, or individual name and click
**Search related names** to continue. Original names and source metadata remain
saved; name-search candidates are not treated as verified identities.

Saved graphs and JSONL import/export work offline. New investigations contact
only the two configured providers. The faculty library is not invoked.
See [investigation behavior and data model](docs/turncoat-investigations.md).

## Quick start

Prerequisites: **Nim 2.2.x** (tested with 2.2.10), Nimble, a C compiler, Git,
SQLite's shared library with JSON functions and preferably FTS5, and OpenSSL
for the existing HappyX build configuration. SQLite 3.38+ is recommended.
On macOS the system SQLite works; on Linux install your distribution's SQLite
runtime/development package. On Windows put a compatible sqlite3.dll on PATH.

~~~sh
nimble --nimbleDir:.nimble --useSystemNim --accept install --depsOnly
nimble --nimbleDir:.nimble --useSystemNim setup
nimble --nimbleDir:.nimble --useSystemNim build

./bin/turncoat init
./bin/turncoat import demo tests/fixtures/graph/demo.jsonl
./bin/turncoat serve
~~~

Open **http://127.0.0.1:5000** for search or **http://127.0.0.1:5000/graph** for the graph. Select **demo**, search **Institute**, and select
the result. Click **Alex Example**, then **Load saved neighbors** to add connected
nodes. Double-clicking also expands. Click any node to inspect its ID, label
and JSON properties. Nodes are draggable; scroll to zoom, and use the controls
to center, pause the force layout, or clear the working graph.

The synthetic fixture has four nodes and three directed edges:
Institution → EMPLOYS → Person → AUTHORED → Paper, and
Person → INVENTED → Patent. It is entirely fictional.

~~~sh
./bin/turncoat stats demo
./bin/turncoat export demo /tmp/demo-export.jsonl
./bin/turncoat --db:data/reimport.db import demo /tmp/demo-export.jsonl
./bin/turncoat --db:data/reimport.db stats demo
~~~

Export requires a **new destination filename** to protect existing files and
the database. It streams into a temporary file before publishing the result.

## Architecture and boundaries

~~~mermaid
flowchart TD
  Source[Google Patents / arXiv] --> Parser[Existing provider adapters]
  Parser --> Investigation[Bounded name investigation]
  Investigation --> Records[Canonical NodeRecord / EdgeRecord]
  Records <--> JSONL[Streaming JSONL import / export]
  Records --> SQLite[(SQLite: durable source of truth)]
  JSONL <--> SQLite
  SQLite --> Query[Bounded subgraph queries]
  Query --> Grim[Grim working graph and traversal]
  Grim --> DTO[Stable API DTO: nodes / links]
  DTO --> HappyX[HappyX local REST service]
  HappyX --> D3[D3 progressive graph explorer]
~~~

SQLite owns persistence. Grim owns only a bounded working graph. Canonical
records feed a separate D3 DTO; no Grim or SQLite internals reach JavaScript.
Parsers produce records and know nothing about HappyX or visualization.
JSONL stores canonical records rather than D3 objects.

Datasets are registered in a datasets table. Indexed **dataset columns** on
nodes and edges make isolation and filtering explicit and efficient. Each
record has one owning dataset in schema v1. OIDs are globally unique across
both record types and all datasets; imports cannot silently move an OID.
Composite foreign keys ensure both endpoints belong to the edge's dataset.
Deleting a node cascades to its edges.

This initial ownership model avoids ambiguous updates to shared records.
A future combined view can union source selections; shared dataset membership
would require a schema migration. No source names are built into the engine.

Schema initialization runs automatically on open, with migrations tracked by
SQLite user_version. A newer unsupported schema is refused. JSON validity,
foreign keys, identity constraints, WAL and a five-second busy timeout are
enabled. All SQL resides in storage modules and all values use prepared
statements with SQLite binding. API reads use a consistent snapshot.

## Dependencies and compatibility

| Dependency | Role |
| --- | --- |
| [HappyX 4.7.4](https://github.com/HapticX/happyx) | Local HTTP server using its standard async backend |
| [ebran/grim 0.3.1](https://github.com/ebran/grim) | In-memory labeled graph and adjacency traversal |
| [nim-lang/db_connector 0.1.0](https://github.com/nim-lang/db_connector) | Maintained Nim SQLite C binding; no ORM |
| [NimYAML 0.16.0](https://github.com/flyx/NimYAML/tree/v0.16.0) | Pinned compatibility dependency of Grim |
| zero_functional | Transitive Grim dependency |
| [D3 7.9.0](https://github.com/d3/d3/tree/v7.9.0) | Force graph, drag, zoom; vendored with ISC license |
| Nim standard library | JSON, streams, collections, CLI, tests and filesystem operations |

The lockfile pins all transitive revisions. Use it when installing; do not
blindly regenerate it. Grim's upstream YAML requirement follows HEAD, but
current NimYAML no longer exports the old hint API expected by Grim.
The unified executable and graph tests pin NimYAML 0.16.0 and select
**refc** in their target-specific Nim configuration, since that version uses
shallowCopy. Nimble builds one executable: **turncoat**.

Grim's graph-level neighbor template is incompatible with Nim 2.2 iterator
invocation; the private adapter uses its node-level closure iterator instead.
The adapter contains the narrowly scoped GC-safety annotation for that
read-only iterator. Grim Box supports scalar values, so the adapter preserves
nested properties as canonical JSON and stores a lossless JSON string in
Grim's private property map. No dependencies are modified or forked.

Nimble 0.22 can write unusable HEAD-based versions and empty package URLs when
refreshing this dependency tree. The checked-in lockfile records actual
numeric package versions, Git revisions, checksums and repository URLs.
The setup command generates local compiler paths, so the checkout is portable.

## Configuration and CLI

Defaults require no environment setup: data/app.db, 127.0.0.1, port 5000.
Options use Nim's colon or equals syntax and may appear before or after the
command. The default command is serve.

~~~sh
./bin/turncoat --db:data/work.db --port:5050 --neighbor-limit:50 serve
./bin/turncoat --db:data/work.db --batch-size:1000 import my_dataset input.jsonl
./bin/turncoat --help
~~~

| Setting | Default | Bound |
| --- | --- | --- |
| --db | data/app.db | Local CLI path |
| --host | 127.0.0.1 | Explicit override to listen elsewhere |
| --port | 5000 | 1–65535 |
| --neighbor-limit | 100 | At most --max-neighbors |
| --max-neighbors | 1000 | At most 1000 relationships per request |
| --depth | 1 | 0–maximum depth |
| --max-depth | 3 | At most 10 |
| --max-nodes | 500 | At most 10000 nodes per subgraph/canvas |
| --max-edges | 1000 | At most 20000 edges per subgraph/canvas |
| --batch-size | 500 | 1–10000; also an 8 MiB batch threshold |
| --no-fts | Off | Disable search while preserving storage |

TURNCOAT_DB, HOST and PORT provide optional environment overrides. The legacy
GRAPHAPP_DB, GRAPHAPP_HOST and GRAPHAPP_PORT variables remain fallbacks; explicit
CLI options take precedence. Neither imports nor exports
are exposed over HTTP, so API parameters cannot select filesystem paths.

## REST API

Every API response is JSON. Errors have the shape
{"error":{"status":400,"message":"..."}}. Invalid input returns 400,
missing datasets/nodes/routes return 404, unavailable FTS returns 503,
and unexpected failures return a generic 500 without internal stack traces.

| Endpoint | Behavior |
| --- | --- |
| GET /api/health | Health, FTS availability and configured limits |
| GET /api/datasets | IDs and node/edge counts, including empty datasets |
| GET /api/:dataset/search?q=... | Matching node DTOs and pagination metadata |
| GET /api/:dataset/node/:oid | One node DTO |
| GET /api/:dataset/node/:oid/neighbors | Root, adjacent nodes and incident links |
| GET /api/:dataset/node/:oid/edges | Incident link DTOs |
| GET /api/:dataset/subgraph/:oid?depth=1 | Bounded breadth-first working graph |

~~~sh
curl 'http://127.0.0.1:5000/api/demo/search?q=Example&labels=Person'
curl 'http://127.0.0.1:5000/api/demo/node/demo%3Aperson%3A1/neighbors?limit=1&offset=0'
curl 'http://127.0.0.1:5000/api/demo/subgraph/demo%3Ainstitution%3A1?depth=2'
~~~

URL-encode each OID as one path segment. Encoded slashes, plus signs, Unicode
and literal percent escapes are supported. A small dispatcher splits the
original path before decoding, avoiding HappyX's whole-path decoding behavior.
Dataset IDs allow 1–64 ASCII letters, digits, underscores and hyphens.
OIDs allow 1–512 UTF-8 bytes with no ASCII whitespace/control characters.

Search indexes OIDs, labels and all nested string property values, including
arrays, via an interchangeable TextExtractor callback. It makes no assumptions
about labels or property names. Every whitespace-separated query term is
quoted as a literal FTS phrase and combined with AND; results are ordered by
OID, without ranking. Queries are limited to 512 bytes/32 terms; optional
comma-separated labels accepts up to 20 labels. FTS5 indexes update in the same
transaction as nodes through SQLite triggers. On a build without FTS5, storage
works and search explicitly returns 503.

Search, neighbors and edges accept limit and offset. Search defaults to 30;
neighbors/edges default to 100. Offsets are bounded at 1000000. Metadata reports
returned, total, truncated, hasMore and nextOffset. Neighbor counts describe
**relationships**, not distinct nodes; both directions are included, with
self-loops counted once and parallel edges preserved.

Graph DTOs have this stable shape, independent of Grim:

~~~json
{"nodes":[{"id":"demo:person:1","label":"Person","properties":{"name":"Alex"}}],
 "links":[{"id":"demo:edge:1","source":"demo:person:1","target":"demo:person:1",
           "label":"RELATED","properties":{}}]}
~~~

Subgraphs include returned node/link counts, depth, truncation/budget flags,
and per-expansion exact relationship totals. Their aggregate total is null:
computing all reachable nodes just to count them would defeat bounded loading.
Nodes at the requested depth are not expanded, and edges between that boundary
are not automatically included. Capped traversal reports omitted relationships.

The explorer never fetches an entire dataset. It retains existing simulation
objects while merging new IDs, generates legends from observed labels, and
shows Load more relationships for partial neighborhoods. It also bounds its
canvas and refuses pages exceeding the cap without advancing pagination.

## Canonical JSONL

Each UTF-8 line is one node or edge, with an object-valued properties field:

~~~jsonl
{"type":"node","oid":"source:item:1","label":"AnyLabel","properties":{"name":"Example","aliases":["Alias"]}}
{"type":"node","oid":"source:item:2","label":"AnotherLabel","properties":{}}
{"type":"edge","oid":"source:relation:1","source":"source:item:1","target":"source:item:2","label":"RELATED","properties":{}}
~~~

Namespaces belong to future parsers; the engine treats IDs as opaque strings.
Dataset ownership is the import/export command argument, outside the portable
records. Export orders nodes before edges and records by OID, with recursive
property-key sorting. Labels may be heterogeneous and contain spaces.

Imports stream line by line, twice, so edges may precede nodes in the input.
Empty files establish empty datasets; blank lines, invalid JSON, missing or
wrongly typed fields, invalid IDs, non-object properties, records over 1 MiB,
and property nesting beyond 64 levels are rejected. CRLF and a missing final
newline are accepted.

Duplicate OIDs **upsert** within the same dataset: the last node/edge record in
its pass wins, replacing label/properties and edge endpoints. Counts printed by
import describe processed records, not newly created entities. A malformed
record or constraint failure rolls back the current batch; already committed
batches remain. Errors include line numbers and committed node/edge counts.
Re-running a corrected file is idempotent. Keep the input file stable during
both passes; this is a seekable-file importer, not a stdin pipe importer.

## Layout and testing

| Path | Responsibility |
| --- | --- |
| src/turncoat.nim, src/config.nim | Unified CLI and local configuration |
| src/arxiv_search.nim | Combined HappyX server and provider clients |
| src/investigations.nim | Bounded investigation orchestration and evidence records |
| src/model/ | Canonical nodes/edges, validation and deterministic JSON |
| src/storage/ | SQLite driver/schema, CRUD, FTS and streaming JSONL |
| src/graph/ | Grim adapter, bounded loading and traversal |
| src/api/ | Framework-independent endpoint behavior and DTOs |
| src/web/routes.nim | HappyX transport and embedded static assets |
| src/web/static/ | D3 explorer, CSS, bundled D3 and license |
| src/parsers/README.md | Future parser interface and synthetic example |
| tests/fixtures/graph/demo.jsonl | Small synthetic demonstration graph |
| tests/test_graph.nim | Canonical, storage, import/export, graph and API tests |
| tests/test_graph_http.nim | Executable/CLI and loopback HappyX integration |
| docs/graph-implementation-plan.md | API inspection, decisions and implementation plan |

~~~sh
nimble --nimbleDir:.nimble --useSystemNim testGraph
nimble --nimbleDir:.nimble --useSystemNim testGraphHttp
nimble --nimbleDir:.nimble --useSystemNim test
~~~

The HTTP suite requires loopback socket permission. Tests use temporary SQLite
files and synthetic fixtures, with no live website dependency. The final
command also runs the existing research and faculty fixture suites.

Future work should start with [parser integration](src/parsers/README.md),
explicit dataset-combination semantics, richer search/tokenization, and larger
fixture-driven performance testing. Real source parsers and entity analysis
are deliberately outside this initial foundation.

---

## Research search: arXiv & Google Patents

A responsive research search interface written in **Nim 2.2** with **HappyX 4.7.4**. HappyX renders HTML on the server and searches arXiv papers and Google Patents. There is no API key, account, JavaScript framework, or frontend build step.

The page and reusable sections in `src/views.nim` use HappyX's `return buildHtml:` syntax with nested `tHtml`, `tHead`, `tBody`, and other tags. Helpers return `TagRef` values and compose through `{helper(...)}` expressions. The route returns the HTML tree directly, with the appropriate response status and headers. Dynamic text is escaped by HappyX; dynamic attribute values are escaped before they enter the tree.

## Run

Install [Nim and Nimble](https://nim-lang.org/install.html), a C compiler, and OpenSSL. On macOS, Homebrew's `nim` and `openssl@3` packages work.

From this directory:

```sh
nimble --nimbleDir:.nimble --accept install --depsOnly
nimble --nimbleDir:.nimble setup
nimble --nimbleDir:.nimble build
./bin/turncoat
```

Open **http://127.0.0.1:5000** for papers or **http://127.0.0.1:5000/patents** for patents. Dependencies stay in the project's `.nimble` directory. The checked-in lockfile pins dependency revisions; it records numeric versions for HappyX's commit-based dependencies so Nimble correctly resolves their installed source directories.

To use a different local port:

```sh
PORT=8080 ./bin/turncoat
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

Cache and pacing are process-local. Run a single instance for this standalone application; multiple production replicas would need shared rate limiting and caching. Restarting the process clears the HTTP cache, while completed investigation queries remain reusable in SQLite. Live requests start after a search is submitted, an Investigate link is opened, or a graph node is explicitly expanded through the provider-search control.

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
PORT=5010 PATENTS_ORIGIN=http://127.0.0.1:5011 ./bin/turncoat
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

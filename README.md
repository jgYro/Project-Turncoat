# arXiv Explorer

A responsive research search interface written in **Nim 2.2** with **HappyX 4.7.4**. HappyX renders HTML on the server and queries the arXiv Atom API. There is no API key, account, JavaScript framework, or frontend build step.

The page and reusable sections in `src/views.nim` use HappyX's `return buildHtml:` syntax with nested `tHtml`, `tHead`, `tBody`, and other tags. Helpers return `TagRef` values and compose through `{helper(...)}` expressions. The route returns the HTML tree directly, with the appropriate response status and headers. Dynamic text is escaped by HappyX; dynamic attribute values are escaped before they enter the tree.

## Run

Install [Nim and Nimble](https://nim-lang.org/install.html), a C compiler, and OpenSSL. On macOS, Homebrew's `nim` and `openssl@3` packages work.

From this directory:

```sh
nimble --nimbleDir:.nimble --accept install --depsOnly
nimble --nimbleDir:.nimble build
./bin/arxiv_search
```

Open **http://127.0.0.1:5000**. Dependencies stay in the project's `.nimble` directory. The checked-in lockfile pins dependency revisions; it records numeric versions for HappyX's commit-based dependencies so Nimble correctly resolves their installed source directories.

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

## API behavior

Following the [arXiv API manual](https://info.arxiv.org/help/api/user-manual.html#detailed_examples), the application parses Atom metadata, honors pagination and sort parameters, and handles API errors returned inside Atom feeds as well as HTTP failures.

The standard HappyX async server runs one process-local request queue. Requests to arXiv are serialized with at least **three seconds between completed requests and the next request**, have a **20-second upstream timeout**, and are cached in memory for **24 hours** (up to 128 searches/pages). Queued identical searches reuse the preceding response. At most eight searches can wait or run at once; overflow receives an actionable 503 response. Cache hits return immediately. The UI caps pagination at arXiv's first 30,000 matches and encourages refining broad searches.

Cache and pacing are process-local. Run a single instance for this standalone application; multiple production replicas would need shared rate limiting and caching. Restarting the process clears the cache. The application performs live network requests only after a search is submitted.

## Verify

```sh
nimble --nimbleDir:.nimble test
```

Tests cover query fields and phrases, Boolean grouping, ID versions, dates, URL encoding, pagination, Atom namespaces and metadata, empty/error feeds, HTML escaping, and safe paper links. A local HTTP fixture server verifies caching, concurrent duplicate searches, request pacing, upstream failures, timeout, and recovery without depending on arXiv availability. These integration tests require permission to bind a loopback port.

`GET /health` returns `ok` without contacting arXiv.

## Files

| Path | Purpose |
| --- | --- |
| `src/arxiv_search.nim` | HappyX routes and HTTP responses |
| `src/arxiv.nim` | Query validation, URLs, models, Atom parsing |
| `src/arxiv_client.nim` | Async HTTP, caching, pacing, and errors |
| `src/views.nim` | Escaped, accessible server-rendered page |
| `public/` | Responsive styles and small progressive enhancements |
| `tests/` | Unit and HTTP integration tests; synthetic fixtures |

Framework reference: [HappyX documentation](https://hapticx.github.io/happyx/). This is an independent interface and is not affiliated with arXiv.

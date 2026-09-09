# Project Turncoat investigations

The earlier graph foundation is now integrated with the research UI in one
`turncoat` executable. The SQLite schema, canonical records, dataset isolation,
Grim traversal and JSONL import/export are reused. No university requests occur.

## First investigation

1. Search patents, including an institution assignee preset.
2. Click **Investigate** on a patent, such as `US20230050445A1`.
3. The graph opens immediately and a token-protected POST starts a background
   task. The selected patent and investigation are saved before retrieval.
4. The existing Google Patents adapter loads the full patent's inventor and
   original-assignee metadata. Search-result snippets alone are not used to
   infer all inventors.
5. Individual inventor names are queried with Google's `inventor` parameter
   and arXiv's quoted `au:` field. Assignees are displayed but never searched as
   individual inventors. Queries carry no inherited university or topic filter.
6. Each response is saved atomically with its candidate links. The browser polls
   local progress every 900 ms and merges nodes into the existing D3 simulation.
7. Select a patent to retrieve its inventors and search them; select a paper to
   search its listed authors; select a name to search it directly. Further
   recursion is explicit, through **Search related names**. **Load saved
   neighbors** and double-click only traverse the local graph.

The defaults are one automatic expansion, twelve names per selected record,
ten results per provider/name (first page), 40 provider operations over the
whole investigation, at most 500 nodes and 1,000 relationships, and one active
investigation operation per app. The graph CLI's smaller node/edge limits also
apply. These are not exhaustive searches. Query properties retain provider
totals and `hasMore`; remaining names can be selected individually. A new
investigation gets a separate budget and dataset.

The two existing clients retain their independent three-second request spacing,
20-second timeouts and daily in-memory response caches. A cached operation still
counts against the investigation budget, so the counter is an upper bound on
actual network requests. Completed name queries are reused from SQLite across
restarts. Failed queries can be retried by explicit expansion; there are no
automatic network retries. One provider's failure leaves the other's data
available and marks the operation partial. Stop prevents further work and
discards results of already in-flight calls; those calls may take until their
timeout to release the worker. Closing the browser leaves the worker running.

## Names and evidence

Names are source text, not person identifiers. No fuzzy matching, identity
scoring, affiliation inference, semantic analysis or LLM extraction is performed.
The patent's English Google page may already supply Latin-script inventor names.
These remain provider metadata; the app does not claim to have translated them.
Chinese names remain searchable as retrieved. **Search spelling** allows a known
Latin spelling or another explicit variant; its query edge is marked
`user supplied spelling`, and `originalName` is never replaced. No third-party
translation API or automatic transliteration is included in this first pass.

Every name mention is scoped to a source document and role. Two documents listing
the same name have separate mention nodes. Exact provider/name queries share a
query node inside an investigation to prevent cycles and repeated requests.
Patents deduplicate by publication number; papers by the returned arXiv ID,
including its version. Nothing is merged across investigation datasets.

| Node / edge | Meaning |
| --- | --- |
| Investigation | Seed, persistent progress, bounded activity log, limits |
| Patent / Paper | Provider identifier, URL, retrieval time, parsed provider record |
| Name mention | Original name, role, source document, unresolved identity |
| Assignee | Organization or other assignee string explicitly listed by Google |
| Name search | Exact name, provider/field, query URL, totals, state and errors |
| `lists_inventor`, `lists_author`, `lists_assignee` | Explicit source metadata |
| `searched_name` | The name or user-supplied spelling used for a query |
| `name_search_hit` (dashed) | Publication returned by the provider's name search |

Source metadata links say what the document lists. A dashed result link does
**not** establish that the result belongs to the seed inventor or university.
Parsed records are preserved in `providerRecord`; Google patent detail records
also preserve the decoded original Dublin Core meta attributes in `raw_metadata`.
Full patent HTML, PDF contents and raw Atom bodies are not archived here.

An institution's **arXiv name mentions** link uses a quoted `all:` query, for
example `all:"Harbin Institute of Technology"`. This searches indexed metadata,
not every PDF's affiliation lines. It is different from the new inventor
investigation's `au:"Name"` query. Neither is a verified institution roster.
See the [arXiv query documentation](https://info.arxiv.org/help/api/user-manual.html#query_details).

## Storage and endpoints

The default database remains `data/app.db`; configure `TURNCOAT_DB` or `--db:PATH`.
Each investigation owns an `inv-<random hex>` dataset. OIDs include this dataset
prefix, kind and a hash of the provider key. Progress is a canonical Investigation
node with `schema: turncoat/investigation/v1`; no second SQL schema is introduced.
Restart marks unfinished jobs interrupted without making provider requests.
Open a saved investigation or expand a node to continue. The sidebar shows the
30 most recent investigations; older data remains available in the dataset list
and via a saved investigation URL. JSONL export includes progress and evidence.

| Method | Path | Behavior |
| --- | --- | --- |
| GET | `/graph` | Shared graph UI; accepts `?patent=ID` or `?investigation=ID` |
| POST | `/api/investigations` | `{ "publication": "US20230050445A1" }` → 202 and ID |
| GET | `/api/investigations` | Recent saved investigations |
| GET | `/api/investigations/{id}` | Persistent progress and `{nodes, links}` snapshot |
| POST | `/api/investigations/{id}/expand` | `{ "node": "oid", "spelling": "optional" }` |
| POST | `/api/investigations/{id}/cancel` | Stops further discovery |

Writes require `X-Turncoat-Token` from the graph page's meta tag. The token rotates
on restart. Existing read-only graph endpoints, `/api/patents/*`, search routes,
institution management and graph CLI commands remain available in the same app.

## Validation

`nimble test` includes provider fixtures, university parser fixtures, graph/storage
tests and investigation tests. `nimble testInvestigations` runs the new loopback
HTTP/SQLite tests alone; `nimble testGraphHttp` builds `turncoat` and tests the
combined CLI and server, including write-token and request validation.
Normal tests never contact Google, arXiv or university hosts.

Browser verification uses the local fixture provider on 5011, a separate app on
5010 and a temporary database. It exercises the patent button, incremental
arrivals, saved reopening, node expansion, stop, desktop/mobile rendering and
browser security errors. Synthetic fixture results are not live research claims.

Google's website search endpoint is undocumented and may return 403/429/503 or
change markup. A blocked or unavailable source is surfaced in the activity
stream; no authentication, bot protection or access controls are bypassed.

# Local graph foundation

This records the original foundation work. Its storage, API and D3 components
are now integrated into the single Project Turncoat app; see
[the investigation integration](turncoat-investigations.md) for current behavior.

The user's supplied specification is the approved scope. This adds `graphapp`
alongside the existing research executable; existing source collectors are not
part of the graph service. No collection, entity resolution, scoring, or AI work.

## Inspected APIs and differences

- HappyX 4.7.4 is already installed and used here. Its route syntax is
  `/api/{dataset}/node/{oid}`, not Express-style `:dataset`; runtime host/port
  and `statusCode`/JSON responses are supported. Use its standard async server.
- ebran/grim 0.3.1 supports explicit string OIDs, `newGraph`, `addNode`,
  `addEdge`, and directional neighbor iteration. It uses boxed properties,
  not `JsonNode`; the adapter will preserve canonical JSON behind a private
  representation. Grim requires YAML and zero_functional transitively.
  Compilation confirmed three compatibility constraints: pin NimYAML 0.16.0
  (current YAML removed the top-level hint exports); use target-specific refc
  (old YAML uses shallowCopy); invoke the node-level closure iterator explicitly
  (the graph-level template's implicit iterator invocation fails on Nim 2.2).
  The iterator only reads local adjacency tables; its missing gcsafe annotation
  is handled narrowly inside the adapter. No installed dependencies are patched.
- nim-lang/db_connector 0.1.0 is the official extracted Nim database library.
  `prepare` and `bindParam` provide real SQLite parameter binding; the ordinary
  `sql`/varargs overload uses textual formatting. Use prepared statements with
  explicit lifetime management. SQLite is a system shared library.
  The final driver uses that package's SQLite C API (prepare_v2, bind_text,
  step, finalize), ensuring statement cleanup happens exactly once on failure.
- D3 7.9.0 will be checked in with its license and embedded with static assets.

Sources: [Grim](https://github.com/ebran/grim),
[HappyX](https://github.com/HapticX/happyx),
[db_connector](https://github.com/nim-lang/db_connector).

## Decisions

1. Canonical records have generic labels, globally unique string OIDs, and JSON
   object properties; recursive key sorting makes serialization deterministic.
2. Dataset ownership lives in indexed `dataset` columns, outside portable records.
   One record belongs to one dataset in this first schema. Global OID conflicts
   across datasets are rejected, including node/edge collisions. Composite foreign
   keys require both edge endpoints in the edge's dataset. A future combined view
   can union dataset selections; shared memberships require a later migration.
3. Versioned schema initialization, JSON CHECK constraints, foreign keys, WAL,
   and transactionally maintained FTS5. Search extracts all nested string values
   generically; callers can substitute an extractor. Search is literal token AND,
   ordered by OID, with no entity scoring. FTS5 is optional and its absence explicit.
4. JSONL is line streamed and bounded per record. Import uses two file passes
   (nodes then edges) and batches; duplicate OIDs upsert within a dataset. Completed
   batches survive an error; the current batch rolls back and the CLI reports the
   line and committed record counts. Export streams nodes then edges by OID.
5. SQLite selects bounded BFS working sets. Grim receives nodes before edges and
   stays inside `graph/`. Canonical records feed a separate D3 DTO. Depth, per-node
   relationships, and overall node/edge caps prevent unbounded working sets.
6. Neighbor and edge endpoints paginate relationships and report exact incident
   totals. Subgraphs report per-expansion totals plus graph budget/depth metadata;
   no expensive unbounded count of the full reachable graph.
7. A local HappyX service owns one SQLite connection. Read-only API routes expose
   generic datasets/search/records/graph DTOs and validated limits. The browser
   progressively merges IDs, preserves simulation positions, and exposes Load more.

## Implementation and validation sequence

Canonical models and storage → JSONL and fixture → bounded Grim adapter/traversal
→ API and CLI → offline D3 UI → automated tests and README. Build both executables;
run graph unit/integration tests plus existing tests; exercise CLI init/import/
export/re-import and HTTP statuses; use a browser for search/seed/expand/inspect,
deduplication, dataset switching, and error/truncation visibility.

## Verification completed

- Nim 2.2.10: both executables build through Nimble.
- Fresh temporary checkout: downloaded locked dependencies into a new cache,
  generated compiler paths, built both executables, initialized the default
  database and imported/statted the synthetic fixture successfully.
- 25 graph tests and five CLI/HTTP tests pass; the existing full fixture suite
  also passed. HTTP checks cover encoded OIDs and failure on an occupied port.
- Headless Chrome: search, seed, inspect, expand, relationship pagination,
  deduplication, pause and clear verified; no external asset/API requests.
- JSONL export/import into another SQLite file reproduces the exported bytes.
- Only the graph target uses refc; existing application configuration is preserved.

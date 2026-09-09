# Future parser interface

Parsers emit canonical records from model/graph_record. They own source-specific
identifier generation and normalization, and must choose stable globally unique
string OIDs. Labels and JSON property keys are open-ended.

The graph application has no source collectors. Existing research/faculty
modules elsewhere in this repository are separate and are not imported by it.

An iterator is sufficient; no inheritance or framework registration is required:

~~~nim
import std/json
import model/graph_record
import storage/sqlite

iterator fixtureRecords(): GraphRecord =
  yield GraphRecord(kind: nodeKind,
    node: NodeRecord(oid: "fixture:item:1", label: "Example",
      properties: %*{"name": "Synthetic example"}))

let store = openStore("data/app.db")
defer: store.close()
store.transaction:
  store.ensureDataset("fixture")
  for record in fixtureRecords():
    case record.kind
    of nodeKind: store.upsertNode("fixture", record.node)
    of edgeKind: store.upsertEdge("fixture", record.edge)
~~~

Supply nodes before their referencing edges when writing directly to SQLite.
Use batches (for example 500 records), avoiding a transaction per input record.
Every endpoint must belong to the edge's dataset. A duplicate OID in the same
dataset updates the record; reusing an OID from another dataset is rejected.
Node and edge OIDs share one global namespace.

For arbitrary ordering or long-running collection, write canonical JSONL using
storage/jsonl.writeNode/writeEdge and then importGraph. Import performs two
streaming file passes, nodes before edges. Streams are not loaded all at once.
See the root README for size limits, failure behavior and the JSONL schema.

Records carry JSON object properties, not serialized JSON strings. Names,
aliases, provenance URLs, timestamps and arbitrary nested values can be placed
there without changing storage code. Validate records before persistence, and
include provenance in future parsers. Dataset membership is supplied separately
to persistence/import, not encoded as a UI field or buried inside properties.

Do not import HappyX, D3 DTOs, or Grim into a parser. Export the same records for
CLI analysis or archival use. Source collection, entity resolution, scoring,
and LLM pipelines are future work.

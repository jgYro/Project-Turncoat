# Investigation sharing

Open a saved investigation and choose **Share investigation → Create link & copy**.
The URL opens a read-only snapshot on the same Turncoat server. The dialog can
also copy or revoke previous links. Later searches, node edits and reports do not
change an existing snapshot; create a new link to share updated work.

A snapshot contains the saved nodes, directed edges, investigation metadata,
source properties, and optionally the latest keyword scan and latest AI review
for each document, including their evidence extracts. It contains no PDF binaries,
chat conversations, API keys or workspace form token. The viewer supports graph
zoom, node inspection and a JSON download, with no provider or LLM requests.
Source hyperlinks open their original public source when clicked.

Snapshots persist in SQLite schema v3. Each link uses 32 random bytes encoded as
hex. Revocation deletes that snapshot without touching source records or reports;
previously downloaded copies cannot be recalled. Graph JSONL exports remain
graph-only; the snapshot JSON uses `turncoat-share-v1` and is not a JSONL import.

Bounds: 2000 nodes, 5000 edges, and 8 MB per snapshot. Graphs over the bounds are
rejected. Up to 100 latest reports are included within the byte budget; the
returned/viewed snapshot explicitly counts omitted reports. No graph is silently
truncated. The owner can exclude reports using the checkbox.

| Route | Behavior |
| --- | --- |
| POST /api/shares/create | Owner form token; dataset and includeReports |
| POST /api/shares/list | Owner form token; dataset |
| POST /api/shares/revoke | Owner form token; dataset and token |
| GET /shared/:token | Read-only viewer shell |
| GET /shared/:token/data | Immutable JSON or 404 after revocation |

The shared page uses no-store caching, no-referrer, and noindex headers. Rendering
uses DOM text nodes; source/model strings are never inserted as HTML.

## Reachability and access

The app still defaults to a trusted local workspace on 127.0.0.1. Creating a link
does not host or tunnel the server. A colleague needs a reachable deployment of
that same server; localhost addresses point to their own computer.

The snapshot viewer is read-only, but the full Turncoat app does not yet have
workspace authentication. A share token does not restrict access to other routes
if the entire app is exposed. For untrusted recipients, put a proxy in front of
the server that exposes only `/shared/`, the required static assets and favicon;
keep workspace pages and `/api/` private or authenticated. This feature does not
automatically configure network exposure or access controls.

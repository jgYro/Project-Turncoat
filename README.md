# Project Turncoat

Research and patent evidence is scattered across publications, search results,
and disconnected records. Analysts need a way to follow those connections while
keeping the original sources and uncertainty visible.

Turncoat brings arXiv papers, Google Patents records, document review, and a saved
investigation graph into one local workspace. The hackathon use case is mapping
the research behind hypersonic industrial-base development. The current prototype
supports evidence discovery and review; trade-data ingestion, verified identity
resolution, and supply-chain prediction remain future work.

## What you can do

- **Find research:** search papers and patents by topic, author, inventor, or
  institution preset, then open the source record and PDF.
- **Follow connections:** investigate a patent, search its inventor names across
  both providers, and explore saved relationships in an interactive graph.
- **Review evidence:** screen documents with English/Chinese keyword rules and
  request AI reviews with source quotations. PDF text extraction and local OCR
  support document review.
- **Keep and share work:** save investigations in SQLite, export graph JSONL,
  download review results, or create a revocable, read-only snapshot link.

Name-search results are candidates, not verified identities. AI interpretations
remain separate from source records. Saved graphs work offline; new searches
contact the providers, and AI reviews use the configured inference endpoint.
Sharing requires access to the same Turncoat server.

## Slides

[View the slides (PDF)](<Project Turncoat_ Mapping the Adversary's Hypersonic Industrial Base.pdf>)
or [open the PowerPoint](<Project Turncoat_ Mapping the Adversary's Hypersonic Industrial Base.pptx>).

- **Slide 1:** the fragmented-source problem and mission.
- **Slide 2:** the software stack and 23 pinned Nim dependencies.
- **Slide 7:** the proposed analytics and supply-chain roadmap.

The deck includes future capabilities; the working features are described above.

## Run locally

Prerequisites: Nim 2.2.x, Nimble, a C compiler, Git, OpenSSL, and SQLite with JSON
support (FTS5 enables graph search). The application uses Nim/HappyX with bundled
browser assets; no frontend build step is required.

```sh
nimble --nimbleDir:.nimble --useSystemNim --accept install --depsOnly
nimble --nimbleDir:.nimble --useSystemNim setup
nimble --nimbleDir:.nimble --useSystemNim build

./bin/turncoat init
./bin/turncoat import demo tests/fixtures/graph/demo.jsonl
./bin/turncoat serve
```

Open **http://127.0.0.1:5000** to search, or **http://127.0.0.1:5000/graph** and
select **demo** for a fictional investigation graph. For a live investigation,
search patents and select **Investigate** on a result.

The default database is `data/app.db`. Keep the checked-in `nimble.lock` when
installing dependencies; NimYAML 0.16.0 is intentionally pinned for Grim
compatibility. Optional document extraction uses Poppler and local Docling;
AI review requires an OpenAI-compatible endpoint such as local Ollama.

## SBOM and Nash scan results

The saved **September 9, 2026** directory scan includes the project, bundled
dependency caches, and local environment files. Each finding retains its source
path; cached copies are not assumed to be dependencies of the root project.

| Evidence | Recorded result |
| --- | --- |
| Root project | `arxiv_search` 0.1.0; executable `turncoat` |
| Root Nim lockfile | 23 packages with versions, repository URLs, Git revisions, and checksums |
| Full directory | 43,958 entries; 37,611 regular files hashed |
| Full directory BOM | 219 components, including cached manifests and dependency declarations |
| Inventory and selected parsers | Complete; no diagnostics; independent file hashes matched |
| Vulnerability evaluation | Incomplete; zero findings do not establish a vulnerability-free project |

- [CycloneDX SBOM](sbom.cdx.json): the standalone BOM from the scan.
- [Full Nash scan result](nash-scan-results.json): the BOM, file inventory,
  hashes, parser status, diagnostics, and vulnerability-query results.

Nash refreshed its internal NVD corpus before querying. Nimble advisory coverage
is not configured, many manifest declarations do not specify a resolved version,
and the root lockfile does not pin the Nim compiler. These remain unresolved;
the compiler requirement `nim >= 2.2.0` is not an installed-version measurement.
This snapshot predates the slide files and this README/report update.

To repeat the scan, use a Nash build that includes `scan directory`. With Nash on
PATH and its PostgreSQL/Memgraph configuration loaded, run from this directory:

```sh
nash scan directory --source "$PWD" --workers 10 > /tmp/turncoat-nash-scan.json
jq '.bom' /tmp/turncoat-nash-scan.json > /tmp/turncoat-sbom.cdx.json
```

`10` is the caller-selected worker count. Add `--vulnerabilities=false` for a
directory inventory and SBOM without database or advisory-network access.
Write new results outside the scanned directory; later scans will include any
previously saved reports and other files added since this snapshot.

## Guides

- [Investigations and evidence semantics](docs/turncoat-investigations.md)
- [Document review, keyword screening, and saved reports](docs/graph-drilldowns.md)
- [Chat and inference configuration](docs/llm-chat.md) · [PDF extraction and OCR](docs/document-extraction.md)
- [Sharing and deployment scope](docs/investigation-sharing.md)
- [Patent API](docs/patents-api.md) · [Separate faculty collection library](docs/faculty.md)
- [Graph architecture](docs/graph-implementation-plan.md) · [Dependency lockfile](nimble.lock)

Existing fixture tests can be run with
`nimble --nimbleDir:.nimble --useSystemNim test`. See the guides for provider
limits, extraction scope, configuration, and focused verification commands.

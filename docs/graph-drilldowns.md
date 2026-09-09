# Graph drill-downs and evidence screening

## Behavior

The graph remains a permanent workspace tab. Right-click an author/name mention,
paper, or patent and choose **Drill down**. The inspector also offers the action
for touch and keyboard use. Tabs are scoped to a dataset and node, deduplicated,
closable, and restored in this browser tab's session. Returning to Graph preserves
the canvas and camera. No design mock was supplied; use the existing IBM Plex theme.

Author tabs show saved source-listed documents and name-search candidates in a
table, with their different evidence bases intact. Pagination reads SQLite.
**Search both providers** explicitly invokes the existing bounded investigation;
opening a tab never issues Google Patents/arXiv searches. There is no identity
resolution or inference of institutional affiliation.

Document tabs automatically prepare PDF context with a visible readiness/error
state and retry control. Keyword scans include it by default, and AI reviews
require it. Preparation alone never runs inference or saves a report.

AI findings and limitations use the same safe Markdown renderer and typography
as chat. Citation cards preserve literal quotation text, link to the source/PDF,
and show whether the quoted passage was located. Unverified findings remain
readable with a distinct label; their raw JSON is collapsed by default. Shared
snapshots use the same presentation without workspace actions.

Document tabs provide literal keyword screening, PDF viewing, and preset AI
reviews. The starter vocabulary has English and Chinese terms grouped into direct
military terms, potentially relevant dual-use categories, and broad context terms.
Version 2 adds EMI/radar, AI/LLMs, red teaming and vulnerability vocabulary. Users may add a
literal search phrase to a scan. Terms are indicators, not proof of military use.
For example, carbon fiber alone is tagged as a dual-use material. No fuzzy matching,
translation, embeddings, or identity scoring is performed.

Keyword matches retain the original matched text, field, UTF-8 byte offsets, and
an excerpt. Matching ignores ASCII case and uses word boundaries for Latin terms;
Chinese phrases match exactly. PDF extraction retains the existing first-40-page,
32000-byte limit. Local Docling OCR handles scanned PDFs when embedded text is
unavailable; the report identifies the extraction method. Missing PDF text is
explicit; metadata-only scans remain possible.
AI reviews require PDF text and run only after a button click. Presets cover broad
wartime relevance, kinetic warfare references, missile supply-chain relevance, and
dual-use materials. Reviews separate direct references from potential indirect
relevance, with alternative civilian interpretations and missing evidence.

AI output is interpretation. Each finding must include a quote and source field.
The server checks whether the quote occurs in the supplied evidence; locating a
quote does not validate the model's interpretation. Unlocatable quotes and invalid
structured replies remain visible as unverified output and never become keyword
tags or source facts. Reviews stay at the level of evidence and technology
categories, without design, targeting, or weapon optimization guidance.

## Storage and implementation

Nim modules under `src/analysis/` own the vocabulary, matching, prompts, and report
validation. A storage module handles saved author relationships and analysis
reports using the existing bound SQLite driver. Schema version 2 adds a report
table with dataset/node foreign keys. Raw graph node properties remain untouched.
Reports include their evidence snapshot, content fingerprint, rule/prompt version,
query, model when applicable, timestamp, and extraction scope. Closing a tab does
not delete a report. Graph JSONL export remains graph-only; report JSON can be
downloaded from the document tab.

**Settings** lists the active keyword rules and every literal alias, exact preset
AI query, and shared review instructions. A separate Provider searches section
shows saved name queries, provider links, states, counts, and timestamps, filterable
by dataset. Settings is a read-only inspection page; viewing it does not run a
provider query or an AI review.

The HappyX API validates dataset membership, request sizes, and the existing form
token. The client reuses current PDF limits and LLM concurrency/timeouts. There are
no automatic LLM retries. UI state lives in `public/drilldowns.js` and its styles;
the D3 canvas only supplies selected node/context-menu events.

## Validation

Fixture tests cover literal matching, Chinese text, boundaries and offsets,
direct/indirect separation, citation validation, schema migration, report
persistence/isolation, and saved relationship traversal. Browser checks cover
context menus, keyboard/touch alternatives, tab lifecycle/camera preservation,
author tables, source-specific document actions, errors, and mobile scrolling.
Provider and model responses are synthetic in normal tests.

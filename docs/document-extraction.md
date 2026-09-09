# PDF text and Docling OCR

The application and HTTP integration remain Nim. IBM-originated
[Docling](https://docling-project.github.io/docling/) runs as a local CLI helper.
It receives only the PDF already retrieved through the existing source adapter.
PDFs are not uploaded to a conversion service.

Opening a document reader, document chat (including a saved paper/patent from
the graph), or document screening tab automatically prepares its PDF context.
The UI shows preparation, readiness and extraction failures with a retry action.
New document chats and keyword scans include the PDF by default; the checkbox
is an explicit metadata-only option. Existing conversations retain their chosen
attachment scope. AI reviews require PDF text; the general AI Analysis button
can fall back to a clearly labeled metadata-only review when extraction fails.
Opening or refreshing a view prepares evidence without sending an AI prompt.

`PDF_TEXT_ENGINE=auto` (default) first uses Poppler's embedded text. If text is
unavailable, it tries Docling with full-page OCR. Set `PDF_TEXT_ENGINE=docling`
to use Docling for every PDF, including mixed scanned/text documents. `poppler`
retains the text-only path. Restart the app after changing environment settings.

Install the pinned helper in the project directory:

```sh
uv venv --python 3.12 .docling-venv
uv pip install --python .docling-venv/bin/python -r docling-requirements.txt
.docling-venv/bin/docling-tools models download layout tableformer --output-dir .docling-models
```

The local `.docling-venv/bin/docling` and `.docling-models` are detected automatically. `DOCLING_BIN`
can point to another installed executable. Docling downloads model weights on
first use; prefetch them before processing documents offline. Use
`DOCLING_ARTIFACTS_PATH` for a predownloaded model directory.
If the Hugging Face Xet transfer stalls, retry model prefetch with
`HF_HUB_DISABLE_XET=1` to use its standard HTTP downloader.

macOS defaults to `DOCLING_OCR_ENGINE=ocrmac` and
`DOCLING_OCR_LANG=en-US,zh-Hans` using Apple's local OCR. Other platforms default
to RapidOCR (`rapidocr`, language `ch`, covering Chinese and English). Install
the relevant OCR backend if changing engines; see the
[Docling CLI reference](https://docling-project.github.io/docling/reference/cli/).
No automatic translation is performed. OCR output is recognized text and may
differ from the original printed characters.

Both paths retain the first-40-page, 32000-UTF-8-byte evidence limit. Poppler has
a 20-second processing deadline; Docling has five minutes, with four CPU threads
and one active PDF operation per app process. Concurrent requests for the same
document share extraction; different documents enter a FIFO queue with at most
eight waiting operations and a six-minute waiting deadline. Models load in each CLI process.
Results are cached in memory until restart. Temporary PDF and extraction files
are removed when the document client closes. Keyword/AI reports separately save
the extracted evidence and its method/scope in SQLite.

The returned `scope` identifies embedded text or Docling OCR. Quotations and byte
offsets refer to that extracted text. OCR may misread names, formulas or tables;
locating a quotation does not prove faithful transcription. Neither path performs
picture interpretation. In automatic mode a mixed PDF with some embedded text
may need `PDF_TEXT_ENGINE=docling` to capture its scanned portions.

`GET /api/documents/config` reports the configured mode, helper availability,
OCR engine and bounds. Settings → AI queries links to this guide. Normal unit
tests use a synthetic CLI fixture; real Docling validation is a separate local
smoke test so normal tests do not download models.

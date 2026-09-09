## In-app source reader and bounded PDF text extraction. Never accepts arbitrary URLs.
import std/[asyncdispatch, httpclient, httpcore, json, strutils, uri, tables,
  os, osproc, tempfiles, times, monotimes, unicode]
import checksums/sha1
import arxiv, arxiv_client, patents, patents_client
import bounded_http
import docling_extract
import storage/sqlite

const
  MaxPdfBytes* = 16_000_000
  MaxPdfTextBytes* = 32_000
  PdfPageLimit* = 40

type
  DocumentEntry = ref object
    record: JsonNode
    pdfPath, text, extractionMethod: string
    textLoaded: bool
    pdfPending: Future[string]
    textPending: Future[JsonNode]
  DocumentClient* = ref object
    arxiv: ArxivClient
    patents: PatentsClient
    entries: OrderedTable[string, DocumentEntry]
    directory: string
    active: bool
    waiters: seq[Future[void]]
    nextPdf: MonoTime
    pdfOrigin: string # Explicit loopback fixture seam; never accepted from a request.

proc documentId*(source, id: string): string =
  case source
  of "patents": result = publicationId(id)
  of "arxiv":
    if id.len == 0 or id.len > 80 or ".." in id or id[0] == '/' or id[^1] == '/':
      raise newException(ValueError, "Invalid arXiv identifier.")
    for ch in id:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '-', '/'}:
        raise newException(ValueError, "Use an arXiv identifier, not a URL.")
    if id.count('/') > 1: raise newException(ValueError, "Invalid arXiv identifier.")
    result = id
  else: raise newException(ValueError, "Document source must be patents or arxiv.")

proc validPdfUrl*(url: string): bool =
  let parsed = parseUri(url)
  parsed.scheme == "https" and parsed.hostname in ["arxiv.org", "export.arxiv.org", "patentimages.storage.googleapis.com"] and
    parsed.username.len == 0 and parsed.password.len == 0 and parsed.port in ["", "443"] and
    parsed.query.len == 0 and parsed.anchor.len == 0 and
    (parsed.path.startsWith("/pdf/") or (parsed.hostname == "patentimages.storage.googleapis.com" and parsed.path.endsWith(".pdf")))

proc newDocumentClient*(arxiv: ArxivClient; patents: PatentsClient; pdfOrigin = ""): DocumentClient =
  if pdfOrigin.len > 0:
    let parsed = parseUri(pdfOrigin)
    if parsed.scheme != "http" or parsed.hostname != "127.0.0.1":
      raise newException(ValueError, "PDF fixture origin must use loopback HTTP.")
  DocumentClient(arxiv: arxiv, patents: patents, directory: createTempDir("turncoat-docs-", ""), pdfOrigin: pdfOrigin)

proc close*(client: DocumentClient) =
  if dirExists(client.directory): removeDir(client.directory)

proc metadata*(client: DocumentClient; source, identifier: string): Future[JsonNode] {.async.} =
  let id = documentId(source, identifier)
  let key = source & ":" & id
  if key in client.entries: return client.entries[key].record
  var record: JsonNode
  if source == "patents":
    let data = await client.patents.lookup(id)
    record = %*{"source": source, "id": id, "title": data{"title"}.getStr,
      "authors": data{"inventors"}, "abstract": data{"abstract"}.getStr,
      "sourceUrl": data{"url"}.getStr, "pdfUrl": data{"pdf_url"}.getStr,
      "providerRecord": data}
  else:
    var options = defaultOptions()
    options.query = id; options.field = "id"
    let data = await client.arxiv.search(options)
    var found = false
    for paper in data.papers:
      if paper.id == id or (not id.contains('v') and paper.id.startsWith(id & "v")):
        found = true
        record = %*{"source": source, "id": paper.id, "title": paper.title,
          "authors": paper.authors, "abstract": paper.summary,
          "sourceUrl": "https://arxiv.org/abs/" & paper.id,
          "pdfUrl": "https://arxiv.org/pdf/" & paper.id, "providerRecord": %paper}
        break
    if not found: raise apiError("This paper was not returned by arXiv.", 404)
  if client.entries.len >= 16:
    # In-flight PDF extraction keeps its entry alive; do not evict it.
    if client.active: raise apiError("Document cache is busy. Try again after the PDF finishes.", 503)
    for oldest, entry in client.entries:
      if entry.pdfPath.len > 0 and fileExists(entry.pdfPath): removeFile(entry.pdfPath)
      client.entries.del(oldest)
      break
  client.entries[key] = DocumentEntry(record: record)
  return record

proc savedMetadata*(client: DocumentClient; store: GraphStore; source, identifier, dataset, oid: string): JsonNode =
  let id = documentId(source, identifier)
  let node = store.getNode(dataset, oid)
  if node.isNone: raise apiError("The saved document was not found in this dataset.", 404)
  let properties = node.get.properties
  let data = properties{"providerRecord"}
  if data == nil or data.kind != JObject:
    raise newException(ValueError, "This node has no saved source document.")
  let sourceUrl = if source == "patents": "https://patents.google.com/patent/" & id & "/en" else: "https://arxiv.org/abs/" & id
  if properties{"sourceUrl"}.getStr != sourceUrl:
    raise newException(ValueError, "The selected node does not match this document.")
  var authors = if source == "arxiv": data{"authors"} else: data{"inventors"}
  if authors == nil or authors.kind != JArray:
    authors = newJArray()
    if data{"inventor"}.getStr.len > 0: authors.add(%data{"inventor"}.getStr)
  let text = if source == "arxiv": data{"summary"}.getStr else: data{"abstract"}.getStr(data{"snippet"}.getStr)
  let pdf = if source == "arxiv": "https://arxiv.org/pdf/" & id else: data{"pdf_url"}.getStr
  result = %*{"source":source, "id":id, "title":data{"title"}.getStr(properties{"title"}.getStr),
    "authors":authors, "abstract":text, "sourceUrl":sourceUrl, "pdfUrl":pdf,
    "providerRecord":data, "savedRecord":true,
    "recordScope":(if source == "patents" and not properties{"detailLoaded"}.getBool:
      "Saved search metadata; inventor names and abstract may be incomplete."
      else: "Saved source metadata from the selected graph record.")}
  let key = source & ":" & id
  # A saved record seeds the PDF reader without another provider lookup.
  if key notin client.entries:
    if client.entries.len >= 16:
      if client.active: raise apiError("Document cache is busy. Try again shortly.", 503)
      for oldest, entry in client.entries:
        if entry.pdfPath.len > 0 and fileExists(entry.pdfPath): removeFile(entry.pdfPath)
        client.entries.del(oldest)
        break
    client.entries[key] = DocumentEntry(record: result)

proc resolveMetadata*(client: DocumentClient; store: GraphStore; reference: JsonNode): Future[JsonNode] {.async.} =
  if reference.kind != JObject or reference{"source"} == nil or reference{"source"}.kind != JString or
      reference{"id"} == nil or reference{"id"}.kind != JString:
    raise newException(ValueError, "Document requests require source and id strings.")
  if reference.hasKey("node") or reference.hasKey("dataset"):
    if reference{"node"} == nil or reference{"node"}.kind != JString or
        reference{"dataset"} == nil or reference{"dataset"}.kind != JString:
      raise newException(ValueError, "Saved documents require dataset and node identifiers.")
    return client.savedMetadata(store, reference["source"].getStr, reference["id"].getStr,
      reference["dataset"].getStr, reference["node"].getStr)
  return await client.metadata(reference["source"].getStr, reference["id"].getStr)

proc download(http: AsyncHttpClient; url: string): Future[string] {.async.} =
  var current = url
  for attempt in 0..3:
    if not validPdfUrl(current): raise apiError("The source returned an unsupported PDF URL.", 502)
    let response = await http.get(current)
    if response.code.int in [301, 302, 303, 307, 308]:
      current = $combine(parseUri(current), parseUri(response.headers.getOrDefault("Location")))
      discard await response.readBoundedBody(64_000, "The PDF redirect response was too large.")
      continue
    if response.code != Http200: raise apiError("The PDF source is unavailable (HTTP " & $response.code.int & "). Metadata remains available.", 502)
    result = await response.readBoundedBody(MaxPdfBytes, "This PDF exceeds the 16 MB viewer limit.")
    if not result.startsWith("%PDF-"): raise apiError("The source did not return a PDF. Metadata remains available.", 502)
    return
  raise apiError("The PDF source redirected too many times.", 502)

proc fixtureDownload(http: AsyncHttpClient; url: string): Future[string] {.async.} =
  let response = await http.get(url)
  result = await response.body
  if response.code != Http200 or result.len > MaxPdfBytes or not result.startsWith("%PDF-"):
    raise apiError("Invalid fixture PDF.")

proc loadPdf(client: DocumentClient; entry: DocumentEntry): Future[string] {.async.} =
  if entry.pdfPath.len > 0 and fileExists(entry.pdfPath): return entry.pdfPath
  let url = entry.record{"pdfUrl"}.getStr
  if not validPdfUrl(url): raise apiError("No supported PDF is available for this document.", 404)
  let delay = (client.nextPdf - getMonoTime()).inMilliseconds
  if delay > 0: await sleepAsync(int(delay))
  let http = newAsyncHttpClient(userAgent = "ProjectTurncoat/0.1 (interactive document reader)", maxRedirects = 0)
  try:
    let pending = if client.pdfOrigin.len > 0: fixtureDownload(http, client.pdfOrigin & "/fixture.pdf") else: download(http, url)
    if not await withTimeout(pending, 30_000): raise apiError("The PDF download timed out. Try again later.", 504)
    let data = await pending
    entry.pdfPath = client.directory / ($secureHash(url) & ".pdf")
    writeFile(entry.pdfPath, data)
    return entry.pdfPath
  except ApiError: raise
  except CatchableError: raise apiError("Could not download this PDF. Metadata remains available.", 502)
  finally:
    http.close()
    client.nextPdf = getMonoTime() + initDuration(seconds = 3)

proc acquirePdf(client: DocumentClient): Future[void] {.async.} =
  # A small FIFO queue lets independent analysis tabs prepare context together.
  if not client.active:
    client.active = true
    return
  if client.waiters.len >= 8: raise apiError("The PDF preparation queue is full. Retry shortly.", 429)
  let waiter = newFuture[void]("documents.acquirePdf")
  client.waiters.add(waiter)
  if not await withTimeout(waiter, 360_000):
    for i, queued in client.waiters:
      if queued == waiter:
        client.waiters.delete(i)
        break
    raise apiError("Timed out waiting for PDF preparation. Retry when other documents finish.", 504)

proc releasePdf(client: DocumentClient) =
  if client.waiters.len == 0: client.active = false
  else:
    let next = client.waiters[0]
    client.waiters.delete(0)
    next.complete()

proc preparePdfFile(client: DocumentClient; entry: DocumentEntry): Future[string] {.async.} =
  await client.acquirePdf()
  try: return await client.loadPdf(entry)
  finally: client.releasePdf()

proc pdfFile*(client: DocumentClient; source, id: string): Future[string] {.async.} =
  discard await client.metadata(source, id)
  let entry = client.entries[source & ":" & documentId(source, id)]
  if entry.pdfPath.len > 0 and fileExists(entry.pdfPath): return entry.pdfPath
  if entry.pdfPending == nil: entry.pdfPending = client.preparePdfFile(entry)
  let pending = entry.pdfPending
  try: return await pending
  finally:
    if entry.pdfPending == pending: entry.pdfPending = nil

proc cachedPdfFile*(client: DocumentClient; source, id: string): string =
  let key = source & ":" & documentId(source, id)
  if key notin client.entries or client.entries[key].pdfPath.len == 0 or not fileExists(client.entries[key].pdfPath):
    raise apiError("Open this document's PDF tab to prepare the viewer first.", 404)
  client.entries[key].pdfPath

proc extractPdfText*(path: string; limit = MaxPdfTextBytes): Future[string] {.async.} =
  let binary = findExe("pdftotext")
  if binary.len == 0: raise apiError("Install Poppler (pdftotext) to read PDF text in chat. The PDF viewer and metadata still work.", 503)
  let output = path & ".txt"
  let process = startProcess(binary, args = @["-f", "1", "-l", $PdfPageLimit, "-layout", "-enc", "UTF-8", "-q", path, output], options = {})
  try:
    let deadline = getMonoTime() + initDuration(seconds = 20)
    while process.running:
      if getMonoTime() >= deadline:
        process.kill()
        raise apiError("PDF text extraction timed out.", 504)
      await sleepAsync(30)
    if process.peekExitCode != 0 or not fileExists(output): raise apiError("This PDF could not be converted to text.", 422)
    let input = open(output, fmRead)
    try:
      result = newString(limit)
      result.setLen(input.readBuffer(addr result[0], limit))
    finally: input.close()
    # Cut only at a valid UTF-8 boundary; no transliteration or whitespace rewriting.
    while result.len > 0 and validateUtf8(result) >= 0: result.setLen(result.len - 1)
    if result.strip.len == 0: raise apiError("This PDF has no extractable text. Scanned pages need OCR; metadata can still be used in chat.", 422)
  finally:
    if process.running: process.kill()
    discard process.waitForExit()
    process.close()
    if fileExists(output): removeFile(output)

proc preparePdfText(client: DocumentClient; entry: DocumentEntry): Future[JsonNode] {.async.} =
  if not entry.textLoaded:
    await client.acquirePdf()
    try:
      let path = await client.loadPdf(entry)
      let engine = getEnv("PDF_TEXT_ENGINE","auto")
      if engine notin ["auto","docling","poppler"]: raise apiError("PDF_TEXT_ENGINE must be auto, docling, or poppler.",503)
      if engine=="docling":
        entry.text = await extractWithDocling(path)
        entry.extractionMethod = "Docling OCR"
      else:
        try:
          entry.text = await extractPdfText(path)
          entry.extractionMethod = "Poppler embedded text"
        except ApiError as error:
          if engine!="auto" or error.status notin [422,503]: raise
          entry.text = await extractWithDocling(path)
          entry.extractionMethod = "Docling OCR"
      entry.textLoaded = true
    finally: client.releasePdf()
  return %*{"text": entry.text, "pageLimit": PdfPageLimit, "byteLimit": MaxPdfTextBytes,
    "method":entry.extractionMethod,
    "scope": entry.extractionMethod & ": up to the first 40 pages, limited to 32000 UTF-8 bytes. Later content may be omitted. " &
      (if entry.extractionMethod=="Docling OCR":"OCR can misread text; verify quotations against the PDF. No picture interpretation." else:"Embedded text only; no picture interpretation.")}

proc pdfText*(client: DocumentClient; source, id: string): Future[JsonNode] {.async.} =
  discard await client.metadata(source, id)
  let entry = client.entries[source & ":" & documentId(source, id)]
  if entry.textPending == nil: entry.textPending = client.preparePdfText(entry)
  let pending = entry.textPending
  try: return await pending
  except CatchableError:
    # A failed preparation can be retried; simultaneous callers share its result.
    if entry.textPending == pending: entry.textPending = nil
    raise

## Drill-down orchestration. Network calls stay in the existing document/LLM clients.
import std/[asyncdispatch, json, strutils, times, sysrand]
import checksums/sha1
import keywords, reviews
import ../documents
import ../llm/client
import ../storage/[sqlite, analysis_store]
export keywords, reviews, analysis_store

proc stringField(body: JsonNode; key: string; optional = false): string =
  if body.kind != JObject: raise newException(ValueError, "Expected a JSON object.")
  if optional and not body.hasKey(key): return ""
  if body{key} == nil or body[key].kind != JString:
    raise newException(ValueError, "Expected a string for " & key & ".")
  body[key].getStr

proc pageField(body: JsonNode; key: string; fallback: int): int =
  if not body.hasKey(key): return fallback
  if body[key].kind != JInt: raise newException(ValueError, "Invalid page parameter.")
  body[key].getInt

proc documentReference*(store: GraphStore; dataset, oid: string): JsonNode =
  let node = store.requireNode(dataset, oid)
  if node.label notin ["Paper", "Patent"]: raise newException(ValueError, "Select a saved paper or patent.")
  let source = if node.label == "Paper": "arxiv" else: "patents"
  let id = documentId(source, node.properties{if source == "arxiv": "arxivId" else: "publicationNumber"}.getStr)
  %*{"source":source, "id":id, "dataset":dataset, "node":oid}

proc snapshot*(documents: DocumentClient; store: GraphStore; reference: JsonNode;
    includePdf, requirePdf: bool): Future[JsonNode] {.async.} =
  let record = await documents.resolveMetadata(store, reference)
  var pdf = ""
  var scope = "Metadata only; PDF text is not included."
  var warning = ""
  if includePdf:
    try:
      let extracted = await documents.pdfText(reference["source"].getStr, reference["id"].getStr)
      pdf = extracted["text"].getStr
      scope = extracted["scope"].getStr
    except ApiError as error:
      if requirePdf: raise
      warning = error.publicMessage
  if requirePdf and pdf.strip.len == 0: raise apiError("PDF text is required for this review. Load an extractable PDF first.", 422)
  let fields = evidenceFields(record, pdf)
  result = %*{"reference":reference, "record":record, "fields":fields, "scope":scope, "warning":warning,
    "pdfIncluded":pdf.len>0, "fingerprint":($secureHash($fields & scope)).toLowerAscii}
  if ($result).len > 200_000: raise apiError("This source record is too large for a saved analysis snapshot.", 413)

proc baseReport(dataset, oid, kind: string; evidence: JsonNode): JsonNode =
  %*{"schema":"turncoat-analysis-v1", "id":($secureHash($urandom(24))).toLowerAscii,
    "dataset":dataset, "node":oid, "kind":kind,
    "createdAt":now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"), "evidence":evidence}

proc drilldown*(store: GraphStore; documents: DocumentClient; llm: LlmClient;
    action: string; body: JsonNode): Future[JsonNode] {.async.} =
  if action == "searches":
    return store.savedNameSearches(stringField(body,"dataset",true),pageField(body,"limit",50),pageField(body,"offset",0))
  let dataset = stringField(body, "dataset")
  let oid = stringField(body, "node")
  if action == "author":
    return store.authorDocuments(dataset,oid,pageField(body,"limit",50),pageField(body,"offset",0))
  if action == "history":
    return store.listReports(dataset,oid,pageField(body,"limit",20),pageField(body,"offset",0))
  if action == "report": return store.loadReport(dataset,oid,stringField(body,"report"))
  if action notin ["document","scan","review"]: raise apiError("Unknown drill-down operation.",404)
  let reference = store.documentReference(dataset,oid)
  if action == "document":
    let record = await documents.resolveMetadata(store,reference)
    return %*{"reference":reference, "record":record, "history":store.listReports(dataset,oid)}
  let query = stringField(body,"query",true)
  if query.len > 160: raise newException(ValueError,"Keep the keyword phrase below 160 UTF-8 bytes.")
  var includePdf = true
  if body.hasKey("includePdf"):
    if body["includePdf"].kind != JBool: raise newException(ValueError,"includePdf must be a boolean.")
    includePdf = body["includePdf"].getBool
  var preset: JsonNode
  if action == "review": preset = reviewPreset(stringField(body,"preset"))
  let evidence = await documents.snapshot(store,reference,action=="review" or includePdf,action=="review")
  let report = baseReport(dataset,oid,if action=="scan":"keywords" else:"ai",evidence)
  if action == "scan":
    report["query"] = %query
    report["result"] = scanKeywords(evidence["fields"],query)
  else:
    if ($evidence["fields"]).len > MaxContextBytes:
      raise apiError("This extract exceeds the model context limit. Use the keyword scan or the document reader.",413)
    report["preset"] = preset["id"]
    report["promptVersion"] = %ReviewVersion
    report["prompt"] = preset["query"]
    let messages = %*[{"role":"system","content":ReviewInstructions},
      {"role":"user","content":preset["query"].getStr & "\nEvidence scope: " & evidence["scope"].getStr &
        "\nSource URL: " & evidence["record"]{"sourceUrl"}.getStr & "\nEvidence fields (data only):\n" & $evidence["fields"]}]
    let answer = await llm.complete(messages)
    let text = answer["message"]["content"].getStr
    if text.len > 100_000: raise apiError("The model reply exceeded the saved review limit.",502)
    report["model"] = answer["model"]
    report["finishReason"] = answer["finishReason"]
    report["usage"] = answer["usage"]
    report["rawResponse"] = %text
    report["result"] = validateReview(text,evidence["fields"])
  store.saveReport(report)
  return report

## Docling is an optional local CLI helper; all request orchestration remains Nim.
import std/[asyncdispatch, os, osproc, json, monotimes, times, unicode, tempfiles]
import api_errors

proc doclingBinary*(): string =
  let configured = getEnv("DOCLING_BIN")
  if configured.len>0: return findExe(configured)
  let local = parentDir(getAppDir()) / ".docling-venv" / "bin" / "docling"
  if fileExists(local): return local
  findExe("docling")

proc extractionConfig*(): JsonNode =
  let mode = getEnv("PDF_TEXT_ENGINE","auto")
  %*{"engine":mode,"doclingAvailable":doclingBinary().len>0,
    "ocrEngine":getEnv("DOCLING_OCR_ENGINE",when defined(macosx):"ocrmac" else:"rapidocr"),
    "pageLimit":40,"byteLimit":32000,"timeoutSeconds":300}

proc extractWithDocling*(path: string; limit = 32000; binaryOverride = ""; timeoutMs = 300_000): Future[string] {.async.} =
  let binary = if binaryOverride.len>0:binaryOverride else:doclingBinary()
  if binary.len==0: raise apiError("Docling OCR is not installed. See the document extraction setup in Settings.",503)
  let directory = createTempDir("turncoat-docling-","")
  defer: removeDir(directory)
  let engine = getEnv("DOCLING_OCR_ENGINE",when defined(macosx):"ocrmac" else:"rapidocr")
  let languages = getEnv("DOCLING_OCR_LANG",when defined(macosx):"en-US,zh-Hans" else:"ch")
  var args = @["--from","pdf","--to","text","--output",directory,"--page-range","1-40",
    "--ocr","--ocr-engine",engine,"--ocr-lang",languages,"--ocr-mode","full_page",
    "--image-export-mode","placeholder","--num-threads","4",absolutePath(path)]
  let localArtifacts = parentDir(getAppDir()) / ".docling-models"
  let artifacts = getEnv("DOCLING_ARTIFACTS_PATH",if dirExists(localArtifacts):localArtifacts else:"")
  if artifacts.len>0: args = @["--artifacts-path",artifacts] & args
  let process = startProcess(binary,args=args,options={poParentStreams})
  try:
    let deadline = getMonoTime()+initDuration(milliseconds=timeoutMs)
    while process.running:
      if getMonoTime()>=deadline:
        process.kill()
        raise apiError("Docling OCR timed out. Try a smaller document or check the local extraction setup.",504)
      await sleepAsync(80)
    let output = directory / (splitFile(path).name & ".txt")
    if process.peekExitCode!=0 or not fileExists(output):
      raise apiError("Docling could not extract this PDF. Check its local model files and OCR language configuration.",422)
    let input = open(output,fmRead)
    try:
      result = newString(limit)
      result.setLen(input.readBuffer(addr result[0],limit))
    finally: input.close()
    while result.len>0 and validateUtf8(result)>=0: result.setLen(result.len-1)
    if result.strip.len==0: raise apiError("Docling OCR returned no readable text for this PDF.",422)
  finally:
    if process.running: process.kill()
    discard process.waitForExit()
    process.close()

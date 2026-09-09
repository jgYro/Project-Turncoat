## Explicit local smoke test; requires installed Docling and model weights.
import std/[os, asyncdispatch, json]
import docling_extract, analysis/keywords
if paramCount()!=2: quit("Usage: docling_smoke INPUT.pdf OUTPUT.json",1)
let text=waitFor extractWithDocling(paramStr(1))
let result= %*{"method":"Docling OCR","bytes":text.len,"text":text,"scan":scanKeywords(%*{"pdf":text})}
writeFile(paramStr(2),pretty(result))
echo "Extracted ",text.len," bytes; ",result["scan"]["tags"].len," keyword tags."

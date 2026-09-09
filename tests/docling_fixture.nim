## Synthetic CLI contract, not an OCR implementation.
import std/[os, strutils]
let args=commandLineParams()
let output=args[args.find("--output")+1]
let input=args[^1]
doAssert args[args.find("--page-range")+1]=="1-40"
doAssert args[args.find("--ocr-mode")+1]=="full_page"
if input.endsWith("slow.pdf"): sleep(2000)
if input.endsWith("failure.pdf"): quit(1)
createDir(output)
writeFile(output/(splitFile(input).name & ".txt"),repeat("原始中文 EMI radar vulnerabilities LLM model.\n",1000))

## Small DOM primitives. Institution selectors and label mappings live elsewhere.
import std/[xmltree, strutils, strtabs, uri]
import pkg/htmlparser
from std/unicode import validateUtf8, strip
import ../api_errors

export htmlparser, xmltree

proc htmlAttr*(node: XmlNode; key: string): string =
  if node == nil or node.kind != xnElement or node.attrs == nil: return
  for name, value in node.attrs:
    if name.toLowerAscii() == key.toLowerAscii(): return value

proc sourceText*(node: XmlNode): string =
  if node == nil: return
  case node.kind
  of xnText, xnCData, xnEntity: result = node.innerText
  of xnElement:
    if node.tag.toLowerAscii() in ["script", "style", "noscript"]: return
    if node.tag.toLowerAscii() == "br": return "\n"
    for child in node: result.add(child.sourceText())
  else: discard

proc nodeText*(node: XmlNode): string =
  ## Only remove surrounding ASCII layout whitespace. rawHtml/rawFields retain it.
  strutils.strip(node.sourceText())

proc hasClass*(node: XmlNode; value: string): bool =
  node != nil and node.kind == xnElement and value in node.htmlAttr("class").splitWhitespace()

proc byClass*(node: XmlNode; value: string): seq[XmlNode] =
  if node == nil or node.kind != xnElement: return
  if node.hasClass(value): result.add(node)
  for child in node: result.add(child.byClass(value))

proc byId*(node: XmlNode; value: string): XmlNode =
  if node == nil or node.kind != xnElement: return nil
  if node.htmlAttr("id") == value: return node
  for child in node:
    let found = child.byId(value)
    if found != nil: return found

proc firstClass*(node: XmlNode; value: string): XmlNode =
  let nodes = node.byClass(value)
  if nodes.len > 0: nodes[0] else: nil

proc firstTag*(node: XmlNode; tag: string): XmlNode =
  if node == nil: return nil
  let nodes = node.findAll(tag)
  if nodes.len > 0: nodes[0] else: nil

proc metadata*(node: XmlNode; name: string): string =
  for meta in node.findAll("meta"):
    if meta.htmlAttr("name").toLowerAscii() == name.toLowerAscii(): return meta.htmlAttr("content")

proc labelValue*(value: string): tuple[label, value: string] =
  let chinese = value.find("：")
  let ascii = value.find(':')
  let pos = if chinese >= 0 and (ascii < 0 or chinese < ascii): chinese else: ascii
  if pos < 0: return ("", "")
  let width = if pos == chinese: "：".len else: 1
  (unicode.strip(value[0..<pos]), value[pos + width..^1])

proc plainEmail*(value: string): bool =
  let value = strutils.strip(value)
  let parts = value.split('@')
  parts.len == 2 and parts[0].len > 0 and parts[1].contains('.') and
    not value.contains({' ', '\t', '\r', '\n', '<', '>'})

proc safeUrl*(href, source: string; hosts: openArray[string]): string =
  if href.len == 0: return
  try:
    var parsed = combine(parseUri(source), parseUri(strutils.strip(href)))
    if parsed.scheme notin ["http", "https"] or parsed.hostname.toLowerAscii() notin hosts or
        parsed.username.len > 0 or parsed.password.len > 0 or parsed.port.len > 0:
      return
    parsed.anchor = ""
    result = $parsed
  except ValueError: discard

proc checkedHtml*(html: string): XmlNode =
  if validateUtf8(html) != -1:
    raise apiError("Faculty response is not valid UTF-8; its source encoding needs explicit support.")
  let lower = html.toLowerAscii()
  if "$_ts=" in html or "window._cf_chl_opt" in lower or
      "g-recaptcha" in lower or "h-captcha" in lower or
      "verify you are human" in lower or "安全验证" in html:
    raise apiError("The faculty website returned an access challenge; retrieval stopped.", 503)
  result = parseHtml(html)

proc appendUnique*(values: var seq[string]; value: string) =
  if value.len > 0 and value notin values: values.add(value)

proc nextLink*(document: XmlNode; source: string; hosts: openArray[string]): string =
  for link in document.findAll("a"):
    if link.nodeText() in ["下页", "下一页", "Next", "Next page", "next"] or link.htmlAttr("rel") == "next":
      let url = safeUrl(link.htmlAttr("href"), source, hosts)
      if url.len > 0 and url != source: return url

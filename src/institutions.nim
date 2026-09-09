## User-defined search presets. This module never contacts an institution website.
import std/[json, os, strutils, tables, uri, sysrand]
from std/unicode import validateUtf8
import arxiv, patents, api_errors

type
  InstitutionPreset* = object
    id*, name*, originalName*, assignee*: string
  InstitutionStore* = ref object
    path: string
    presets: seq[InstitutionPreset]

const DefaultInstitutions* = [
  InstitutionPreset(id: "HIT", name: "Harbin Institute of Technology",
    originalName: "哈尔滨工业大学", assignee: "Harbin Institute of Technology"),
  InstitutionPreset(id: "NUAA", name: "Nanjing University of Aeronautics and Astronautics",
    originalName: "南京航空航天大学", assignee: "Nanjing University of Aeronautics and Astronautics"),
  InstitutionPreset(id: "NPU", name: "Northwestern Polytechnical University",
    originalName: "西北工业大学", assignee: "Northwestern Polytechnical University"),
  InstitutionPreset(id: "BUAA", name: "Beihang University",
    originalName: "北京航空航天大学", assignee: "Beihang University")]

proc isCustom*(preset: InstitutionPreset): bool = preset.id.startsWith("custom-")

proc validated(name, originalName, assignee: string): InstitutionPreset =
  result = InstitutionPreset(name: name.strip(), originalName: originalName.strip(), assignee: assignee.strip())
  if result.assignee.len == 0: result.assignee = result.name
  if result.name.len == 0: raise newException(ValueError, "Enter an institution name.")
  for value in [result.name, result.originalName, result.assignee]:
    if value.len > 200 or validateUtf8(value) != -1 or value.contains({'\0'..'\x1f', '\x7f'}):
      raise newException(ValueError, "Institution names must be valid text of at most 200 UTF-8 bytes.")

proc allInstitutions*(store: InstitutionStore): seq[InstitutionPreset] = store.presets

proc newInstitutionStore*(path = "data/institutions.json"): InstitutionStore =
  result = InstitutionStore(path: path, presets: @DefaultInstitutions)
  if not fileExists(path): return
  if getFileSize(path) > 100_000: raise newException(ValueError, "Institution preset file is too large.")
  let data = parseJson(readFile(path))
  if data.kind != JArray or data.len > 100:
    raise newException(ValueError, "Institution preset file must contain an array of up to 100 custom institutions.")
  for entry in data:
    if entry.kind != JObject: raise newException(ValueError, "Invalid saved institution.")
    for field in ["id", "name", "originalName", "assignee"]:
      if not entry.hasKey(field) or entry[field].kind != JString:
        raise newException(ValueError, "Invalid saved institution field: " & field)
    var preset = validated(entry["name"].getStr(), entry["originalName"].getStr(), entry["assignee"].getStr())
    preset.id = entry["id"].getStr()
    if not preset.isCustom or preset.id.len > 30:
      raise newException(ValueError, "Invalid saved institution identifier.")
    for existing in result.presets:
      if existing.id == preset.id: raise newException(ValueError, "Duplicate saved institution identifier.")
    result.presets.add(preset)

proc save(store: InstitutionStore; presets: seq[InstitutionPreset]) =
  var data = newJArray()
  for preset in presets:
    if preset.isCustom: data.add(%preset)
  let parent = store.path.parentDir()
  if parent.len > 0: createDir(parent)
  # Write before changing memory; a failed save leaves the current list intact.
  let temporary = store.path & ".tmp"
  writeFile(temporary, data.pretty())
  moveFile(temporary, store.path)
  store.presets = presets

proc addInstitution*(store: InstitutionStore; name, originalName, assignee: string) =
  var preset = validated(name, originalName, assignee)
  if store.presets.len >= DefaultInstitutions.len + 100:
    raise newException(ValueError, "The local list supports up to 100 custom institutions.")
  var ids: seq[string]
  for existing in store.presets:
    ids.add(existing.id)
    if existing.name == preset.name and existing.assignee == preset.assignee:
      raise newException(ValueError, "That institution and assignee are already in the list.")
  var number = 1
  while "custom-" & $number in ids: inc number
  preset.id = "custom-" & $number
  store.save(store.presets & @[preset])

proc removeInstitution*(store: InstitutionStore; id: string) =
  var remaining: seq[InstitutionPreset]
  var found = false
  for preset in store.presets:
    if preset.id == id and preset.isCustom: found = true
    else: remaining.add(preset)
  if not found: raise newException(ValueError, "Only a custom institution can be removed.")
  store.save(remaining)

proc patentPresetUrl*(preset: InstitutionPreset): string =
  var options = defaultPatentOptions()
  options.assignee = preset.assignee
  options.patentPageUrl(1)

proc arxivPresetUrl*(preset: InstitutionPreset): string =
  var options = defaultOptions()
  options.query = "\"" & preset.name.replace("\"", "") & "\""
  options.field = "all"
  options.pageUrl(1)

proc newInstitutionFormToken*(): string =
  for value in urandom(24): result.add(toHex(value, 2))

proc institutionFormFields*(body, token: string): Table[string, string] =
  if body.len > 5000: raise newException(ValueError, "Institution form is too large.")
  for key, value in decodeQuery(body): result[key] = value
  if token.len == 0 or result.getOrDefault("csrf") != token:
    raise apiError("This form has expired. Reload the Institutions page and try again.", 403)

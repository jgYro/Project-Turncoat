import std/[unittest, os, tempfiles, uri, tables, strutils, json]
import happyx/spa/tag
import institutions, institution_views, patents, arxiv, api_errors

suite "Institution search presets":
  test "custom names and assignees persist across reload and removal":
    let directory = createTempDir("institution-test-", "")
    defer: removeDir(directory)
    let path = directory / "presets.json"
    let store = newInstitutionStore(path)
    check store.allInstitutions().len == 4
    check not fileExists(path)
    store.addInstitution("Test University", "测试大学", "Test University & Research")
    let reloaded = newInstitutionStore(path)
    check reloaded.allInstitutions().len == 5
    let added = reloaded.allInstitutions()[^1]
    check added.originalName == "测试大学"
    check added.assignee == "Test University & Research"
    reloaded.removeInstitution(added.id)
    check newInstitutionStore(path).allInstitutions().len == 4

  test "patent presets restrict assignee and arXiv presets search metadata names":
    for preset in DefaultInstitutions:
      let patent = patentOptionsFromQuery(parseUri(preset.patentPresetUrl()).query)
      check patent.assignee == preset.assignee
      check patent.query == ""
      check patent.page == 1
      check patent.hasSearch
      let paper = optionsFromQuery(parseUri(preset.arxivPresetUrl()).query)
      check paper.query == "\"" & preset.name & "\""
      check paper.field == "all"
      check parseUri(preset.patentPresetUrl()).path == "/patents"
      check parseUri(preset.arxivPresetUrl()).hostname == ""

  test "validation, defaults and form token protect saved presets":
    let directory = createTempDir("institution-validation-", "")
    defer: removeDir(directory)
    let path = directory / "presets.json"
    let store = newInstitutionStore(path)
    expect ValueError: store.addInstitution(" ", "", "")
    expect ValueError: store.addInstitution(repeat('x', 201), "", "")
    store.addInstitution("Example", "", "")
    check store.allInstitutions()[^1].assignee == "Example"
    expect ValueError: store.addInstitution("Example", "", "Example")
    expect ValueError: store.removeInstitution("HIT")
    let token = newInstitutionFormToken()
    check token.len == 48
    let fields = institutionFormFields(encodeQuery([("csrf", token), ("name", "大学 & A+B")]), token)
    check fields["name"] == "大学 & A+B"
    expect ApiError: discard institutionFormFields("name=Example", token)
    expect ApiError: discard institutionFormFields("csrf=wrong", token)
    writeFile(path, "invalid JSON")
    expect JsonParsingError: discard newInstitutionStore(path)
    check readFile(path) == "invalid JSON"

  test "HappyX page escapes saved names and labels the arXiv limitation":
    var presets = @DefaultInstitutions
    presets.add(InstitutionPreset(id: "custom-1", name: "<img src=x>", originalName: "测试", assignee: "A&B"))
    let html = $renderInstitutionsPage(presets, "token", error = "<script>alert(1)</script>")
    check "<img src=x>" notin html
    check "<script>alert(1)</script>" notin html
    check "role=\"alert\"" in html
    check "arXiv name mentions" in html
    check "not a verified affiliation list" in html
    check "action=\"/institutions#add-institution\"" in html
    check "action=\"/institutions/remove\"" in html
    check "assignee=A%26B" in html

import std/tables
import happyx
import institutions, views

proc institutionCard(preset: InstitutionPreset; token: string): TagRef =
  return buildHtml:
    tArticle(class = "institution-card"):
      tDiv(class = "institution-card-top"):
        tSpan(class = "eyebrow"):
          if preset.isCustom: "YOUR INSTITUTION"
          else: {preset.id}
        if preset.isCustom:
          tForm("method" = "post", action = "/institutions/remove"):
            tInput("type" = "hidden", name = "csrf", value = attr(token))
            tInput("type" = "hidden", name = "id", value = attr(preset.id))
            tButton(class = "remove-institution", "type" = "submit",
                "aria-label" = attr("Remove " & preset.name)): "Remove"
      tH3: {preset.name}
      if preset.originalName.len > 0:
        tP(class = "institution-original"): {preset.originalName}
      tP(class = "institution-assignee"):
        tSpan: "Patent assignee"
        {preset.assignee}
      tDiv(class = "institution-actions"):
        tA(class = "institution-patents", href = attr(preset.patentPresetUrl()),
            "aria-label" = attr("Search patents for " & preset.name)): "Search patents ↗"
        tA(href = attr(preset.arxivPresetUrl()),
            "aria-label" = attr("Search arXiv name mentions for " & preset.name)): "arXiv name mentions ↗"

proc renderInstitutionsPage*(presets: seq[InstitutionPreset]; token: string;
    error = ""; fields = initTable[string, string]()): TagRef =
  let content = buildHtml:
    {siteHeader("institutions")}
    tMain(class = "wrap"):
      tSection(class = "hero institution-hero", "aria-labelledby" = "hero-title"):
        tDiv(class = "hero-copy"):
          tP(class = "eyebrow"): "SEARCH BY INSTITUTION"
          tH1(id = "hero-title"):
            "Start with an "
            tEm: "institution."
          tP(class = "hero-description"): "A shared starting point for university research and inventions."
      tDiv(class = "institution-explainer"):
        tP:
          tStrong: "Google Patents: "
          "searches the named assignee. Add topic keywords on the results page."
        tP:
          tStrong: "arXiv: "
          "searches the university name in metadata. Results are name mentions, not a verified affiliation list."
        tP(class = "institution-source-note"): "Searches use Google Patents and arXiv. No university websites are contacted."
      tSection(id = "results", tabindex = "-1", "aria-labelledby" = "institutions-title"):
        tDiv(class = "institution-list-heading"):
          tDiv:
            tH2(id = "institutions-title"): "Your search list"
            tP: "{presets.len} institutions · saved on this app"
          tA(class = "page-button", href = "#add-institution"): "+ Add institution"
        tDiv(class = "institution-grid"):
          for preset in presets:
            {institutionCard(preset, token)}
      tSection(class = "institution-editor", id = "add-institution", "aria-labelledby" = "add-title"):
        tDiv:
          tSpan(class = "eyebrow"): "EXPAND YOUR SEARCH"
          tH2(id = "add-title"): "Add an institution"
          tP: "Save a university, college, or research organization for your next search."
        if error.len > 0:
          tP(class = "institution-error", role = "alert"): {error}
        tForm("method" = "post", action = "/institutions#add-institution", class = "institution-form"):
          tInput("type" = "hidden", name = "csrf", value = attr(token))
          tDiv(class = "filter-group"):
            tLabel("for" = "institution-name"): "Institution name"
            tInput(id = "institution-name", name = "name", required = "", maxlength = "200",
              value = attr(fields.getOrDefault("name")), placeholder = "e.g. Tsinghua University")
          tDiv(class = "filter-group"):
            tLabel("for" = "institution-original"): "Original-language name (optional)"
            tInput(id = "institution-original", name = "originalName", maxlength = "200",
              value = attr(fields.getOrDefault("originalName")), placeholder = "e.g. 清华大学")
          tDiv(class = "filter-group"):
            tLabel("for" = "institution-assignee"): "Patent assignee name (optional)"
            tInput(id = "institution-assignee", name = "assignee", maxlength = "200",
              value = attr(fields.getOrDefault("assignee")), "aria-describedby" = "assignee-help",
              placeholder = "Defaults to the institution name")
            tP(id = "assignee-help"): "Use the name recorded on Google Patents if it differs."
          tButton(class = "primary-button", "type" = "submit"): "Save institution →"
      tDetails(class = "search-guide institution-guide", id = "search-guide"):
        tSummary: "About these institution searches ＋"
        tP: "Assignee names may vary across patent records. A preset uses the name shown on its card and does not combine spelling variants automatically."
        tP: "arXiv has no affiliation search filter. A university-name search can miss papers whose affiliation appears only in the full text."
        tA(href = "https://support.google.com/faqs/answer/7049475", target = "_blank", rel = "noopener noreferrer"): "Google Patents search help ↗"
    {siteFooter("institutions")}
  pageDocument("Institutions", "Save institution searches for Google Patents and arXiv.", content)

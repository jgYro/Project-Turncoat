## The patent interface uses the same server-rendered HappyX HTML DSL.
import std/[json, strutils]
import happyx
import patents, views

proc patentForm(options: PatentOptions): TagRef =
  return buildHtml:
    tSection(class = "search-section", "aria-label" = "Search patents"):
      tForm(id = "search-form", "method" = "get", action = "/patents#results", role = "search",
          "data-source" = "Google Patents", "data-search-label" = "Search patents"):
        tDiv(class = "search-box"):
          tSvg(class = "search-icon", viewBox = "0 0 24 24", fill = "none", "aria-hidden" = "true"):
            tCircle(cx = "10.5", cy = "10.5", r = "6.5")
            tPath(d = "m16 16 5 5")
          tLabel(class = "sr-only", "for" = "q"): "Search patents"
          tInput(id = "q", name = "q", "type" = "search", value = attr(options.query),
            placeholder = "Search an invention, a technology, an idea…", maxlength = "1000",
            "aria-describedby" = "query-hint")
          tLabel(class = "sr-only", "for" = "field"): "Patent office"
          tSelect(id = "field", name = "country"):
            {choices(PatentCountries, options.country)}
            if options.country.len > 0:
              var known = false
              for item in PatentCountries:
                if item[0] == options.country: known = true
              if not known:
                tOption(value = attr(options.country), selected = ""): {options.country}
          tButton(class = "search-button", "type" = "submit"):
            tSpan(class = "button-label"): "Search patents"
            tSpan(class = "button-arrow", "aria-hidden" = "true"): "↗"
            tSpan(class = "spinner", "aria-hidden" = "true")
      tDiv(class = "search-under"):
        tP(id = "query-hint"): "Search worldwide patent publications. Use quotes for an exact phrase."
        tSpan(class = "keyboard-hint"):
          "Press "
          tKbd: "/"
          " to search"

proc patentFilters(options: PatentOptions): TagRef =
  return buildHtml:
    tAside(class = "filters", "aria-labelledby" = "filter-title"):
      tDiv(class = "filter-heading"):
        tH2(id = "filter-title"): "Refine your search"
        tA(href = "/patents"): "Reset"
      tDiv(class = "filter-group"):
        tLabel("for" = "assignee"): "Assignee"
        tInput(id = "assignee", name = "assignee", form = "search-form",
          value = attr(options.assignee), placeholder = "e.g. Google", maxlength = "200")
      tDiv(class = "filter-group"):
        tLabel("for" = "inventor"): "Inventor"
        tInput(id = "inventor", name = "inventor", form = "search-form",
          value = attr(options.inventor), placeholder = "e.g. Henrik Kretzschmar", maxlength = "200")
      tFieldset(class = "filter-group"):
        tLegend: "Filing date"
        tLabel(class = "small-label", "for" = "after"): "After"
        tInput(id = "after", name = "after", form = "search-form", "type" = "date", value = attr(options.after))
        tLabel(class = "small-label", "for" = "before"): "Before"
        tInput(id = "before", name = "before", form = "search-form", "type" = "date", value = attr(options.before))
      tButton(class = "apply-button", "type" = "submit", form = "search-form"): "Apply filters →"
      tDetails(class = "search-guide", id = "search-guide"):
        tSummary: "Make your search go further ＋"
        tP:
          tStrong: "Exact phrase"
          tBr
          tCode: "\"neural network\""
        tP:
          tStrong: "Search in the title"
          tBr
          tCode: "TI=(wireless charging)"
        tP:
          tStrong: "Combine ideas"
          tBr
          tCode: "(solar OR photovoltaic) AND battery"
        tP: "Use a publication number such as US9014905B1 to find a specific patent."
        tA(href = "https://support.google.com/faqs/answer/7049475", target = "_blank", rel = "noopener noreferrer"):
          "Google Patents search help ↗"

proc patentCard(patent: JsonNode; index: int): TagRef =
  let id = patent["publication_number"].getStr()
  let title = patent["title"].getStr()
  let url = patent["url"].getStr()
  return buildHtml:
    tArticle(class = "paper"):
      tDiv(class = "paper-number"): "{index:02}"
      tDiv(class = "paper-content"):
        tDiv(class = "paper-meta"):
          tSpan(class = "primary-category"): {id}
          if patent["filing_date"].getStr().len > 0:
            tSpan: "Filed {patent[\"filing_date\"].getStr()}"
        tH3:
          tA(href = attr(url), target = "_blank", rel = "noopener noreferrer"): {title}
        if patent["assignee"].getStr().len > 0:
          tP(class = "authors"): {patent["assignee"].getStr()}
        if patent["snippet"].getStr().len > 0:
          tP(class = "patent-snippet"): {patent["snippet"].getStr()}
        tDiv(class = "paper-bottom"):
          tDiv(class = "tags"):
            if patent["publication_date"].getStr().len > 0:
              tSpan(class = "tag"): "Published {patent[\"publication_date\"].getStr()}"
          tDiv(class = "paper-links"):
            tA(class = "investigate-link", href = attr("/graph?patent=" & id),
                "aria-label" = attr("Investigate " & id)): "Investigate ⌁"
            tA(href = attr(url), target = "_blank", rel = "noopener noreferrer"): "Google Patents ↗"
            if patent["pdf_url"].getStr().len > 0:
              tA(class = "pdf-link", href = attr(patent["pdf_url"].getStr()),
                  target = "_blank", rel = "noopener noreferrer"): "Read PDF ↗"

proc patentStarter(query, number, title, description: string): TagRef =
  var options = defaultPatentOptions()
  options.query = query
  return buildHtml:
    tA(class = "starter", href = attr(options.patentPageUrl(1))):
      tSpan(class = "eyebrow"): {number}
      tH3:
        {title}
        tSpan("aria-hidden" = "true"): "↗"
      tP: {description}

proc patentResults(options: PatentOptions; data: JsonNode; error: string): TagRef =
  if error.len > 0:
    return buildHtml:
      tDiv(class = "state error-state", role = "alert"):
        tSpan(class = "state-mark", "aria-hidden" = "true"): "!"
        tH2: "We couldn’t complete this search"
        tP: {error}
        tButton(class = "primary-button", "type" = "submit", form = "search-form"): "Try search again ↗"
        if options.hasSearch:
          tP:
            tA(href = attr(options.patentSearchUrl()), target = "_blank", rel = "noopener noreferrer"):
              "Continue on Google Patents ↗"
  if not options.hasSearch:
    return buildHtml:
      tDiv(class = "welcome-heading"):
        tSpan(class = "eyebrow"): "FROM IDEAS TO INVENTIONS"
        tH2: "See how an idea takes shape."
        tP: "Explore patent publications, follow an inventor’s work, or discover a new approach."
      tDiv(class = "starter-grid"):
        {patentStarter("neural network", "01 / MACHINE LEARNING", "Learning by design",
          "Explore inventions built around neural networks.")}
        {patentStarter("wireless charging", "02 / ENERGY", "Power without wires",
          "Discover new ways to keep devices moving.")}
        {patentStarter("autonomous vehicle", "03 / TRANSPORT", "The road ahead",
          "Follow advances in sensing, navigation, and autonomous vehicles.")}
        {patentStarter("US9014905B1", "04 / A PATENT TO EXPLORE", "Reading the road",
          "How an autonomous vehicle can recognize a cyclist’s hand signals.")}
  if data["results"].len == 0:
    return buildHtml:
      tDiv(class = "state"):
        tH2: "No patents on this page"
        tP: "Try fewer keywords, another patent office, or a broader filing date range."
        tA(class = "primary-button", href = attr(options.patentPageUrl(1))): "Back to first page"
  return buildHtml:
    for index in 0..<data["results"].len:
      {patentCard(data["results"][index], (options.page - 1) * options.pageSize + index + 1)}
    tNav(class = "pagination", "aria-label" = "Result pages"):
      if options.page > 1:
        tA(class = "page-button", href = attr(options.patentPageUrl(options.page - 1))): "← Previous"
      else:
        tSpan(class = "page-button disabled", "aria-disabled" = "true"): "← Previous"
      tSpan: "Page {options.page} of {data[\"total_pages\"].getInt()}"
      if data["has_next"].getBool():
        tA(class = "page-button", href = attr(options.patentPageUrl(options.page + 1))): "Next →"
      else:
        tSpan(class = "page-button disabled", "aria-disabled" = "true"): "Next →"
    tP(class = "limit-note"):
      "Counts are approximate. Google groups related publications into patent families and limits accessible pages. Titles and snippets may be shortened."

proc renderPatentPage*(options: PatentOptions; data: JsonNode = nil; error = ""): TagRef =
  let title = if options.query.len > 0: options.query & " — Patents" else: "Patents"
  let heading = if error.len > 0: "Search needs attention"
    elif data != nil: "About " & insertSep($data["total"].getBiggestInt(), ',') & " patent results"
    else: "A starting point for discovery"
  let content = buildHtml:
    {siteHeader("patents")}
    tMain(class = "wrap"):
      tSection(class = "hero patent-hero", "aria-labelledby" = "hero-title"):
        tDiv(class = "hero-copy"):
          tP(class = "eyebrow"):
            tSpan(class = "tiny-line")
            " INVENTIONS / GOOGLE PATENTS"
          tH1(id = "hero-title"):
            "Explore inventions."
            tBr
            "Follow the "
            tEm: "inventors."
          tP(class = "hero-description"): "Explore patents. Follow inventors. Connect the possibilities."
      {patentForm(options)}
      tP(class = "institution-shortcut"):
        tA(href = "/institutions"): "Search by institution →"
        " Choose a university assignee or add your own institution."
      tDiv(class = "workspace"):
        {patentFilters(options)}
        tSection(class = "results", id = "results", tabindex = "-1", "aria-labelledby" = "results-title"):
          tDiv(class = "results-toolbar"):
            tDiv:
              tH2(id = "results-title"): {heading}
              tSpan(class = "result-count"): "Patent publications · Google Patents"
            tDiv(class = "sort-controls"):
              tLabel(class = "sr-only", "for" = "sort"): "Sort results"
              tSelect(id = "sort", name = "sort", form = "search-form"):
                {choices(PatentSorts, options.sort)}
              tLabel(class = "sr-only", "for" = "size"): "Results per page"
              tSelect(id = "size", name = "size", form = "search-form"):
                {choices([("10", "10 / page"), ("25", "25 / page"), ("50", "50 / page")], $options.pageSize)}
              tButton(class = "sort-apply", "type" = "submit", form = "search-form"): "Update"
          {patentResults(options, data, error)}
    {siteFooter("patents")}
  pageDocument(title, "Discover inventions with Google Patents. Search by topic, inventor, assignee, patent office, and filing date.", content)

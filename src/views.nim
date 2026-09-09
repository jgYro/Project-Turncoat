## The page and its reusable sections are HappyX HTML trees.
import std/[strutils, strformat, uri]
# Exclude the similarly named table macros re-exported from std/htmlgen.
import happyx except tHead, tBody
import arxiv

# HappyX 4.7.4 confuses tHead/tBody with the table tags thead/tbody.
# These small tag builders preserve the documented spelling and correct HTML.
proc tHead(stmt: TagRef): TagRef =
  return buildHtml(head):
    {stmt}

proc tBody(stmt: TagRef): TagRef =
  return buildHtml(body):
    {stmt}

proc attr*(value: string): string =
  ## HappyX escapes text nodes; attribute values also need entity escaping.
  value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    .replace("\"", "&quot;").replace("'", "&#39;")

proc choices*(items: openArray[(string, string)]; selected: string): TagRef =
  return buildHtml:
    for (value, label) in items:
      if value == selected:
        tOption(value = attr(value), selected = ""): {label}
      else:
        tOption(value = attr(value)): {label}

proc displayDate(value: string): string =
  if value.len >= 10: value[0..9] else: value

proc paperCard(paper: Paper; index: int): TagRef =
  let url = "/document?source=arxiv&id=" & encodeUrl(paper.id)
  let pdf = url & "&view=pdf"
  return buildHtml:
    tArticle(class = "paper"):
      tDiv(class = "paper-number"): "{index:02}"
      tDiv(class = "paper-content"):
        tDiv(class = "paper-meta"):
          tSpan(class = "primary-category"): {paper.primaryCategory}
          tSpan: "Submitted {displayDate(paper.published)}"
        tH3:
          tA(href = attr(url)):
            {paper.title}
        tP(class = "authors"): {paper.authors.join(", ")}
        tDetails(class = "abstract"):
          tSummary:
            tSpan(class = "abstract-preview"): {paper.summary}
            tSpan(class = "read-more"):
              tSpan(class = "when-closed"): "Read full abstract +"
              tSpan(class = "when-open"): "Close abstract −"
          tDiv(class = "abstract-body"):
            tP: {paper.summary}
            tDiv(class = "paper-extra"):
              if paper.comment.len > 0:
                tP:
                  tStrong: "Notes"
                  {paper.comment}
              if paper.journal.len > 0:
                tP:
                  tStrong: "Journal"
                  {paper.journal}
              if paper.doi.len > 0:
                tP:
                  tStrong: "DOI"
                  tA(href = attr("https://doi.org/" & encodeUrl(paper.doi)),
                      target = "_blank", rel = "noopener noreferrer"):
                    "{paper.doi} ↗"
              tP:
                tStrong: "Last updated"
                {displayDate(paper.updated)}
        tDiv(class = "paper-bottom"):
          tDiv(class = "tags"):
            for category in paper.categories:
              tSpan(class = "tag"): {category}
          tDiv(class = "paper-links"):
            tA(class = "investigate-link",href = attr("/graph?paper=" & encodeUrl(paper.id)),title = "Investigate with background keyword and AI analysis"):
              "Investigate ↗"
            tButton(class = "analysis-link", "type" = "button", "data-analysis-source" = "arxiv",
                "data-analysis-id" = attr(paper.id), "aria-label" = attr("AI Analysis of " & paper.title)):
              "AI Analysis ✳"
            tA(href = attr(url), "aria-label" = attr("Read arXiv record: " & paper.title)):
              "arXiv record →"
            tA(class = "pdf-link", href = attr(pdf), "aria-label" = attr("Read PDF of " & paper.title)):
              "Read PDF →"

proc starter(query, field, eyebrow, title, description: string): TagRef =
  var options = defaultOptions()
  options.query = query
  options.field = field
  return buildHtml:
    tA(class = "starter", href = attr(options.pageUrl(1))):
      tSpan(class = "eyebrow"): {eyebrow}
      tH3:
        {title}
        tSpan("aria-hidden" = "true"): "↗"
      tP: {description}

proc welcome(): TagRef =
  return buildHtml:
    tDiv(class = "welcome-heading"):
      tSpan(class = "eyebrow"): "FOLLOW YOUR CURIOSITY"
      tH2: "Where will your next idea begin?"
      tP: "Find a new perspective, revisit a foundational paper, or explore the edge of your field."
    tDiv(class = "starter-grid"):
      {starter("large language models", "all", "01 / COMPUTER SCIENCE",
        "Thinking in language", "Explore language models, reasoning, and the systems behind them.")}
      {starter("quantum computing", "all", "02 / QUANTUM PHYSICS",
        "Beyond the classical", "Follow new approaches to quantum computation and information.")}
      {starter("au:del_maestro AND ti:checkerboard", "raw", "03 / ADVANCED SEARCH",
        "Connect the dots", "Combine authors, titles, and ideas with a precise search query.")}
      {starter("1706.03762", "id", "04 / A PAPER TO REVISIT",
        "Attention Is All You Need", "Open the transformer paper directly using its arXiv identifier.")}
    tDiv(class = "open-note"):
      tSpan("aria-hidden" = "true"): "✳"
      tDiv:
        tH3: "Knowledge grows when it’s open."
        tP: "Search preprints across disciplines, straight from arXiv. No account required."

proc renderResults(options: SearchOptions; data: SearchResult; error: string): TagRef =
  if error.len > 0:
    return buildHtml:
      tDiv(class = "state error-state", role = "alert"):
        tSpan(class = "state-mark", "aria-hidden" = "true"): "!"
        tH2: "We couldn’t complete this search"
        tP: {error}
        tP: "Your search is still here. Adjust it above, or try again."
        tButton(class = "primary-button", "type" = "submit", form = "search-form"):
          "Try search again ↗"
  if not options.hasSearch:
    return welcome()
  if data.papers.len == 0:
    let outOfRange = data.total > 0
    let title = if outOfRange: "You’ve reached the end of these results"
      else: "No papers found. A new angle might help."
    let hint = if outOfRange: "Return to the first page to explore the matching papers."
      else: "Try fewer keywords, a broader discipline, or a wider date range. Check the search guide for phrase and author searches."
    let href = if outOfRange: options.pageUrl(1) else: "/"
    let label = if outOfRange: "Back to first page" else: "Start a fresh search"
    return buildHtml:
      tDiv(class = "state"):
        tSpan(class = "state-mark", "aria-hidden" = "true"): "↗"
        tH2: {title}
        tP: {hint}
        tA(class = "primary-button", href = attr(href)): {label}

  let limit = min(data.total, MaxResults)
  let pages = max(1, (limit + options.pageSize - 1) div options.pageSize)
  return buildHtml:
    for index, paper in data.papers:
      {paperCard(paper, data.start + index + 1)}
    tNav(class = "pagination", "aria-label" = "Result pages"):
      if options.page > 1:
        tA(class = "page-button", href = attr(options.pageUrl(options.page - 1))):
          "← Previous"
      else:
        tSpan(class = "page-button disabled", "aria-disabled" = "true"): "← Previous"
      tSpan:
        "Page "
        tStrong: "{options.page}"
        " of {pages}"
      if options.page < pages:
        tA(class = "page-button", href = attr(options.pageUrl(options.page + 1))):
          "Next →"
      else:
        tSpan(class = "page-button disabled", "aria-disabled" = "true"): "Next →"
    if data.total > MaxResults:
      tP(class = "limit-note"):
        "Showing the first 30,000 matches available through the API. Refine your search for more focused results."

proc siteHeader*(source = "arxiv"): TagRef =
  return buildHtml:
    tA(class = "skip-link", href = "#results"): "Skip to results"
    tHeader(class = "site-header"):
      tA(class = "brand", href = "/", "aria-label" = "Project Turncoat home"):
        tSpan(class = "brand-mark", "aria-hidden" = "true"): "✳"
        tSpan:
          tSpan(class = "brand-light"): "Project "
          "Turncoat"
      tNav("aria-label" = "Main navigation"):
        if source == "arxiv":
          tA(class = "active", href = "/", "aria-current" = "page"): "Papers"
          tA(href = "/patents"): "Patents"
        elif source == "patents":
          tA(href = "/"): "Papers"
          tA(class = "active", href = "/patents", "aria-current" = "page"): "Patents"
        else:
          tA(href = "/"): "Papers"
          tA(href = "/patents"): "Patents"
        if source == "institutions":
          tA(class = "active", href = "/institutions", "aria-current" = "page"): "Institutions"
        else:
          tA(href = "/institutions"): "Institutions"
        tA(href = "/graph"): "Graph"
        if source == "chat":
          tA(class = "active", href = "/chat", "aria-current" = "page"): "Chat"
        else:
          tA(href = "/chat"): "Chat"
        if source == "settings":
          tA(class = "active",href = "/settings","aria-current" = "page"): "Settings"
        else:
          tA(href = "/settings"): "Settings"
        if source == "settings":
          tA(class = "nav-guide", href = "/docs/graph-drilldowns.md"): "Screening guide ↗"
        elif source in ["chat", "document", "chat-guide"]:
          tA(class = "nav-guide", href = "/chat/guide"): "Chat guide ↗"
        else:
          tA(class = "nav-guide", href = "#search-guide"):
            "Search guide "
            tSpan("aria-hidden" = "true"): "↗"
      tSpan(class = "local-indicator"): "LOCAL WORKSPACE"

proc hero(): TagRef =
  return buildHtml:
    tSection(class = "hero", "aria-labelledby" = "hero-title"):
      tDiv(class = "hero-copy"):
        tP(class = "eyebrow"):
          tSpan(class = "tiny-line")
          " RESEARCH / ARXIV"
        tH1(id = "hero-title"):
          "Trace ideas."
          tBr
          "Follow the "
          tEm: "research."
        tP(class = "hero-description"): "Explore papers. Connect ideas. Find what’s next."
      tDiv(class = "orbit-art", "aria-hidden" = "true"):
        tSvg(viewBox = "0 0 350 220", fill = "none"):
          tG(stroke = "currentColor", "stroke-width" = "0.8"):
            for radius in ["76", "57", "33", "12"]:
              tEllipse(cx = "175", cy = "110", rx = "116", ry = radius,
                transform = "rotate(-25 175 110)")
            for radius in ["28", "60", "92"]:
              tEllipse(cx = "175", cy = "110", rx = radius, ry = "76",
                transform = "rotate(-25 175 110)")
            tPath(d = "M40 174L307 49M58 40L295 177", "stroke-dasharray" = "3 6")
          tCircle(cx = "281", cy = "60", r = "5", fill = "#63e4dc")
          tCircle(cx = "93", cy = "166", r = "4", fill = "#efc579")
          tPath(d = "M305 164v16m-8-8h16", stroke = "#63e4dc", "stroke-width" = "1.4")
        tSpan(class = "art-caption"): "IDEAS HAVE NO BOUNDARIES"

proc searchForm(options: SearchOptions): TagRef =
  return buildHtml:
    tSection(class = "search-section", "aria-label" = "Search papers"):
      tForm(id = "search-form", "method" = "get", action = "/#results", role = "search"):
        tDiv(class = "search-box"):
          tSvg(class = "search-icon", viewBox = "0 0 24 24", fill = "none", "aria-hidden" = "true"):
            tCircle(cx = "10.5", cy = "10.5", r = "6.5")
            tPath(d = "m16 16 5 5")
          tLabel(class = "sr-only", "for" = "q"): "Search papers"
          tInput(id = "q", name = "q", "type" = "search", value = attr(options.query),
            placeholder = "Search an idea, a paper, a possibility…", maxlength = "1000",
            autocomplete = "off", "aria-describedby" = "query-hint")
          tLabel(class = "sr-only", "for" = "field"): "Search in"
          tSelect(name = "field", id = "field"):
            {choices(Fields, options.field)}
          tButton(class = "search-button", "type" = "submit"):
            tSpan(class = "button-label"): "Search papers"
            tSpan(class = "button-arrow", "aria-hidden" = "true"): "↗"
            tSpan(class = "spinner", "aria-hidden" = "true")
      tDiv(class = "search-under"):
        tP(id = "query-hint"):
          "A few words can open a whole new field. Use quotes for an exact phrase."
        tSpan(class = "keyboard-hint"):
          "Press "
          tKbd: "/"
          " to search"

proc searchGuide(): TagRef =
  return buildHtml:
    tDetails(class = "search-guide", id = "search-guide"):
      tSummary:
        "Make your search go further "
        tSpan("aria-hidden" = "true"): "＋"
      tP:
        tStrong: "Exact phrases"
        tBr
        tCode: "\"graph neural networks\""
      tP:
        tStrong: "Advanced query mode"
        tBr
        tCode:
          "au:del_maestro AND"
          tBr
          "ti:checkerboard"
      tP:
        "Combine "
        tCode: "ti:"
        " title, "
        tCode: "au:"
        " author, and "
        tCode: "cat:"
        " category with "
        tCode: "AND"
        ", "
        tCode: "OR"
        ", or "
        tCode: "ANDNOT"
        "."
      tP:
        tStrong: "Find a specific paper"
        tBr
        "Choose “arXiv IDs” and enter "
        tCode: "1706.03762"
        ". Separate multiple IDs with commas."
      tA(href = "https://info.arxiv.org/help/api/user-manual.html#detailed_examples",
          target = "_blank", rel = "noopener noreferrer"):
        "arXiv search documentation ↗"

proc filters(options: SearchOptions): TagRef =
  return buildHtml:
    tAside(class = "filters", "aria-labelledby" = "filter-title"):
      tDiv(class = "filter-heading"):
        tH2(id = "filter-title"): "Refine your search"
        tA(href = "/"): "Reset"
      tDiv(class = "filter-group"):
        tLabel("for" = "category"): "Discipline"
        tSelect(id = "category", name = "category", form = "search-form"):
          {choices(Categories, options.category)}
      tDiv(class = "filter-group"):
        tLabel("for" = "author"): "Author"
        tInput(id = "author", name = "author", form = "search-form",
          placeholder = "e.g. Yoshua Bengio", value = attr(options.author), maxlength = "200")
      tFieldset(class = "filter-group"):
        tLegend: "Submission date"
        tLabel(class = "small-label", "for" = "from"): "From"
        tInput(id = "from", name = "from", form = "search-form", "type" = "date",
          value = attr(options.dateFrom))
        tLabel(class = "small-label", "for" = "to"): "To"
        tInput(id = "to", name = "to", form = "search-form", "type" = "date",
          value = attr(options.dateTo))
      tButton(class = "apply-button", "type" = "submit", form = "search-form"):
        "Apply filters "
        tSpan("aria-hidden" = "true"): "→"
      {searchGuide()}

proc resultsSection(options: SearchOptions; data: SearchResult; error: string): TagRef =
  let heading = if error.len > 0: "Search needs attention"
    elif options.hasSearch: insertSep($data.total, ',') & (if data.total == 1: " paper found" else: " papers found")
    else: "A starting point for discovery"
  let note = if error.len > 0 or not options.hasSearch: ""
    elif data.papers.len > 0: fmt"Showing {data.start + 1}–{data.start + data.papers.len}"
    else: "Try broadening your search"
  return buildHtml:
    tSection(class = "results", id = "results", tabindex = "-1", "aria-labelledby" = "results-title"):
      tDiv(class = "results-toolbar"):
        tDiv:
          tH2(id = "results-title"): {heading}
          tSpan(class = "result-count"): {note}
        tDiv(class = "sort-controls"):
          tLabel(class = "sr-only", "for" = "sort"): "Sort results"
          tSelect(id = "sort", name = "sort", form = "search-form"):
            {choices(Sorts, options.sort)}
          tLabel(class = "sr-only", "for" = "size"): "Results per page"
          tSelect(id = "size", name = "size", form = "search-form"):
            {choices([("10", "10 / page"), ("25", "25 / page"), ("50", "50 / page")], $options.pageSize)}
          tButton(class = "sort-apply", "type" = "submit", form = "search-form"): "Update"
      {renderResults(options, data, error)}

proc siteFooter*(source = "arxiv"): TagRef =
  let provider = if source == "patents": "Google Patents" else: "arXiv"
  let providerUrl = if source == "patents": "https://patents.google.com" else: "https://arxiv.org"
  return buildHtml:
    tFooter(class = "site-footer wrap"):
      tSpan(class = "footer-brand"): "Project Turncoat"
      tP:
        "Independent discovery interface. "
        if source == "institutions":
          "Searches via "
          tA(href = "https://patents.google.com", target = "_blank", rel = "noopener noreferrer"): "Google Patents"
          " and "
          tA(href = "https://arxiv.org", target = "_blank", rel = "noopener noreferrer"): "arXiv"
        else:
          "Metadata provided by "
          tA(href = providerUrl, target = "_blank", rel = "noopener noreferrer"): {provider}
        "."
      tButton(id = "copy-search", "type" = "button", hidden = ""): "Copy search link ↗"
    tDiv(class = "sr-only", id = "status", role = "status", "aria-live" = "polite")

proc pageDocument*(title, description: string; content: TagRef; extraHead: TagRef = nil): TagRef =
  # The document declaration is a node too; all page markup uses the DSL below.
  let doctype = initTag("!DOCTYPE")
  doctype.addArg("html")
  let additions = if extraHead == nil: initTag("div", onlyChildren = true) else: extraHead
  return buildHtml:
    {doctype}
    tHtml(lang = "en"):
      tHead:
        tMeta(charset = "utf-8")
        tMeta(name = "viewport", content = "width=device-width, initial-scale=1")
        tMeta(name = "description", content = attr(description))
        tMeta(name = "color-scheme", content = "dark")
        tTitle: {title & " · Project Turncoat"}
        tLink(rel = "icon", href = "/favicon.svg", "type" = "image/svg+xml")
        tLink(rel = "stylesheet", href = "/assets/theme.css")
        tLink(rel = "stylesheet", href = "/assets/style.css")
        tScript(src = "/assets/app.js", "defer" = "")
        tLink(rel = "stylesheet", href = "/assets/jobs.css")
        tScript(src = "/assets/jobs.js", "defer" = "")
        {additions}
      tBody:
        {content}

proc renderPage*(options: SearchOptions; data = SearchResult(); error = ""): TagRef =
  let title = if options.query.len > 0: options.query & " — Papers"
    else: "Papers"
  let content = buildHtml:
    {siteHeader()}
    tMain(class = "wrap"):
      {hero()}
      {searchForm(options)}
      tP(class = "institution-shortcut"):
        tA(href = "/institutions"): "Search by institution →"
        " Presets for HIT, NUAA, NPU, and Beihang. Add your own."
      tDiv(class = "workspace"):
        {filters(options)}
        {resultsSection(options, data, error)}
    {siteFooter()}
  pageDocument(title, "A quieter way to discover open research. Search arXiv papers by topic, author, discipline, and date.", content)

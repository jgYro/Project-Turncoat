import happyx
import views

proc renderSettingsPage*(token: string): TagRef =
  let content = buildHtml:
    {siteHeader("settings")}
    tMain(id="results",class="settings-workspace"):
      tHeader(class="research-heading"):
        tDiv:
          tP(class="eyebrow"): "SETTINGS / RESEARCH RULES"
          tH1: "Rules, queries, and search history."
          tP(class="research-note"): "Inspect the vocabulary and review instructions used for new analyses, and the provider searches saved in this workspace."
      tNav(class="research-subtabs",role="tablist","aria-label"="Settings sections"):
        tButton(id="settings-rules","type"="button",role="tab","aria-selected"="true","aria-controls"="settings-content"): "Keyword rules"
        tButton(id="settings-queries","type"="button",role="tab","aria-selected"="false","aria-controls"="settings-content"): "AI queries"
        tButton(id="settings-searches","type"="button",role="tab","aria-selected"="false","aria-controls"="settings-content"): "Provider searches"
      tDiv(class="research-toolbar"):
        tLabel("for"="settings-filter"): "Filter loaded entries"
        tInput(id="settings-filter","type"="search",placeholder="Term, category, query, or provider…")
        tSelect(id="settings-dataset","aria-label"="Search dataset",hidden=""):
          tOption(value=""): "All datasets"
        tButton(id="settings-refresh","type"="button"): "Refresh"
      tP(id="settings-status",class="research-status",role="status"): "Loading rules…"
      tSection(id="settings-content",class="research-scroll",role="tabpanel","aria-labelledby"="settings-rules",tabindex="0")
      tButton(id="settings-more","type"="button",hidden=""): "More saved searches"
    tNoscript: "Enable JavaScript to inspect the current rules and saved searches."
  let head = buildHtml:
    tMeta(name="turncoat-token",content=attr(token))
    tLink(rel="stylesheet",href="/assets/research.css")
    tScript(src="/assets/research-ui.js","defer"="")
    tScript(src="/assets/settings.js","defer"="")
  pageDocument("Settings","Inspect research rules and saved provider searches.",content,head)

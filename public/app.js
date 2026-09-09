const form = document.querySelector('#search-form');
const status = document.querySelector('#status');

let analysisStarting = false;
window.TurncoatStartAnalysis = (reference) => {
  if (analysisStarting) return;
  const analysis = crypto.randomUUID();
  sessionStorage.setItem('turncoat-analysis-intent:' + analysis, JSON.stringify({reference, createdAt: Date.now()}));
  location.assign('/chat?' + new URLSearchParams({...reference, analysis}));
  analysisStarting = true;
};
window.addEventListener('pageshow', () => { analysisStarting = false; });
for (const button of document.querySelectorAll('[data-analysis-source]')) {
  button.addEventListener('click', () => {
    try {
      window.TurncoatStartAnalysis({source: button.dataset.analysisSource, id: button.dataset.analysisId});
    } catch {
      status.textContent = 'AI Analysis needs browser session storage. Enable it, or open the document and choose Ask about this document.';
    }
  });
}

function resetLoading() {
  if (!form) return;
  form.removeAttribute('aria-busy');
  document.body.classList.remove('is-searching');
  document.querySelector('.button-label').textContent = form.dataset.searchLabel || 'Search papers';
}

form?.addEventListener('submit', () => {
  document.body.classList.add('is-searching');
  form.setAttribute('aria-busy', 'true');
  document.querySelector('.button-label').textContent = 'Searching…';
  status.textContent = `Searching ${form.dataset.source || 'arXiv'}. This may take a few moments.`;
});

window.addEventListener('pageshow', resetLoading);
document.querySelector('a[href="#search-guide"]')?.addEventListener('click', () => {
  document.querySelector('#search-guide').open = true;
});
document.addEventListener('keydown', (event) => {
  if (event.key === '/' && !event.ctrlKey && !event.metaKey && !event.altKey &&
      !event.target.matches('input, textarea, select, [contenteditable]') && document.querySelector('#q')) {
    event.preventDefault();
    document.querySelector('#q').focus();
  }
});

for (const id of ['sort', 'size']) {
  document.getElementById(id)?.addEventListener('change', () => {
    if (location.search) form.requestSubmit();
  });
}

const copy = document.querySelector('#copy-search');
if (copy && navigator.clipboard && location.search) {
  copy.hidden = false;
  copy.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(location.href);
      copy.textContent = 'Link copied ✓';
      status.textContent = 'Search link copied to clipboard.';
    } catch {
      status.textContent = 'Could not copy automatically. Copy the URL from your address bar.';
      copy.textContent = 'Copy the URL from your address bar';
    }
  });
}

(() => {
  'use strict';
  const el=id=>document.getElementById(id), params=new URLSearchParams(location.search);
  const reference={source:params.get('source'),id:params.get('id')};
  if(params.has('node')){reference.node=params.get('node');reference.dataset=params.get('dataset');}
  const token=document.querySelector('meta[name="turncoat-token"]').content;
  const tree=new TurncoatJsonTree(el('document-tree'));
  let record=null,pdfLoaded=false,pdfContext=null;
  function status(text,error=false){el('document-status').textContent=text;el('document-status').classList.toggle('error',error);}
  el('document-analysis').addEventListener('click',()=>{
    if(!record||el('document-analysis').disabled)return;
    el('document-analysis').disabled=true;
    try{
      window.TurncoatStartAnalysis(reference);
    }catch{
      status('AI Analysis needs browser session storage. Enable it, or use Ask about this document to send a review request.',true);
      el('document-analysis').disabled=false;
    }
  });
  window.addEventListener('pageshow',()=>{el('document-analysis').disabled=false;});
  async function request(path){const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-Turncoat-Token':token},body:JSON.stringify(reference)});const d=await r.json();if(!r.ok)throw new Error(d.error?.message||'Could not load document.');return d;}
  async function show(view){
    if(!['record','pdf','text'].includes(view))view='record';
    for(const name of ['record','pdf','text']){el('view-'+name).hidden=name!==view;el('tab-'+name).setAttribute('aria-selected',String(name===view));el('tab-'+name).tabIndex=name===view?0:-1;}
    history.replaceState(null,'','/document?'+new URLSearchParams({...reference,view}));
    if(view==='pdf'&&record&&!pdfLoaded){
      if(!record.pdfUrl){status('No PDF is listed for this record.',true);return;}
      status('Loading PDF into the reader…');
      try{
        await request('/api/documents/prepare-pdf');
        const frame=document.createElement('iframe');frame.title='PDF document';frame.src='/api/documents/pdf?'+new URLSearchParams({source:reference.source,id:reference.id});
        el('pdf-container').replaceChildren(frame);pdfLoaded=true;status('PDF ready. Switch to Extracted text to inspect what chat can read.');
      }catch(error){status(error.message,true);}
    }
  }
  for(const name of ['record','pdf','text'])el('tab-'+name).addEventListener('click',()=>show(name));
  document.querySelector('.reader-tabs').addEventListener('keydown',event=>{
    if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
    event.preventDefault();const tabs=['record','pdf','text'],current=tabs.findIndex(n=>el('tab-'+n).getAttribute('aria-selected')==='true');
    const next=event.key==='Home'?0:event.key==='End'?2:(current+(event.key==='ArrowRight'?1:2))%3;
    el('tab-'+tabs[next]).focus();show(tabs[next]);
  });
  el('load-pdf-text').addEventListener('click',()=>pdfContext?.prepare(true));
  request('/api/documents/record').then(data=>{
    record=data;el('document-title').textContent=data.title||data.id;el('document-byline').textContent=[data.id,...(data.authors||[])].join(' · ');
    el('document-abstract').textContent=data.abstract||'No abstract was provided by the source.';tree.update(data,'record');
    el('document-chat').href='/chat?'+new URLSearchParams(reference);el('document-chat').hidden=false;
    el('document-analysis').hidden=false;
    // Server-provided links are restricted to supported sources; still validate protocols in the browser.
    for(const [id,url] of [['document-source',data.sourceUrl],['pdf-original',data.pdfUrl]]){try{const u=new URL(url);if(u.protocol==='https:'){el(id).href=u.href;el(id).hidden=false;}}catch{}}
    status(data.recordScope||'Source record loaded.');show(params.get('view')||'record');
    if(data.pdfUrl){
      pdfContext=new TurncoatPdfContext(reference,state=>{
        el('text-scope').textContent=state.description;
        el('load-pdf-text').disabled=state.state!=='error';
        el('load-pdf-text').textContent=state.state==='ready'?'PDF context ready':state.state==='error'?'Retry PDF context':'Preparing PDF context…';
        if(state.data)el('document-text').textContent=state.data.text;
        status(state.description,state.state==='error');
      });
      pdfContext.prepare();
    }else{el('load-pdf-text').disabled=true;el('text-scope').textContent='No PDF is listed for this record. Chat can use its metadata.';}
  }).catch(error=>{el('document-title').textContent='Document unavailable';status(error.message,true);});
})();

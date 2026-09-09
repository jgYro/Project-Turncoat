/* Dataset-scoped investigation tabs. Source text is rendered with DOM text nodes. */
(() => {
  'use strict';
  const {make,button,request,api,getCatalog,link,table,note,bucketName,renderAiFindings}=TurncoatResearch;
  const el=id=>document.getElementById(id),tabs=new Map(),bar=el('workspace-tabs'),area=el('drill-workspace');
  const authors=new Set(['Name mention','Name search','Person','Author','Inventor']);
  const supported=node=>node&&(authors.has(node.label)||['Paper','Patent'].includes(node.label));
  let active='graph',serial=0,menuOrigin=null,menuAction=null;
  const storageKey='turncoat-drill-tabs-v1';
  function save(){try{sessionStorage.setItem(storageKey,JSON.stringify({active,tabs:[...tabs.values()].map(t=>t.descriptor)}));}catch{}}
  function status(node,text,error=false){node.textContent=text;node.classList.toggle('error',error);}
  function select(key,focus=false){
    active=key;const graph=key==='graph';el('graph-workspace').hidden=!graph;document.querySelector('.mission-bar').hidden=!graph;area.hidden=graph;
    el('graph-tab').setAttribute('aria-selected',String(graph));el('graph-tab').tabIndex=graph?0:-1;
    for(const [id,tab] of tabs){tab.panel.hidden=id!==key;tab.button.setAttribute('aria-selected',String(id===key));tab.button.tabIndex=id===key?0:-1;}
    const tab=tabs.get(key);window.TurncoatJobs?.setViewing(tab&&!authors.has(tab.descriptor.label)?tab.ref:null);
    if(tab&&!tab.loaded){tab.loaded=true;tab.ready=tab.load();}
    const selected=tab?.button||el('graph-tab');
    if(focus)selected.focus({preventScroll:true});
    selected.scrollIntoView({block:'nearest',inline:'nearest'});
    document.dispatchEvent(new CustomEvent('turncoat:workspace-view',{detail:{graph}}));save();
  }
  function close(key){
    const tab=tabs.get(key);if(!tab)return;tab.dispose?.();tab.panel.remove();tab.wrap.remove();tabs.delete(key);
    if(active===key)select('graph',true);else save();
  }
  function add(descriptor,activate=true,automatic=false){
    const key=JSON.stringify([descriptor.dataset,descriptor.id]);
    if(tabs.has(key)){const tab=tabs.get(key);if(activate)select(key,true);if(automatic)tab.startAutomatic?.();return tab;}
    if(tabs.size>=12){status(el('drill-notice'),'Close a drill-down tab before opening another.',true);el('drill-notice').hidden=false;return;}
    const uid='drill-'+(++serial),wrap=make('div','workspace-tab'),tabButton=button(descriptor.title,()=>select(key),'workspace-tab-button');
    tabButton.id=uid;tabButton.setAttribute('role','tab');tabButton.setAttribute('aria-controls',uid+'-panel');tabButton.setAttribute('aria-selected','false');tabButton.tabIndex=-1;tabButton.title=descriptor.title;
    const remove=button('×',()=>close(key),'workspace-tab-close');remove.setAttribute('aria-label','Close '+descriptor.title);
    wrap.append(tabButton,remove);bar.append(wrap);
    const panel=make('section','drill-panel');panel.id=uid+'-panel';panel.setAttribute('role','tabpanel');panel.setAttribute('aria-labelledby',uid);panel.hidden=true;area.append(panel);
    const tab={key,descriptor,wrap,button:tabButton,panel,ref:{dataset:descriptor.dataset,node:descriptor.id},loaded:false,automatic};tabs.set(key,tab);
    if(authors.has(descriptor.label))authorTab(tab);else documentTab(tab);
    if(activate)select(key,true);else save();return tab;
  }
  function openNode(node,dataset){
    if(!supported(node)||!dataset)return;
    add({dataset,id:node.id,label:node.label,title:String(node.properties?.name||node.properties?.title||node.id).slice(0,160)},true,true);
  }
  async function openReference(reference,reportId){
    const ref={dataset:reference.dataset,node:reference.node};
    const data=await api('document',ref);
    const tab=add({dataset:ref.dataset,id:ref.node,label:data.reference.source==='arxiv'?'Paper':'Patent',title:data.record.title},true,false);
    if(!tab)return;await tab.ready;if(reportId)await tab.openReport(reportId);
  }
  function header(tab,kind){
    const head=make('header','research-heading'),copy=make('div');copy.append(make('p','eyebrow',kind),make('h2','',tab.descriptor.title),note(tab.descriptor.dataset));head.append(copy);tab.panel.append(head);return head;
  }
  function authorTab(tab){
    header(tab,'AUTHOR / SAVED EVIDENCE');
    tab.panel.append(note('Source-listed documents and name-search candidates are shown separately. A name match does not establish a shared identity.'));
    const toolbar=make('div','research-toolbar'),filter=make('input'),source=make('select');filter.type='search';filter.placeholder='Filter loaded titles…';filter.setAttribute('aria-label','Filter loaded titles');source.setAttribute('aria-label','Publication type');
    for(const [value,label] of [['','All sources'],['Paper','Papers'],['Patent','Patents']]){const option=make('option','',label);option.value=value;source.append(option);}
    const refresh=button('Refresh saved',()=>load()),search=button('Search both providers',searchMore,'research-primary');search.disabled=true;
    toolbar.append(filter,source,refresh,search);tab.panel.append(toolbar);
    const message=make('p','research-status');message.setAttribute('role','status');tab.panel.append(message);
    const scroll=make('div','research-scroll'),t=table(['Title','Source','Evidence basis','Date','']);scroll.tabIndex=0;scroll.setAttribute('aria-label','Saved papers and patents');scroll.append(t.node);tab.panel.append(scroll);
    const more=button('More saved documents',()=>load(true));more.hidden=true;tab.panel.append(more);
    let rows=[],page=null,epoch=0,timer=null,disposed=false;
    function render(){
      t.body.replaceChildren();const q=filter.value.trim().toLocaleLowerCase();
      for(const item of rows.filter(x=>(!source.value||x.node.label===source.value)&&String(x.node.properties.title||x.node.id).toLocaleLowerCase().includes(q))){
        const node=item.node,record=node.properties.providerRecord||{},row=make('tr'),title=make('td'),titleButton=button(node.properties.title||node.id,()=>openNode(node,tab.ref.dataset),'table-title');
        title.append(titleButton,note(node.properties.publicationNumber||node.properties.arxivId||node.id));
        const basis=make('td');basis.append(make('span','research-tag '+(item.basis==='source_listed'?'listed':'candidate'),item.basis==='source_listed'?'Source-listed':'Name-search candidate'));
        const action=make('td');action.append(button('Open →',()=>openNode(node,tab.ref.dataset)));
        row.append(title,make('td','',node.label==='Paper'?'arXiv':'Google Patents'),basis,make('td','',record.publication_date||record.published||record.updated||'—'),action);t.body.append(row);
      }
      if(!rows.length){const row=make('tr'),cell=make('td','','No saved documents yet. Search this name or expand its saved relationships.');cell.colSpan=5;row.append(cell);t.body.append(row);}
    }
    async function load(append=false){
      clearTimeout(timer);const current=++epoch;refresh.disabled=true;more.disabled=true;status(message,'Loading saved relationships…');
      try{
        const data=await api('author',{...tab.ref,offset:append?page?.nextOffset||0:0});if(disposed||current!==epoch)return;
        rows=append?rows.concat(data.rows):data.rows;page=data.meta;more.hidden=!page.hasMore;
        search.disabled=!data.canSearch||data.job?.state==='running'||data.job?.requests>=data.job?.limits?.maxRequests;
        search.title=data.canSearch?'Uses this investigation’s existing request budget and completed query cache.':'Provider search requires a source-listed name in an investigation.';
        status(message,rows.length+' of '+page.total+' saved documents loaded'+(data.job?.state==='running'?' · Investigation running; results update here.':'.'));render();
        if(data.job?.state==='running')timer=setTimeout(()=>load(),1500);
      }catch(error){if(current===epoch&&!disposed)status(message,error.message,true);}
      finally{if(current===epoch){refresh.disabled=false;more.disabled=false;}}
    }
    async function searchMore(){
      search.disabled=true;status(message,'Starting name searches in Google Patents and arXiv…');
      try{await request('/api/investigations/'+encodeURIComponent(tab.ref.dataset)+'/expand',{node:tab.ref.node});await load();}
      catch(error){status(message,error.message,true);search.disabled=false;}
    }
    filter.addEventListener('input',render);source.addEventListener('change',render);tab.load=load;tab.dispose=()=>{disposed=true;clearTimeout(timer);};
  }
  function renderReport(container,report){
    container.replaceChildren();const evidence=report.evidence,result=report.result;
    container.append(note(report.createdAt+' · '+(report.model||result.version||'')+' · '+evidence.scope));
    if(evidence.warning)container.append(make('p','research-warning','PDF unavailable: '+evidence.warning));
    if(report.kind==='keywords'){
      container.append(note(result.totalMatches+' literal matches · '+result.tags.length+' tags. Tags identify terms; they do not establish military end use.'));
      if(result.truncated)container.append(note('Showing the first 500 match excerpts. Tag counts cover the full scanned text.'));
      for(const bucket of ['direct','indirect','context','custom']){
        const tags=result.tags.filter(x=>x.bucket===bucket);if(bucket==='custom'&&!tags.length)continue;
        const section=make('section','finding-section');section.append(make('h3','',bucketName(bucket)));
        if(bucket==='context')section.append(note('Broad or ambiguous vocabulary. These matches alone do not establish AI, security, or military relevance.'));
        const chips=make('div','research-tags');for(const tag of tags)chips.append(make('span','research-tag '+bucket,tag.tag+' · '+tag.count));section.append(chips);
        const hits=result.hits.filter(x=>x.bucket===bucket);if(!hits.length)section.append(note('No matching terms in the supplied evidence.'));
        for(const hit of hits){const card=make('article','finding-card');card.append(make('h4','',hit.tag),note(hit.field+' · bytes '+hit.startByte+'–'+hit.endByte+' · '+hit.category));
          const quote=make('blockquote'),index=Number.isInteger(hit.excerptStartByte)?new TextDecoder().decode(new TextEncoder().encode(hit.excerpt).slice(0,hit.startByte-hit.excerptStartByte)).length:hit.excerpt.indexOf(hit.matched);if(index>=0){quote.append(document.createTextNode(hit.excerpt.slice(0,index)),make('mark','',hit.matched),document.createTextNode(hit.excerpt.slice(index+hit.matched.length)));}else quote.textContent=hit.excerpt;
          card.append(quote);section.append(card);
        }container.append(section);
      }
    }else{
      container.append(note('AI interpretations. “Quote located” means the passage exists in the supplied text; it does not validate the model’s relevance assessment.'));
      if(result.formatError)container.append(make('p','research-warning',result.formatError));
      if(report.finishReason==='length')container.append(make('p','research-warning','The model reached its output limit; this review may be incomplete.'));
      renderAiFindings(container,result,evidence);
      const raw=make('details','research-card');raw.append(make('summary','','Raw AI reply'),make('pre','research-raw',report.rawResponse));container.append(raw);
    }
    const source=make('details','research-card');source.append(make('summary','','Saved evidence snapshot'));const host=make('div');source.append(host);new TurncoatJsonTree(host).update(evidence,report.id);container.append(source);
  }
  function documentTab(tab){
    const head=header(tab,tab.descriptor.label.toUpperCase()+' / DOCUMENT SCREENING');
    const message=make('p','research-status');message.setAttribute('role','status');tab.panel.append(message);
    const layout=make('div','document-drill-layout'),controls=make('aside','drill-controls'),right=make('div','drill-results');layout.append(controls,right);tab.panel.append(layout);
    const queryLabel=make('label','','Additional literal phrase'),query=make('input');query.type='search';query.maxLength=160;query.placeholder='e.g. carbon fiber or 碳纤维';query.id=tab.panel.id+'-query';queryLabel.htmlFor=query.id;
    const pdfLabel=make('label','research-check'),includePdf=make('input');includePdf.type='checkbox';includePdf.checked=true;pdfLabel.append(includePdf,document.createTextNode('Include PDF text in keyword scan'));
    const pdfStatus=note(''),retryPdf=button('Retry PDF context',()=>pdfContext?.prepare(true));pdfStatus.setAttribute('role','status');retryPdf.hidden=true;
    const scan=button('Scan keywords',()=>run('scan'),'research-primary');
    const presetLabel=make('label','','AI review query'),preset=make('select');preset.id=tab.panel.id+'-preset';presetLabel.htmlFor=preset.id;
    const prompt=make('p','research-note'),review=button('Run AI review',()=>run('review'),'research-primary'),model=note('');
    const historyLabel=make('label','','Saved reports'),history=make('select');history.id=tab.panel.id+'-history';historyLabel.htmlFor=history.id;history.setAttribute('aria-label','Saved reports');
    const historyMore=button('More saved reports',()=>loadHistory(true));historyMore.hidden=true;
    const download=button('Download report JSON',()=>{if(!currentReport)return;const blob=new Blob([JSON.stringify(currentReport,null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),a=make('a');a.href=url;a.download=currentReport.id+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);});download.disabled=true;
    controls.append(make('h3','','PDF context'),pdfStatus,retryPdf,make('h3','','Deterministic keywords'),queryLabel,query,pdfLabel,scan,link('View keyword rules →','/settings#rules'),make('h3','','AI analysis'),presetLabel,preset,prompt,review,model,note('PDF text is required. Reviews separate explicit references from tentative dual-use applications.'),link('View all AI queries →','/settings#queries'),make('h3','','Saved work'),historyLabel,history,historyMore,download);
    const sub=make('nav','research-subtabs');sub.setAttribute('aria-label','Document drill-down views');sub.setAttribute('role','tablist');right.append(sub);
    const panes={},buttons={},reportsByKind={},seenReports=new Set(),loadingReports=new Set();let recordData=null,catalog=null,currentReport=null,pdfLoaded=false,pdfContext=null,disposed=false,savedPage=null,currentView='keywords',submitting=null;
    for(const [key,label] of [['keywords','Keywords'],['ai','AI review'],['pdf','PDF'],['source','Source']]){
      const pane=make('section','drill-result-pane research-scroll');pane.id=tab.panel.id+'-'+key;pane.hidden=key!=='keywords';pane.tabIndex=0;pane.setAttribute('role','tabpanel');right.append(pane);panes[key]=pane;
      const b=button(label,()=>show(key));b.id=pane.id+'-tab';b.setAttribute('role','tab');b.setAttribute('aria-controls',pane.id);b.setAttribute('aria-selected',String(key==='keywords'));b.tabIndex=key==='keywords'?0:-1;pane.setAttribute('aria-labelledby',b.id);sub.append(b);buttons[key]=b;
    }
    panes.keywords.append(note('Keyword results and their PDF evidence are saved locally.'));panes.ai.append(note('The automatic review uses Defense and wartime relevance. Choose another query to run an additional review.'));
    sub.addEventListener('keydown',event=>{const keys=Object.keys(buttons),index=keys.findIndex(k=>buttons[k]===event.target);if(index<0||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;event.preventDefault();const i=event.key==='Home'?0:event.key==='End'?3:(index+(event.key==='ArrowRight'?1:3))%4;show(keys[i]);buttons[keys[i]].focus();});
    const pending=job=>['queued','preparing','running'].includes(job.state);
    const ownJobs=()=>window.TurncoatJobs?.items().filter(j=>j.dataset===tab.ref.dataset&&j.node===tab.ref.node)||[];
    function controlsState(){const jobs=ownJobs();scan.disabled=!!submitting||!recordData||jobs.some(j=>j.kind==='keywords'&&pending(j));review.disabled=!!submitting||!recordData||jobs.some(j=>j.kind==='ai'&&pending(j));preset.disabled=!catalog;history.disabled=!recordData;}
    function savedOptions(data,append=false){
      savedPage=data;if(!append){history.replaceChildren();const option=make('option','','Select a saved report…');option.value='';history.append(option);}
      for(const item of data.items){const option=make('option','',item.createdAt+' · '+(item.kind==='ai'?item.preset:'Keywords'+(item.query?' · '+item.query:'')));option.value=item.id;history.append(option);}historyMore.hidden=!data.hasMore;
    }
    async function loadHistory(append=false){
      historyMore.disabled=true;
      try{savedOptions(await api('history',{...tab.ref,offset:append?savedPage?.nextOffset||0:0}),append);if(currentReport)history.value=currentReport.id;}
      catch(error){status(message,error.message,true);}finally{historyMore.disabled=false;}
    }
    function display(report,activate=true){const key=report.kind==='keywords'?'keywords':'ai';reportsByKind[key]=report;renderReport(panes[key],report);seenReports.add(report.id);if(activate)show(key);else if(currentView===key){currentReport=report;download.disabled=false;}}
    tab.openReport=async id=>{const report=await api('report',{...tab.ref,report:id});if(disposed)return;display(report);history.value=id;};
    async function updateJobs(){
      if(disposed||!recordData)return;
      const jobs=ownJobs(),latest=['keywords','ai'].map(kind=>jobs.filter(j=>j.kind===kind).sort((a,b)=>b.createdAt.localeCompare(a.createdAt))[0]).filter(Boolean);
      const activeJobs=jobs.filter(pending),labels={queued:'queued',preparing:'preparing PDF',running:'running',succeeded:'complete',failed:'failed',interrupted:'interrupted'};
      if(latest.length){status(message,latest.map(j=>(j.kind==='ai'?'AI review':'Keywords')+': '+labels[j.state]+(j.error?' — '+j.error:'')).join(' · '),latest.some(j=>['failed','interrupted'].includes(j.state)));message.classList.toggle('research-working',activeJobs.length>0);}
      for(const job of latest){
        buttons[job.kind].textContent=(job.kind==='ai'?'AI review':'Keywords')+(pending(job)?' ◌':'');
        if(!job.reportId||seenReports.has(job.reportId)||loadingReports.has(job.reportId))continue;
        loadingReports.add(job.reportId);
        try{const report=await api('report',{...tab.ref,report:job.reportId});if(!disposed){display(report,false);await loadHistory();}}
        catch(error){if(!disposed)status(message,error.message,true);}
        finally{loadingReports.delete(job.reportId);}
      }
      controlsState();
    }
    document.addEventListener('turncoat:analysis-jobs',updateJobs);
    async function show(key){
      currentView=key;
      if(key==='keywords'||key==='ai'){currentReport=reportsByKind[key]||null;download.disabled=!currentReport;if(currentReport)history.value=currentReport.id;}
      for(const name of Object.keys(panes)){panes[name].hidden=name!==key;buttons[name].setAttribute('aria-selected',String(name===key));buttons[name].tabIndex=name===key?0:-1;}
      if(key!=='pdf'||!recordData||pdfLoaded)return;
      if(!recordData.record.pdfUrl){panes.pdf.replaceChildren(note('No PDF is listed for this record.'));return;}
      pdfLoaded=true;panes.pdf.replaceChildren(note('Loading PDF…'));
      try{await request('/api/documents/prepare-pdf',recordData.reference);const frame=make('iframe','drill-pdf');frame.title='Source PDF';frame.src='/api/documents/pdf?'+new URLSearchParams({source:recordData.reference.source,id:recordData.reference.id});panes.pdf.replaceChildren(frame);}
      catch(error){pdfLoaded=false;panes.pdf.replaceChildren(note(error.message),button('Retry PDF',()=>show('pdf')));}
    }
    async function run(action){
      if(submitting||!recordData)return;submitting=action;controlsState();show(action==='review'?'ai':'keywords');status(message,'Queuing background analysis…');
      try{
        await window.TurncoatJobs.start(tab.ref,{kind:action==='review'?'ai':'keywords',query:query.value.trim(),includePdf:includePdf.checked,preset:preset.value,force:true});
        await updateJobs();
      }catch(error){if(!disposed)status(message,error.message,true);}
      finally{submitting=null;controlsState();}
    }
    tab.startAutomatic=async()=>{
      tab.automatic=true;if(!recordData)return;
      try{await window.TurncoatJobs.start(tab.ref);tab.automatic=false;await updateJobs();}
      catch(error){if(!disposed)status(message,error.message,true);}
    };
    preset.addEventListener('change',()=>{prompt.textContent=catalog.presets.find(x=>x.id===preset.value)?.query||'';});
    history.addEventListener('change',async()=>{if(!history.value)return;const id=history.value;try{const report=await api('report',{...tab.ref,report:id});if(history.value===id&&!disposed){display(report);status(message,'Loaded saved report. No provider or model request was made.');}}catch(error){status(message,error.message,true);}});
    tab.load=async()=>{
      status(message,'Loading saved document…');controlsState();
      try{
        const [data,rules,config]=await Promise.all([api('document',tab.ref),getCatalog(),request('/api/llm/config')]);if(disposed)return;
        recordData=data;catalog=rules;head.querySelector('h2').textContent=data.record.title;head.append(link('Open document reader ↗','/document?'+new URLSearchParams(data.reference)));
        for(const item of catalog.presets){const option=make('option','',item.label);option.value=item.id;preset.append(option);}prompt.textContent=catalog.presets[0].query;model.textContent=config.model+' · '+config.baseUrl;
        savedOptions(data.history);panes.source.append(note(data.record.recordScope||'Saved source record.'));const tree=make('div');panes.source.append(tree);new TurncoatJsonTree(tree).update(data.record,tab.key);
        status(message,'Ready · '+(data.record.recordScope||'Saved metadata loaded.')+' PDF operations use a bounded text extract.');
        if(data.record.pdfUrl){
          pdfContext=new TurncoatPdfContext(data.reference,state=>{
            if(disposed)return;pdfStatus.textContent=state.description;
            pdfStatus.classList.toggle('research-warning',state.state==='error');
            pdfStatus.classList.toggle('research-working',state.state==='loading');
            retryPdf.hidden=state.state!=='error';
          });
          pdfContext.prepare();
        }else pdfStatus.textContent='No PDF is listed. Keyword scans can use metadata; AI review requires PDF text.';
        show(currentView);if(tab.automatic)await tab.startAutomatic();else await updateJobs();
      }catch(error){status(message,error.message,true);const retry=button('Retry loading',()=>{retry.remove();tab.load();});panes.keywords.append(retry);}
      finally{controlsState();}
    };
    tab.dispose=()=>{disposed=true;document.removeEventListener('turncoat:analysis-jobs',updateJobs);};controlsState();
  }
  const menu=el('node-context-menu'),menuButton=el('context-drilldown');
  function hideMenu(restore=false){menu.hidden=true;if(restore)menuOrigin?.focus();menuAction=null;}
  function contextMenu(event,node,dataset,origin){
    if(!supported(node))return;event.preventDefault();event.stopPropagation();menuOrigin=origin;menuAction=()=>openNode(node,dataset);menuButton.textContent=authors.has(node.label)?'Drill down · papers & patents':'Drill down · keywords & AI';
    menu.hidden=false;const rect=origin.getBoundingClientRect(),x=event.type==='keydown'?rect.x:event.clientX,y=event.type==='keydown'?rect.bottom:event.clientY;
    menu.style.left=Math.max(8,Math.min(x,innerWidth-menu.offsetWidth-8))+'px';menu.style.top=Math.max(8,Math.min(y,innerHeight-menu.offsetHeight-8))+'px';menuButton.focus();
  }
  menuButton.addEventListener('click',()=>{const action=menuAction;hideMenu();action?.();});
  document.addEventListener('pointerdown',event=>{if(!menu.hidden&&!menu.contains(event.target))hideMenu();});
  document.addEventListener('keydown',event=>{if(!menu.hidden&&['Escape','Tab'].includes(event.key)){if(event.key==='Escape')event.preventDefault();hideMenu(true);}});
  window.addEventListener('resize',()=>hideMenu());
  el('graph-tab').addEventListener('click',()=>select('graph'));
  bar.addEventListener('keydown',event=>{
    const buttons=[el('graph-tab'),...[...tabs.values()].map(t=>t.button)],index=buttons.indexOf(event.target);if(index<0)return;
    if(event.key==='Delete'&&active!=='graph'){event.preventDefault();close(active);return;}
    if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;event.preventDefault();const next=event.key==='Home'?0:event.key==='End'?buttons.length-1:(index+(event.key==='ArrowRight'?1:buttons.length-1))%buttons.length;buttons[next].click();buttons[next].focus();
  });
  window.TurncoatDrilldown={openNode,openReference,contextMenu,supported};
  try{
    const saved=JSON.parse(sessionStorage.getItem(storageKey)||'null');
    if(Array.isArray(saved?.tabs))for(const item of saved.tabs.slice(0,12))if(typeof item.dataset==='string'&&/^[\w-]{1,64}$/.test(item.dataset)&&typeof item.id==='string'&&item.id.length<=512&&typeof item.title==='string'&&supported(item))add(item,false);
    select(tabs.has(saved?.active)?saved.active:'graph');
  }catch{select('graph');}
  const params=new URLSearchParams(location.search);
  if(params.has('dataset')&&params.has('document'))openReference({dataset:params.get('dataset'),node:params.get('document')},params.get('report')).catch(error=>{status(el('drill-notice'),error.message,true);el('drill-notice').hidden=false;});
})();

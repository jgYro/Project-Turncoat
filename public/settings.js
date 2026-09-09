(() => {
  'use strict';
  const {make,request,api,getCatalog,link,table,note,bucketName}=TurncoatResearch;
  const el=id=>document.getElementById(id),content=el('settings-content');
  let view=['rules','queries','searches'].includes(location.hash.slice(1))?location.hash.slice(1):'rules',catalog,searches=[],page=null,epoch=0;
  function status(text,error=false){el('settings-status').textContent=text;el('settings-status').classList.toggle('error',error);}
  function render(){
    content.replaceChildren();const query=el('settings-filter').value.trim().toLocaleLowerCase();
    const matches=value=>JSON.stringify(value).toLocaleLowerCase().includes(query);
    if(view==='rules'&&catalog){
      content.append(note(catalog.keywords.version+' · '+catalog.keywords.description),note('Literal matching: ASCII case-insensitive with Latin word boundaries; Chinese phrases match exactly. Direct terms are lexical signals, not a conclusion about end use.'));
      if(catalog.example&&!query){const example=catalog.example,card=make('article','research-card');card.append(make('h2','','Public paper example'),link(example.title,example.sourceUrl),note(example.scope));const tags=make('div','research-tags');for(const tag of example.scan.tags)tags.append(make('span','research-tag '+tag.bucket,tag.tag));card.append(tags,link('Open paper in document reader →','/document?source=arxiv&id='+encodeURIComponent(example.id)));content.append(card);}
      const t=table(['Classification','Tag / category','Literal terms']);
      for(const rule of catalog.keywords.rules.filter(matches)){const row=make('tr'),type=make('td');type.append(make('span','research-tag '+rule.bucket,bucketName(rule.bucket)));const title=make('td','',rule.tag);title.append(note(rule.category));row.append(type,title,make('td','rule-terms',rule.terms.join(' · ')));t.body.append(row);}content.append(t.node);
      status(catalog.keywords.rules.length+' active keyword rules · '+t.body.children.length+' shown');
    }else if(view==='queries'&&catalog){
      content.append(note(catalog.promptVersion+' · Investigate automatically starts the Defense and wartime relevance query and keyword analysis in the background. Other queries can be run from the document tab. AI reviews require extracted PDF text.'),link('Docling OCR setup and extraction limits →','/docs/document-extraction.md'));
      for(const preset of catalog.presets.filter(matches)){const card=make('article','research-card');card.append(make('h2','',preset.label),make('p','',preset.query));content.append(card);}
      const instructions=make('details','research-card');instructions.append(make('summary','','Shared review instructions'),make('pre','research-raw',catalog.instructions));content.append(instructions);status(catalog.presets.length+' review queries');
    }else if(view==='searches'){
      content.append(note('Saved author/inventor name queries from investigations. arXiv searches author names; Google Patents searches inventor names. Results are candidates, not verified identities or university affiliations.'));
      const t=table(['Name / provider query','Dataset','State','Results','Started']);
      for(const item of searches.filter(matches)){
        const data=item.search,row=make('tr'),name=make('td','',data.queryName||data.name||item.node);
        name.append(note(data.provider+' · '+(data.field||'name')));
        if(data.queryUrl)name.append(link('View provider query ↗',data.queryUrl));
        const state=make('td','',data.state||'unknown');if(data.error)state.append(note(data.error.split('Async traceback:')[0]));
        row.append(name,make('td','',item.dataset),state,make('td','',String(data.returned??'—')+' / '+String(data.total??'—')+(data.hasMore?' · more available':'')),make('td','',data.startedAt||'—'));t.body.append(row);
      }
      content.append(t.node);if(!searches.length)content.append(note('No saved searches in this dataset.'));
      status(searches.length+' of '+(page?.total||0)+' saved searches loaded · '+t.body.children.length+' shown');
    }
    el('settings-more').hidden=view!=='searches'||!page?.hasMore;
  }
  async function load(more=false){
    const current=++epoch;status('Loading…');el('settings-refresh').disabled=true;el('settings-more').disabled=true;
    try{
      if(view==='searches'){
        const data=await api('searches',{dataset:el('settings-dataset').value,offset:more?page?.nextOffset||0:0});
        if(current!==epoch)return;page=data;searches=more?searches.concat(data.items):data.items;
      }else{const data=await getCatalog();if(current!==epoch)return;catalog=data;}
      render();
    }catch(error){if(current===epoch)status(error.message,true);}
    finally{if(current===epoch){el('settings-refresh').disabled=false;el('settings-more').disabled=false;}}
  }
  function select(name){
    view=name;location.hash=name;el('settings-filter').value='';content.replaceChildren();
    el('settings-dataset').hidden=name!=='searches';el('settings-more').hidden=true;
    for(const key of ['rules','queries','searches']){const tab=el('settings-'+key);tab.setAttribute('aria-selected',String(key===name));tab.tabIndex=key===name?0:-1;}
    content.setAttribute('aria-labelledby','settings-'+name);load();
  }
  const names=['rules','queries','searches'];
  for(const name of names){const tab=el('settings-'+name);tab.addEventListener('click',()=>select(name));tab.addEventListener('keydown',event=>{if(['ArrowLeft','ArrowRight','Home','End'].includes(event.key)){event.preventDefault();const i=event.key==='Home'?0:event.key==='End'?2:(names.indexOf(name)+(event.key==='ArrowRight'?1:2))%3;select(names[i]);el('settings-'+names[i]).focus();}});}
  el('settings-filter').addEventListener('input',render);el('settings-refresh').addEventListener('click',()=>load());el('settings-more').addEventListener('click',()=>load(true));el('settings-dataset').addEventListener('change',()=>load());
  request('/api/datasets').then(data=>{for(const dataset of data.datasets){const option=make('option','',dataset.id);option.value=dataset.id;el('settings-dataset').append(option);}}).catch(error=>status(error.message,true));
  select(view);
})();

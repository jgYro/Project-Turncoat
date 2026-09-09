// Playwright page function. Preview on 5010; provider/model operations are mocked.
async (page) => {
  const c=await page.context().browser().newContext({viewport:{width:1440,height:1000},reducedMotion:'reduce'}),p=await c.newPage(),errors=[],requests=[];
  const assert=(value,message)=>{if(!value)throw new Error(message);};
  const author={id:'author',label:'Name mention',properties:{name:'杨超',originalName:'杨超'}};
  const patent={id:'patent',label:'Patent',properties:{title:'Carbon fiber for civil structures',publicationNumber:'US1234567B1',sourceUrl:'https://patents.google.com/patent/US1234567B1/en'}};
  const paper={id:'paper',label:'Paper',properties:{title:'Material inspection and civilian structures',arxivId:'1706.03762v7',sourceUrl:'https://arxiv.org/abs/1706.03762v7'}};
  const nodes=[patent,author,paper],links=[{id:'list',source:'patent',target:'author',label:'lists_inventor',properties:{}},{id:'hit',source:'author',target:'paper',label:'name_search_hit',properties:{}}];
  const job={seed:'patent',publicationNumber:'US1234567B1',state:'completed',requests:3,limits:{maxNodes:500,maxEdges:1000,maxRequests:40},events:[]};
  const reports=[];let expansions=0,modelCalls=0,failReview=false;
  const recordFor=oid=>({source:oid==='paper'?'arxiv':'patents',id:oid==='paper'?'1706.03762v7':'US1234567B1',title:oid==='paper'?paper.properties.title:patent.properties.title,authors:['杨超'],abstract:'Carbon fiber is used in civil structures. No military use is established.',sourceUrl:oid==='paper'?paper.properties.sourceUrl:patent.properties.sourceUrl,pdfUrl:'https://patentimages.storage.googleapis.com/fixture.pdf',recordScope:'Saved synthetic source metadata.'});
  const history=oid=>({items:reports.filter(x=>x.node===oid).map(x=>({id:x.id,kind:x.kind,createdAt:x.createdAt,preset:x.preset,query:x.query})).reverse(),total:reports.filter(x=>x.node===oid).length,hasMore:false,nextOffset:reports.length});
  const analysisJobs=[];
  function makeReport(body,kind){
      const record=recordFor(body.node),report={id:'report-'+reports.length,dataset:body.dataset,node:body.node,kind,preset:body.preset,query:body.query,createdAt:'2026-09-09T12:00:00Z',evidence:{reference:{...body,source:record.source,id:record.id},record,fields:{pdf:record.abstract},scope:'Synthetic bounded PDF extract.',pdfIncluded:true},model:kind==='ai'?'granite4.1:8b':undefined,finishReason:'stop'};
      report.result=kind==='keywords'?{version:'fixture-v1',totalMatches:1,truncated:false,tags:[{id:'carbon-fiber',tag:'Carbon fiber',bucket:'indirect',category:'Materials',count:1}],hits:[{rule:'carbon-fiber',tag:'Carbon fiber',category:'Materials',bucket:'indirect',field:'pdf',matched:'Carbon fiber',excerpt:record.abstract,startByte:0,endByte:12}]}:{direct:[],indirect:[{finding:'A dual-use material',field:'pdf',quote:record.abstract,relevance:'Potential material relevance only.',caveat:'Civilian use is explicit; military use is not established.',startByte:0,endByte:record.abstract.length,citationStatus:'quote_located'}],unverified:[],limitations:'Synthetic partial PDF.',formatError:''};
      if(kind==='ai'){
        report.result.indirect[0].finding='**A dual-use material**';
        report.result.indirect[0].relevance='Potential **material relevance** only. [Source](https://arxiv.org/abs/1706.03762v7)';
        report.result.unverified=[{bucket:'indirect',reason:'The quoted passage was not located in the supplied field.',output:{finding:'**Unverified candidate** <img src=x onerror=alert(1)>',field:'pdf',quote:'Original quotation: 电磁干扰 **literal marks**',relevance:'A tentative *interpretation*.',caveat:'Requires source verification.'}}];
      }
      report.rawResponse=JSON.stringify(report.result);reports.push(report);return report;
  }
  p.on('pageerror',e=>errors.push(e.message));
  await c.route('**/api/**',async route=>{
    const url=route.request().url(),body=route.request().method()==='POST'?route.request().postDataJSON():null;
    const reply=(data,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(data)});
    requests.push({url,body});
    if(url.endsWith('/api/analysis/jobs')){
      if(!body){for(const task of analysisJobs.filter(j=>j.state==='queued')){if(task.kind==='ai')modelCalls++;if(task.kind==='ai'&&failReview){task.state='failed';task.error='Synthetic model unavailable.';}else{task.reportId=makeReport({...task.request,preset:task.preset,includePdf:true},task.kind).id;task.state='succeeded';}}return reply({jobs:analysisJobs,active:0});}
      const fresh=[];
      for(const kind of body.kind?[body.kind]:['keywords','ai']){
        const previous=analysisJobs.find(j=>j.node===body.node&&j.kind===kind);
        if(previous&&!body.force){fresh.push(previous);continue;}
        const task={id:'job-'+analysisJobs.length,dataset:body.dataset,node:body.node,title:recordFor(body.node).title,kind,state:'queued',preset:kind==='ai'?(body.preset||'wartime'):'',createdAt:new Date().toISOString(),reportId:''};
        task.request=body;analysisJobs.push(task);fresh.push(task);
      }
      return reply({jobs:fresh},202);
    }
    if(url.endsWith('/api/drilldown/catalog'))return route.continue();
    if(url.endsWith('/api/health'))return reply({fts5:true,limits:{neighborLimit:100,maxNodes:500,maxEdges:1000}});
    if(url.endsWith('/api/datasets'))return reply({datasets:[{id:'demo',nodes:3}]});
    if(url.endsWith('/api/investigations'))return reply({investigations:[{id:'demo',job}]});
    if(url.endsWith('/api/investigations/demo'))return reply({id:'demo',job,busy:false,nodes,links});
    if(url.endsWith('/api/investigations/demo/expand')){expansions++;return reply({id:'demo'});}
    if(url.endsWith('/api/llm/config'))return reply({model:'granite4.1:8b',baseUrl:'http://fixture/v1'});
    if(url.endsWith('/api/documents/prepare-pdf'))return reply({ready:true});
    if(url.endsWith('/api/documents/text'))return reply({text:'Carbon fiber is used in civil structures.',scope:'Synthetic bounded PDF extract.'});
    if(url.includes('/api/documents/pdf?'))return route.fulfill({path:'tests/fixtures/document.pdf',contentType:'application/pdf'});
    if(url.endsWith('/api/drilldown/author'))return reply({author,rows:[{node:patent,basis:'source_listed'},{node:paper,basis:'name_search_candidate'}],meta:{total:2,returned:2,nextOffset:2,hasMore:false},canSearch:true,job});
    if(url.endsWith('/api/drilldown/document')){const record=recordFor(body.node);return reply({record,reference:{...body,source:record.source,id:record.id},history:history(body.node)});}
    if(url.endsWith('/api/drilldown/history'))return reply(history(body.node));
    if(url.endsWith('/api/drilldown/report'))return reply(reports.find(x=>x.id===body.report&&x.node===body.node));
    if(url.endsWith('/api/drilldown/searches'))return reply({items:[{dataset:'demo',node:'query',search:{queryName:'杨超 <img src=x>',provider:'Google Patents',field:'inventor',state:'completed',returned:2,total:12,hasMore:true,startedAt:'2026-09-09',queryUrl:'https://patents.google.com/?inventor=example'}}],total:1,hasMore:false,nextOffset:1});
    throw new Error('Unexpected request '+url);
  });
  try{
    await p.goto('http://127.0.0.1:5010/graph?investigation=demo');await p.locator('.node').first().waitFor();await p.locator('#pause').click();await p.locator('#center').click();
    const camera=await p.evaluate(()=>({...document.getElementById('graph').__zoom}));
    const authorNode=p.getByRole('button',{name:'杨超, Name mention',exact:true});await authorNode.locator('circle.core').click({button:'right'});await p.getByRole('menuitem').click();
    await p.getByRole('button',{name:patent.properties.title,exact:true}).waitFor();assert(expansions===0&&modelCalls===0,'Opening an author tab does not start searches or AI');
    assert(await p.getByText('Source-listed',{exact:true}).count()===1&&await p.getByText('Name-search candidate',{exact:true}).count()===1,'Author table preserves evidence bases');
    await p.getByRole('button',{name:'Search both providers',exact:true}).click();await p.waitForFunction(()=>!document.querySelector('.drill-panel:not([hidden]) .research-primary').disabled);assert(expansions===1,'Explicit search action runs once');
    await p.getByRole('button',{name:patent.properties.title,exact:true}).click();await p.getByRole('button',{name:'Scan keywords',exact:true}).waitFor({state:'visible'});await p.waitForFunction(()=>!Array.from(document.querySelectorAll('button')).find(x=>x.textContent==='Scan keywords').disabled);
    await p.getByRole('button',{name:'Scan keywords',exact:true}).click();await p.getByText('Carbon fiber · 1',{exact:true}).waitFor();assert(modelCalls===1,'Only the automatic AI job runs alongside keyword screening');
    assert(requests.some(x=>x.url.endsWith('/api/documents/text')&&x.body.id==='US1234567B1'),'Opening the patent prepares PDF context automatically');
    assert(requests.find(x=>x.url.endsWith('/api/analysis/jobs')&&x.body?.kind==='keywords').body.includePdf===true,'Keyword scan includes PDF context by default');
    await p.locator('.drill-panel:not([hidden]) select[id$="-preset"]').selectOption('missile-supply');await p.getByRole('button',{name:'Run AI review',exact:true}).click();await p.waitForFunction(()=>!Array.from(document.querySelector('.drill-panel:not([hidden])').querySelectorAll('button')).find(b=>b.textContent==='Run AI review').disabled);await p.getByText('A dual-use material',{exact:true}).waitFor();
    assert(modelCalls===2&&reports.at(-1).preset==='missile-supply','Selected AI preset sent exactly once');assert(await p.getByRole('heading',{name:'Direct references',exact:true}).isVisible()&&await p.getByRole('heading',{name:'Potential indirect relevance',exact:true}).isVisible(),'AI review separates direct and indirect findings');
    assert(await p.locator('.ai-finding:not(.unverified) .finding-summary strong').innerText()==='A dual-use material','AI findings use the chat Markdown renderer');
    assert(await p.locator('.ai-finding.unverified .citation-badge').innerText()==='Citation unverified','Unverified citations retain their evidence status');
    assert(await p.locator('.ai-finding.unverified blockquote').innerText()==='Original quotation: 电磁干扰 **literal marks**','Quoted source characters remain literal');
    assert(await p.locator('.ai-finding.unverified .finding-raw').getAttribute('open')===null,'Raw finding JSON stays collapsed');
    assert(await p.locator('.ai-finding img').count()===0&&await p.locator('.ai-finding a[href^="javascript:"]').count()===0,'Model content cannot inject HTML or executable links');
    assert((await p.locator('.ai-finding:not(.unverified)').getByRole('link',{name:'Read PDF →'}).getAttribute('href')).includes('/document?'),'Citations link to the in-app PDF reader');
    await p.screenshot({path:'/private/tmp/turncoat-drill-review.png'});
    await p.getByRole('tab',{name:'PDF',exact:true}).click();await p.locator('.drill-panel:not([hidden]) iframe').waitFor();
    assert((await p.locator('.drill-panel:not([hidden]) iframe').getAttribute('src')).includes('source=patents&id=US1234567B1'),'Patent PDF stays inside the drill-down');
    await p.getByRole('tab',{name:'Source',exact:true}).click();assert(await p.locator('.drill-panel:not([hidden]) [role=tabpanel]:not([hidden]) .json-tree>details').getAttribute('open')===null,'Drill-down source tree starts collapsed');
    await p.locator('#graph-tab').click();assert(await p.locator('.node').count()===3,'Graph is preserved across tabs');
    const after=await p.evaluate(()=>({...document.getElementById('graph').__zoom}));assert(Math.abs(after.k-camera.k)<.001,'Returning to Graph preserves zoom');
    await authorNode.focus();await p.keyboard.press('Shift+F10');assert(await p.getByRole('menu').isVisible(),'Keyboard context menu');await p.keyboard.press('Escape');assert(await p.getByRole('menu').isHidden(),'Escape dismisses menu');
    await p.getByRole('tab',{name:'杨超',exact:true}).click();await p.getByRole('button',{name:paper.properties.title,exact:true}).click();await p.waitForFunction(()=>!document.querySelector('.drill-panel:not([hidden]) .research-primary').disabled);
    await p.getByRole('button',{name:'Run AI review',exact:true}).click();await p.waitForFunction(()=>!Array.from(document.querySelector('.drill-panel:not([hidden])').querySelectorAll('button')).find(b=>b.textContent==='Run AI review').disabled);await p.locator('.drill-panel:not([hidden])').getByText('A dual-use material',{exact:true}).waitFor();assert(reports.at(-1).node==='paper','Paper reviews use the selected paper');
    await p.getByRole('tab',{name:'PDF',exact:true}).click();await p.locator('.drill-panel:not([hidden]) iframe').waitFor();assert((await p.locator('.drill-panel:not([hidden]) iframe').getAttribute('src')).includes('source=arxiv&id=1706.03762v7'),'Paper PDF uses the versioned paper ID');
    const count=await p.locator('#workspace-tabs [role=tab]').count();await p.reload();await p.getByRole('button',{name:'Run AI review',exact:true}).waitFor();assert(await p.locator('#workspace-tabs [role=tab]').count()===count,'Workspace tabs survive reload');assert(modelCalls===4,'Reload never repeats AI');
    await p.waitForFunction(()=>!document.querySelector('.drill-panel:not([hidden]) select[aria-label="Saved reports"]').disabled);await p.locator('.drill-panel:not([hidden]) select[aria-label="Saved reports"]').selectOption(reports.at(-1).id);await p.getByText('A dual-use material',{exact:true}).waitFor();
    failReview=true;await p.getByRole('button',{name:'Run AI review',exact:true}).click();await p.waitForFunction(()=>!Array.from(document.querySelector('.drill-panel:not([hidden])').querySelectorAll('button')).find(b=>b.textContent==='Run AI review').disabled);await p.locator('.drill-panel:not([hidden]) .research-status.error').waitFor();assert(await p.getByRole('button',{name:'Run AI review',exact:true}).isEnabled(),'Model errors allow retry');
    for(const width of [800,390,320]){await p.setViewportSize({width,height:800});assert(await p.evaluate(()=>document.documentElement.scrollWidth<=innerWidth&&document.documentElement.scrollHeight<=innerHeight+1),'Drill-down fits viewport '+width);}
    await p.screenshot({path:'/private/tmp/turncoat-drill-mobile.png'});
    await p.setViewportSize({width:1440,height:1000});await p.goto('http://127.0.0.1:5010/settings');await p.getByText('45 active keyword rules',{exact:false}).waitFor();await p.locator('#settings-filter').fill('碳纤维');assert(await p.locator('.research-table tbody tr').count()===1,'Settings shows literal aliases and filters rules');
    await p.getByRole('tab',{name:'AI queries',exact:true}).click();await p.getByText('Missile supply-chain relevance',{exact:true}).waitFor();await p.getByText('Shared review instructions',{exact:true}).click();assert(await p.locator('.research-raw').isVisible(),'Exact review instructions can be inspected');
    await p.getByRole('tab',{name:'Provider searches',exact:true}).click();await p.getByRole('cell').filter({hasText:'杨超 <img src=x>'}).waitFor();assert(await p.locator('.research-table img').count()===0,'Saved queries are rendered as text');assert(modelCalls===5&&expansions===1,'Settings runs no provider search or AI');
    await p.screenshot({path:'/private/tmp/turncoat-settings-searches.png'});
    await p.setViewportSize({width:320,height:700});assert(await p.evaluate(()=>document.documentElement.scrollWidth<=innerWidth&&document.documentElement.scrollHeight<=innerHeight+1),'Settings fits small screens');
    assert(!errors.length,errors.join('\n'));return {tabs:true,contextMenu:true,authorTable:true,explicitSearch:true,keywords:true,patentAndPaperAI:true,history:true,errorsRecovered:true,settings:true,mobile:true};
  }finally{await c.close();}
}

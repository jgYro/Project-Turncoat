// Server responses are deterministic fixtures; no provider or model calls.
async (page) => {
  const c=await page.context().browser().newContext({viewport:{width:1440,height:900}}),p=await c.newPage(),errors=[],jobs=[],reports=[];
  const assert=(ok,message)=>{if(!ok)throw new Error(message);};
  const nodes=[{id:'patent',label:'Patent',properties:{title:'Background patent',publicationNumber:'US1234567B1'}},{id:'paper',label:'Paper',properties:{title:'Background paper',arxivId:'1706.03762v7'}}];
  let starts=0;
  const record=node=>({title:'Background '+node,source:node==='paper'?'arxiv':'patents',id:node==='paper'?'1706.03762v7':'US1234567B1',authors:['Fixture author'],pdfUrl:'https://arxiv.org/pdf/1706.03762v7',abstract:'Original UTF-8 碳纤维 fixture.'});
  const history=node=>({items:reports.filter(r=>r.node===node),total:reports.filter(r=>r.node===node).length,hasMore:false});
  function complete(node,kind,fail=false){
    const job=jobs.find(j=>j.node===node&&j.kind===kind);job.state=fail?'failed':'succeeded';job.error=fail?'Synthetic model failure.':'';
    if(fail)return;
    const doc=record(node),report={id:'result-'+jobs.indexOf(job),dataset:'demo',node,kind,preset:'wartime',createdAt:'2026-09-09T20:00:00Z',model:'fixture',evidence:{record:doc,reference:{...doc,dataset:'demo',node},fields:{pdf:doc.abstract},pdfIncluded:true,scope:'Synthetic PDF evidence.'},result:kind==='ai'?{direct:[],indirect:[],unverified:[],limitations:'Completed background review.',formatError:''}:{version:'fixture',totalMatches:0,tags:[],hits:[]},rawResponse:'{}'};
    reports.push(report);job.reportId=report.id;
  }
  p.on('pageerror',e=>errors.push(e.message));
  await c.route('**/api/**',async route=>{
    const path='/'+route.request().url().split('/').slice(3).join('/').split('?')[0],body=route.request().method()==='POST'?route.request().postDataJSON():null;
    const reply=(data,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(data)});
    if(path==='/api/drilldown/catalog')return route.continue();
    if(path==='/api/analysis/jobs'){
      if(!body)return reply({jobs});
      starts++;const result=[];
      for(const kind of body.kind?[body.kind]:['keywords','ai']){
        let job=jobs.find(j=>j.node===body.node&&j.kind===kind);
        if(!job||body.force){job={id:'job-'+jobs.length,dataset:'demo',node:body.node,kind,preset:kind==='ai'?'wartime':'',title:record(body.node).title,state:'preparing',createdAt:new Date().toISOString(),reportId:''};jobs.push(job);}
        result.push(job);
      }
      return reply({jobs:result},202);
    }
    if(path==='/api/health')return reply({fts5:true,limits:{neighborLimit:100,maxNodes:500,maxEdges:1000}});
    if(path==='/api/datasets')return reply({datasets:[{id:'demo',nodes:2}]});
    if(path==='/api/investigations')return reply({investigations:[]});
    if(path==='/api/llm/config')return reply({model:'fixture',baseUrl:'http://fixture/v1'});
    if(path==='/api/documents/text')return reply({text:'Original UTF-8 碳纤维 fixture.',scope:'Synthetic PDF evidence.'});
    if(path==='/api/drilldown/document'){const doc=record(body.node);return reply({record:doc,reference:{source:doc.source,id:doc.id,...body},history:history(body.node)});}
    if(path==='/api/drilldown/history')return reply(history(body.node));
    if(path==='/api/drilldown/report')return reply(reports.find(r=>r.id===body.report));
    throw new Error('Unexpected request '+path);
  });
  try{
    await p.goto('http://127.0.0.1:5010/graph');
    await p.evaluate(node=>TurncoatDrilldown.openNode(node,'demo'),nodes[0]);
    await p.getByRole('button',{name:'2 background analysis jobs running',exact:true}).waitFor();
    assert(jobs.length===2,'Explicit document selection queues two independent jobs');
    complete('patent','keywords');await p.evaluate(()=>TurncoatJobs.refresh());
    await p.locator('.drill-panel:not([hidden])').getByText('0 literal matches',{exact:false}).waitFor();
    assert(await p.locator('.job-toast').count()===0,'No completion toast on the matching document tab');
    assert(await p.getByRole('button',{name:'1 background analysis jobs running',exact:true}).isVisible(),'AI continues after keywords finish');
    await p.getByRole('button',{name:'Close Background patent',exact:true}).click();
    assert(await p.locator('#graph-workspace').isVisible(),'Closing the document returns to graph');
    await p.goto('http://127.0.0.1:5010/settings');
    await p.getByRole('button',{name:'1 background analysis jobs running',exact:true}).waitFor();
    complete('patent','ai');await p.evaluate(()=>TurncoatJobs.refresh());
    await p.locator('.job-toast').getByText('AI review complete',{exact:true}).waitFor();
    const before=starts;await p.locator('.job-toast').getByRole('link',{name:'View results →'}).click();
    await p.getByText('Completed background review.',{exact:true}).waitFor();
    assert(starts===before,'Notification opens saved report without inference');
    await p.getByRole('tab',{name:'Keywords',exact:true}).click();
    assert(await p.locator('.drill-panel:not([hidden]) select[aria-label="Saved reports"]').inputValue()==='result-0','Saved report selection follows the visible keyword results');
    await p.getByRole('tab',{name:'AI review',exact:true}).click();
    assert(await p.locator('.drill-panel:not([hidden]) select[aria-label="Saved reports"]').inputValue()==='result-1','Saved report selection follows the visible AI results');
    assert(p.url().includes('document=patent')&&p.url().includes('report=result-1'),'Cross-page notification targets its document and report');
    await p.reload();await p.getByText('Completed background review.',{exact:true}).waitFor();
    assert(starts===before&&jobs.length===2,'Reload does not enqueue jobs');
    await p.evaluate(node=>TurncoatDrilldown.openNode(node,'demo'),nodes[0]);
    await p.evaluate(()=>TurncoatJobs.refresh());assert(jobs.length===2,'Repeated selection reuses completed jobs');
    await p.evaluate(node=>TurncoatDrilldown.openNode(node,'demo'),nodes[1]);
    await p.getByRole('button',{name:'2 background analysis jobs running',exact:true}).waitFor();
    assert(jobs.filter(j=>j.node==='paper').length===2,'Paper selection also queues keyword and AI jobs');
    await p.locator('#graph-tab').click();complete('paper','keywords');complete('paper','ai',true);await p.evaluate(()=>TurncoatJobs.refresh());
    await p.locator('.job-toast.failed').waitFor();
    assert(await p.locator('.job-toast.succeeded').count()===1,'Keyword completion survives AI failure');
    await p.getByRole('button',{name:'Background analysis jobs',exact:true}).click();
    await p.locator('#jobs-panel').getByText('Synthetic model failure.',{exact:true}).waitFor();
    await p.screenshot({path:'/private/tmp/turncoat-background-notifications.png'});
    for(const width of [800,390,320]){
      await p.setViewportSize({width,height:800});
      const bounds=await p.evaluate(()=>{const a=document.querySelector('.brand').getBoundingClientRect(),b=document.getElementById('jobs-toggle').getBoundingClientRect();return{fits:document.documentElement.scrollWidth<=innerWidth,overlap:a.right>b.left&&a.top<b.bottom&&b.top<a.bottom};});
      assert(bounds.fits&&!bounds.overlap,'Navbar and jobs fit at '+width);
    }
    assert(!errors.length,errors.join('\n'));
    return {parallelKinds:true,navigation:true,notifications:true,noReloadInference:true,patentsAndPapers:true,failureIsolation:true,mobile:true};
  }finally{await c.close();}
}

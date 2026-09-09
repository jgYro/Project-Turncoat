// Preview :5010 must contain fixtures/graph/demo.jsonl and share-root.jsonl in demo.
async (page) => {
  const c=await page.context().browser().newContext({viewport:{width:1440,height:1000},reducedMotion:'reduce'}),p=await c.newPage(),errors=[];
  const assert=(value,message)=>{if(!value)throw new Error(message);};
  p.on('pageerror',e=>errors.push(e.message));
  let sharePath;
  try{
    await p.goto('http://127.0.0.1:5010/graph?investigation=demo');await p.locator('.node').first().waitFor();await p.getByRole('button',{name:'Share investigation ↗',exact:true}).click();
    await p.getByRole('button',{name:'Create link & copy',exact:true}).click();await p.getByRole('textbox',{name:'Sharing link'}).waitFor();
    const url=await p.getByRole('textbox',{name:'Sharing link'}).inputValue();sharePath=url.replace('http://127.0.0.1:5010','');assert(/^\/shared\/[a-f0-9]{64}$/.test(sharePath),'Share creates an opaque snapshot URL');
    await p.screenshot({path:'/private/tmp/turncoat-share-dialog.png'});
    const viewer=await c.newPage(),calls=[];viewer.on('pageerror',e=>errors.push(e.message));viewer.on('request',r=>{if(r.url().includes('/api/')||r.url().endsWith('/data'))calls.push({url:r.url(),method:r.method()});});
    // Exercise saved AI presentation without invoking a model for the test.
    await viewer.route('**/shared/*/data',async route=>{
      const response=await route.fetch();if(!response.ok())return route.fulfill({response});
      const data=await response.json();data.reports=[{id:'fixture-review',node:'demo:person:1',kind:'ai',model:'fixture',createdAt:'2026-09-09',evidence:{scope:'Synthetic PDF extract.',record:{sourceUrl:'https://arxiv.org/abs/1706.03762v7'},reference:{source:'arxiv',id:'1706.03762v7'}},result:{direct:[],indirect:[],unverified:[{bucket:'indirect',reason:'Quotation not located.',output:{finding:'**Shared finding**',field:'pdf',quote:'Original text: 电磁干扰',relevance:'A *tentative* connection.',caveat:'Requires verification.'}}],limitations:'**Bounded evidence.**'}}];
      return route.fulfill({response,json:data});
    });
    await viewer.goto(url);await viewer.locator('.shared-node').first().waitFor();assert(await viewer.locator('.shared-node').count()===5,'All saved nodes are visible');
    await viewer.getByRole('combobox',{name:'Saved nodes'}).selectOption('demo:person:1');assert(await viewer.locator('#shared-node-title').innerText()==='Alex Example','Recipient can inspect nodes');
    assert(await viewer.locator('.finding-summary strong').innerText()==='Shared finding','Shared citations use chat Markdown formatting');
    assert(await viewer.locator('.citation-badge').innerText()==='Citation unverified','Shared findings preserve citation status');
    assert(await viewer.locator('.finding-raw').getAttribute('open')===null,'Shared raw citation data starts collapsed');
    assert(await viewer.getByRole('link',{name:'Read PDF →'}).count()===0,'Read-only citations do not open workspace actions');
    assert(await viewer.locator('meta[name="turncoat-token"]').count()===0,'Read-only page contains no workspace write token');assert(calls.length===1&&calls[0].method==='GET'&&calls[0].url.endsWith(sharePath+'/data'),'Viewer only requests its snapshot');
    await viewer.screenshot({path:'/private/tmp/turncoat-share-view.png'});
    const download=viewer.waitForEvent('download');await viewer.getByRole('button',{name:'Download snapshot JSON'}).click();assert((await download).suggestedFilename()==='turncoat-investigation.json','Portable JSON download');
    for(const width of [800,390,320]){await viewer.setViewportSize({width,height:800});assert(await viewer.evaluate(()=>document.documentElement.scrollWidth<=innerWidth&&document.documentElement.scrollHeight<=innerHeight+1),'Shared view fits '+width);}
    await p.getByRole('button',{name:'Revoke',exact:true}).first().click();await p.getByText('Link revoked. Downloaded copies are unaffected.',{exact:true}).waitFor();await viewer.reload();await viewer.getByText('This shared investigation is unavailable or its link was revoked.',{exact:true}).waitFor();
    assert(!errors.length,errors.join('\n'));return {create:true,view:true,readonly:true,download:true,revoke:true,mobile:true};
  }finally{await c.close();}
}

// Playwright page function; use browser_run_code_unsafe with this filename.
// Start ./bin/turncoat --port:5010 serve. Every API request uses synthetic data.
async (page) => {
  const c = await page.context().browser().newContext({viewport:{width:1500,height:1050},reducedMotion:'reduce'});
  const p = await c.newPage(), errors = [];
  const assert = (ok,message) => {if (!ok) throw new Error(message);};
  const nodes = [{id:'seed',label:'Patent',properties:{title:'Synthetic graph seed',sourceUrl:'https://patents.google.com/patent/US1234567B1/en',providerRecord:{abstract:'Long source metadata. '.repeat(600)}}}];
  const links = [];
  for (let i=0;i<80;i++) {
    nodes.push({id:'node-'+i,label:i%2?'Paper':'Name mention',properties:{name:'Original name '+i}});
    links.push({id:'link-'+i,source:i<8?'seed':'node-'+(i%8),target:'node-'+i,label:'name_search_hit',properties:{}});
  }
  const job = {seed:'seed',publicationNumber:'US1234567B1',state:'completed',requests:12,limits:{maxNodes:500,maxEdges:1000,maxRequests:40},events:[{at:'2026-01-01T00:00:00Z',message:'Synthetic investigation completed.'}]};
  p.on('pageerror',error=>errors.push(error.message));
  await c.route('**/api/**',async route=>{
    const url=route.request().url(), reply=data=>route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(data)});
    assert(route.request().method()==='GET','Layout controls must not write or query providers');
    if(route.request().url().endsWith('/api/analysis/jobs'))return route.fulfill({contentType:'application/json',body:JSON.stringify({jobs:[],active:0})});
    if (url.endsWith('/api/health'))return reply({fts5:true,limits:{neighborLimit:100,maxNodes:500,maxEdges:1000}});
    if (url.endsWith('/api/datasets'))return reply({datasets:[{id:'layout',nodes:nodes.length}]});
    if (url.endsWith('/api/investigations'))return reply({investigations:[{id:'layout',job}]});
    if (url.endsWith('/api/investigations/layout'))return reply({id:'layout',job,busy:false,nodes,links});
    throw new Error('Unexpected API request '+url);
  });
  const geometry = () => p.evaluate(()=>{
    const r=selector=>{const b=document.querySelector(selector).getBoundingClientRect();return{x:b.x,y:b.y,width:b.width,height:b.height,right:b.right,bottom:b.bottom};};
    const canvas=r('#canvas'), radar=r('.radar'), circles=[...document.querySelectorAll('.node .core')].map(e=>e.getBoundingClientRect());
    const left=Math.min(...circles.map(b=>b.left)),right=Math.max(...circles.map(b=>b.right)),top=Math.min(...circles.map(b=>b.top)),bottom=Math.max(...circles.map(b=>b.bottom));
    const zoom=document.getElementById('graph').__zoom;
    return {canvas,radar,viewport:{width:innerWidth,height:innerHeight},pageHeight:document.documentElement.scrollHeight,pageWidth:document.documentElement.scrollWidth,
      centered:Math.abs((left+right)/2-canvas.x-canvas.width/2)<3&&Math.abs((top+bottom)/2-canvas.y-canvas.height/2)<3,
      fits:left>=canvas.x&&right<=canvas.right&&top>=canvas.y&&bottom<=canvas.bottom,
      world:zoom.invert([canvas.width/2,canvas.height/2]),scale:zoom.k,count:circles.length,selection:document.getElementById('node-id').textContent};
  });
  const settled = () => p.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  const checkCanvas = async (fit=true) => {
    await settled();const g=await geometry();
    assert(g.pageHeight<=g.viewport.height+1&&g.pageWidth<=g.viewport.width,'Workspace must fit the visible window');
    assert(g.canvas.height>100&&g.canvas.bottom<=g.viewport.height,'Canvas must stay visible');
    assert(Math.abs(g.radar.width-g.radar.height)<1,'Radar must remain a circle');
    assert(Math.abs(g.radar.x+g.radar.width/2-g.canvas.x-g.canvas.width/2)<1&&Math.abs(g.radar.y+g.radar.height/2-g.canvas.y-g.canvas.height/2)<1,'Radar must be centered');
    if(fit)assert(g.centered&&g.fits,'Fit mode must center and contain every node');
    assert(g.count===nodes.length&&g.selection==='seed','Panel changes must preserve nodes and selection');
    return g;
  };
  try {
    await p.goto('http://127.0.0.1:5010/graph?investigation=layout');
    await p.locator('.node').first().waitFor();
    await p.locator('#pause').click();await p.locator('#center').click();
    const initial=await checkCanvas();
    await p.locator('#details-panel .panel-body').evaluate(e=>{e.scrollTop=e.scrollHeight;});
    assert((await checkCanvas()).canvas.height===initial.canvas.height,'Inspector content must scroll independently');
    await p.locator('#toggle-left').click();const oneHidden=await checkCanvas();
    assert(oneHidden.canvas.width>initial.canvas.width,'Hiding the left panel must reclaim its space');
    await p.locator('#toggle-right').click();const bothHidden=await checkCanvas();
    assert(bothHidden.canvas.width===1500,'Hiding both panels must expose the full canvas width');
    await p.reload();await p.locator('.node').first().waitFor();await p.locator('#pause').click();await p.locator('#center').click();
    assert(await p.locator('#search-panel').isHidden()&&await p.locator('#details-panel').isHidden(),'Panel preferences must survive reload');
    await p.locator('#toggle-left').click();await p.locator('#toggle-right').click();
    await p.getByRole('button',{name:'Undock workspace panel',exact:true}).click();await checkCanvas();
    const header=p.locator('#search-panel .panel-header'),before=await header.boundingBox();
    await p.mouse.move(before.x+35,before.y+20);await p.mouse.down();await p.mouse.move(before.x+145,before.y+70,{steps:5});await p.mouse.up();
    const moved=await header.boundingBox();assert(moved.x>before.x+80&&moved.y>before.y+30,'Floating panel should move with its header');
    await header.focus();await p.keyboard.press('ArrowRight');assert((await header.boundingBox()).x>moved.x,'Floating panel supports keyboard movement');
    const panelBefore=await p.locator('#search-panel').boundingBox();
    await p.mouse.move(panelBefore.x+panelBefore.width-3,panelBefore.y+panelBefore.height-3);await p.mouse.down();
    await p.mouse.move(panelBefore.x+panelBefore.width+45,panelBefore.y+panelBefore.height+25,{steps:5});await p.mouse.up();
    assert((await p.locator('#search-panel').boundingBox()).width>panelBefore.width,'Floating panel supports resizing');
    await p.getByRole('button',{name:'Dock workspace panel',exact:true}).click();await checkCanvas();
    assert(await p.locator('#search-panel').evaluate(e=>!e.classList.contains('floating')),'Panel redocks');
    // Preserve the world position the user chose when a dock changes the canvas size.
    const g=await geometry();await p.mouse.move(g.canvas.x+g.canvas.width/2,g.canvas.y+25);await p.mouse.down();
    await p.mouse.move(g.canvas.x+g.canvas.width/2+70,g.canvas.y+60,{steps:5});await p.mouse.up();
    const panned=await geometry();await p.locator('#toggle-right').click();const resized=await checkCanvas(false);
    assert(Math.abs(panned.world[0]-resized.world[0])<.1&&Math.abs(panned.world[1]-resized.world[1])<.1&&panned.scale===resized.scale,'Dock changes must preserve manual pan and zoom');
    await p.locator('#center').click();await checkCanvas();
    await p.setViewportSize({width:390,height:844});await checkCanvas();
    assert(await p.locator('#search-panel').isHidden()&&await p.locator('#details-panel').isHidden(),'Mobile starts with panels closed');
    await p.locator('#toggle-left').click();assert(await p.locator('#search-panel').isVisible(),'Mobile workspace can open');
    await p.locator('#toggle-right').click();assert(await p.locator('#search-panel').isHidden()&&await p.locator('#details-panel').isVisible(),'Mobile shows one drawer at a time');
    await p.keyboard.press('Escape');assert(await p.locator('#details-panel').isHidden(),'Escape closes the drawer');
    assert(await p.locator('#toggle-right').evaluate(e=>e===document.activeElement),'Focus returns to the panel toggle');
    await checkCanvas();await p.screenshot({path:'/private/tmp/turncoat-graph-mobile-centered.png'});
    assert(!errors.length,errors.join('\n'));
    return {nodes:nodes.length,centered:true,panels:'hide, restore, float, drag, resize, keyboard, redock, persisted',manualCameraPreserved:true,mobile:true,errors};
  } finally {await c.close();}
}

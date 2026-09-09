// Playwright page function. Start the app on 5010; all document data is synthetic.
async (page) => {
  const browser=page.context().browser(),results=[];
  const assert=(ok,message)=>{if(!ok)throw new Error(message);};
  for(const [width,height] of [[1366,768],[1280,600],[800,600],[390,844],[320,700]]){
    const c=await browser.newContext({viewport:{width,height},reducedMotion:'reduce'}),p=await c.newPage(),errors=[];
    const reference={source:'patents',id:'US1234567B1'};
    const paragraph='Original source text: 杨超. A bridge response is measured and compared with the model.\n\n';
    const record={...reference,title:'Bridge model updating method and measured structural response',authors:['杨超'],abstract:paragraph.repeat(60),sourceUrl:'https://patents.google.com/patent/US1234567B1/en',pdfUrl:'https://patentimages.storage.googleapis.com/fixture.pdf'};
    p.on('pageerror',error=>errors.push(error.message));
    await c.addInitScript(({reference,paragraph})=>{if(window===window.top&&location.pathname==='/chat')sessionStorage.setItem('turncoat-chat-v1:'+JSON.stringify(reference),JSON.stringify({messages:[{role:'user',content:'Summarize the attached record.'},{role:'assistant',model:'granite4.1:8b',content:'## Source summary\n\n'+paragraph.repeat(30)}]}));},{reference,paragraph});
    await c.route('**/api/**',async route=>{
      const url=route.request().url(),reply=data=>route.fulfill({contentType:'application/json',body:JSON.stringify(data)});
      if(url.endsWith('/config'))return reply({model:'granite4.1:8b',baseUrl:'http://fixture/v1',maxMessageBytes:16000,maxMessages:24,maxConversationBytes:64000});
      if(url.endsWith('/context')||url.endsWith('/record'))return reply(record);
      if(url.endsWith('/prepare-pdf'))return reply({ready:true});
      if(url.includes('/api/documents/pdf?'))return route.fulfill({path:'tests/fixtures/document.pdf',contentType:'application/pdf'});
      if(url.endsWith('/text'))return reply({text:paragraph.repeat(80),scope:'Synthetic text for scrolling checks.'});
      throw new Error('Unexpected API request: '+url);
    });
    const settle=()=>p.evaluate(()=>document.fonts.ready.then(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))));
    const bounds=()=>p.evaluate(()=>({width:innerWidth,height:innerHeight,bodyWidth:document.documentElement.scrollWidth,bodyHeight:document.documentElement.scrollHeight,header:document.querySelector('.site-header').getBoundingClientRect().top}));
    const fit=async()=>{const b=await bounds();assert(b.bodyWidth<=b.width&&b.bodyHeight<=b.height+1,'Outer page must fit '+width+'×'+height+' at '+p.url()+': '+JSON.stringify(b));assert(b.header===0,'Navigation stays at the top');};
    const wheel=async selector=>{
      await p.locator(selector).hover();await p.mouse.wheel(0,300);
      await p.waitForFunction(selector=>document.querySelector(selector).scrollTop>0,selector);
    };
    try{
      await p.goto('http://127.0.0.1:5010/chat?source=patents&id=US1234567B1');
      await p.locator('.chat-message.assistant').waitFor();await settle();await fit();
      const contextRoot=p.locator('#context-tree .json-tree>details');
      assert(await contextRoot.getAttribute('open')===null,'Chat JSON starts collapsed');
      await contextRoot.locator(':scope>summary').click();
      if(width<=760)await p.locator('.chat-workspace').evaluate(e=>e.scrollTop=0);
      const compose=await p.locator('.chat-compose').boundingBox();
      assert(compose.y+compose.height<=height+1,'Composer stays visible');
      await p.locator('#messages').evaluate(e=>e.scrollTop=0);await wheel('#messages');
      const after=await p.locator('.chat-compose').boundingBox();
      assert(Math.abs(after.y-compose.y)<1,'Reading messages must not move the composer');
      if(width>760){
        await p.locator('.chat-sidebar').evaluate(e=>e.scrollTop=0);await wheel('.chat-sidebar');
        assert((await p.locator('.chat-compose').boundingBox()).y===compose.y,'Context scrolling is independent');
      }else{
        await p.locator('.chat-workspace').evaluate(e=>e.scrollTop=e.scrollHeight);
        assert(await p.locator('#check-connection').isVisible(),'Model and attachment controls remain reachable below the mobile conversation');
        await p.locator('#check-connection').scrollIntoViewIfNeeded();await fit();
        await p.locator('.chat-workspace').evaluate(e=>e.scrollTop=0);
      }
      if(width===1366||width===390)await p.screenshot({path:'/private/tmp/turncoat-scroll-chat-'+width+'.png'});
      await p.goto('http://127.0.0.1:5010/document?source=patents&id=US1234567B1');
      await p.locator('#document-analysis').waitFor({state:'visible'});await settle();await fit();
      const recordRoot=p.locator('#document-tree .json-tree>details');
      assert(await recordRoot.getAttribute('open')===null,'Document JSON starts collapsed');
      await recordRoot.locator(':scope>summary').click();
      if(width<=760)await p.locator('#view-record').evaluate(e=>e.scrollTop=0);
      const toolbar=await p.locator('.document-toolbar').boundingBox();
      await wheel(width>760?'.reader-record article':'#view-record');
      assert((await p.locator('.document-toolbar').boundingBox()).y===toolbar.y,'Record scrolling must keep document tabs visible');
      if(width>760){
        assert(await p.locator('.reader-record aside').evaluate(e=>e.scrollTop)===0,'Record and source inspector scroll independently');
        await wheel('.reader-record aside');
      }
      if(width===1366||width===390)await p.screenshot({path:'/private/tmp/turncoat-scroll-document-'+width+'.png'});
      await p.locator('#tab-pdf').click();await p.locator('#pdf-container iframe').waitFor();
      const frame=await p.locator('#pdf-container iframe').boundingBox();
      assert(frame.height>100&&frame.y+frame.height<=height,'PDF viewer fills the available document pane');
      await p.locator('#tab-text').click();
      await p.waitForFunction(()=>document.querySelector('#load-pdf-text').textContent==='PDF context ready');
      await wheel('#document-text');
      assert((await p.locator('.document-toolbar').boundingBox()).y===toolbar.y,'Text scrolling must keep document tabs visible');await fit();
      for(const path of ['/','/patents','/institutions','/chat/guide']){
        await p.goto('http://127.0.0.1:5010'+path);await settle();await fit();await wheel('main');await fit();
        if(path==='/institutions'){
          await p.locator('a[href="#add-institution"]').click();
          const editor=await p.locator('#add-institution').boundingBox();assert(editor.y<height&&editor.y>=0,'Add institution anchor scrolls its pane');
        }
      }
      assert(!errors.length,errors.join('\n'));results.push({width,height,chat:true,record:true,pdf:true,text:true,navigation:true});
    }finally{await c.close();}
  }
  return results;
}

// Playwright page function: run with browser_run_code_unsafe's filename option.
// Start ./bin/turncoat --port:5010 serve first. All API calls are intercepted;
// this exercises the actual UI without contacting document or model providers.
async (page) => {
  const origin = 'http://127.0.0.1:5010';
  const browser = page.context().browser(), results = [];
  const assert = (ok, message) => { if (!ok) throw new Error(message); };
  for (const scenario of ['patent-pdf', 'paper-pdf', 'pdf-failure', 'no-pdf', 'model-failure']) {
    const context = await browser.newContext({viewport:{width:1440,height:1000}, reducedMotion:'reduce'});
    const p = await context.newPage(), errors = [], requests = [];
    let extractionCalls = 0;
    let releaseReply;
    const replyGate=new Promise(resolve=>{releaseReply=resolve;});
    p.on('pageerror', error => errors.push(error.message));
    const source = scenario === 'paper-pdf' ? 'arxiv' : 'patents';
    const reference = {source, id:source === 'arxiv' ? '1706.03762v7' : 'CN112367175B', dataset:'saved',node:'saved:example'};
    const query = 'source='+source+'&id='+reference.id+'&dataset=saved&node=saved%3Aexample';
    const record = {...reference,title:'Document analysis fixture',authors:['杨超'],abstract:'Original source text.',pdfUrl:scenario==='no-pdf'?'':'https://arxiv.org/pdf/1706.03762v7',sourceUrl:'https://arxiv.org/abs/1706.03762v7'};
    await context.route('**/api/**',async route => {
      const url=route.request().url();
      const reply=(data,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(data)});
      if(route.request().url().endsWith('/api/analysis/jobs'))return route.fulfill({contentType:'application/json',body:JSON.stringify({jobs:[],active:0})});
      if(url.endsWith('/api/llm/config'))return reply({model:'granite4.1:8b',baseUrl:'http://fixture/v1',maxMessageBytes:16000,maxMessages:24,maxConversationBytes:64000});
      if(url.endsWith('/api/documents/record')||url.endsWith('/api/llm/context'))return reply(record);
      if(url.endsWith('/api/documents/text')){
        extractionCalls++;
        if(scenario==='pdf-failure')return reply({error:{message:'Synthetic PDF unavailable.'}},503);
        return reply({text:'Original PDF text: 杨超',scope:'First 40 pages, at most 32000 UTF-8 bytes.'});
      }
      if(url.endsWith('/api/llm/chat')){
        requests.push(route.request().postDataJSON());
        await replyGate;
        if(scenario==='model-failure')return reply({error:{message:'Synthetic model unavailable.'}},503);
        return reply({message:{role:'assistant',content:'Evidence scope\nFixture review. Original name: 杨超.'},model:'granite4.1:8b',finishReason:'stop'});
      }
      throw new Error('Unexpected outbound API request: '+url);
    });
    try {
      await p.goto(origin+'/document?'+query);
      await p.locator('#document-analysis').waitFor({state:'visible'});
      assert(requests.length===0,'Document loading must not invoke AI');
      const manualKey='turncoat-chat-v1:'+JSON.stringify(reference);
      const manualValue=JSON.stringify({messages:[{role:'user',content:'Existing question'},{role:'assistant',content:'Existing answer'}],includePdf:false});
      await p.evaluate(({key,value})=>sessionStorage.setItem(key,value),{key:manualKey,value:manualValue});
      if(scenario==='patent-pdf'){
        await p.screenshot({path:'/private/tmp/turncoat-ai-analysis-button.png'});
        await p.setViewportSize({width:390,height:844});
        assert(await p.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Mobile reader must fit viewport');
        await p.screenshot({path:'/private/tmp/turncoat-ai-analysis-mobile.png'});
        await p.setViewportSize({width:1440,height:1000});
      }
      await p.getByRole('button',{name:'AI Analysis ✳',exact:true}).click();
      await p.waitForURL('**/chat?**');
      await p.waitForFunction(()=>document.body.classList.contains('is-generating'));
      assert(await p.locator('#chat-input').inputValue()==='','Submitted prompt must leave the composer immediately');
      releaseReply();
      await p.waitForFunction(()=>document.querySelector('.chat-message.assistant')||document.querySelector('#chat-status.error'));
      assert(requests.length===1,'Button should submit exactly once');
      assert(requests[0].context.source===source&&requests[0].context.dataset==='saved'&&requests[0].context.node==='saved:example','Source and graph context preserved');
      assert(requests[0].messages.length===1,'Review must start separately from existing manual conversation');
      assert(requests[0].messages[0].content.includes('preserving original names'),'Review preserves source names');
      assert(requests[0].context.includePdf===!['pdf-failure','no-pdf'].includes(scenario),'Correct PDF attachment scope');
      if(['pdf-failure','no-pdf'].includes(scenario))assert(requests[0].messages[0].content.includes('metadata-only'),'Fallback scope reaches model');
      const status=await p.locator('#analysis-status').innerText();
      if(scenario==='model-failure'){
        assert((await p.locator('#chat-input').inputValue()).includes('Review this attached'),'Failed request kept for manual retry');
        assert(await p.locator('.chat-message.user').count()===0,'Failed request must not leave invalid history');
      }
      await p.reload();
      await p.waitForFunction(()=>!document.querySelector('#send-message').disabled);
      assert(requests.length===1,'Refresh must not re-submit analysis');
      assert(await p.evaluate(key=>sessionStorage.getItem(key),manualKey)===manualValue,'Existing manual conversation preserved');
      if(scenario==='model-failure'){
        assert((await p.locator('#chat-input').inputValue()).includes('Review this attached'),'Failed draft survives reload');
        await p.locator('#send-message').click();
        await p.waitForFunction(()=>!!document.querySelector('#chat-status.error'));
        assert(requests.length===2,'Explicit retry sends one additional request');
      }else{
        assert(await p.locator('.chat-message.assistant').count()===1,'Completed analysis survives reload');
      }
      // A copied URL in another tab has no one-use intent and cannot auto-send.
      const untrusted=await context.newPage();
      await untrusted.goto(p.url());
      await untrusted.waitForFunction(()=>!document.querySelector('#send-message').disabled);
      assert(requests.length===(scenario==='model-failure'?2:1),'Opening copied URL must not trigger AI');
      await untrusted.close();
      assert(errors.length===0,errors.join('\n'));
      results.push({scenario,requests:requests.length,extractionCalls,status});
    } finally {await context.close();}
  }
  return results;
}

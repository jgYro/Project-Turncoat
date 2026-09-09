// Playwright page function for browser_run_code_unsafe. Start the app on 5010.
// All model and document API responses are synthetic; no external requests.
async (page) => {
  const c=await page.context().browser().newContext({viewport:{width:1500,height:1050},permissions:['clipboard-read','clipboard-write'],reducedMotion:'no-preference'});
  const p=await c.newPage(),errors=[],remote=[];let modelCalls=0,releasePdf,releaseModel;
  const pdfGate=new Promise(resolve=>{releasePdf=resolve;}),modelGate=new Promise(resolve=>{releaseModel=resolve;});
  const assert=(ok,message)=>{if(!ok)throw new Error(message);};
  const markdown='## Summary of the Patent Record\n\nThe record describes **bridge model updating** by 杨超.\n\n1. **Purpose and application**\n   - Update the structural model.\n   - Preserve original source text.\n2. Limitations require more evidence.\n\n> Source text stays separate from interpretation.\n\n| Field | Value |\n| :--- | ---: |\n| Inventor | 杨超 |\n| Source | Patent |\n\n~~~nim\necho "<script>not executable</script>"\n~~~\n\n[Paper](https://arxiv.org/abs/1706.03762v7) and [reference](https://example.com/reference).\n\n[Unsafe](javascript:alert(1)) ![remote image](https://tracking.invalid/pixel.png)\n\n<script>window.chatInjected=true</script><img src=x onerror="window.chatInjected=true">\n';
  p.on('pageerror',error=>errors.push(error.message));
  p.on('request',request=>{if(!request.url().startsWith('http://127.0.0.1:5010'))remote.push(request.url());});
  await c.route('**/api/**',async route=>{
    const url=route.request().url(),reply=(data,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(data)});
    if(route.request().url().endsWith('/api/analysis/jobs'))return route.fulfill({contentType:'application/json',body:JSON.stringify({jobs:[],active:0})});
    if(url.endsWith('/config'))return reply({model:'granite4.1:8b',baseUrl:'http://fixture/v1',maxMessageBytes:16000,maxMessages:24,maxConversationBytes:64000});
    if(url.endsWith('/context'))return reply({source:'patents',id:'US1234567B1',title:'Synthetic bridge model record',authors:['杨超'],pdfUrl:'https://patentimages.storage.googleapis.com/fixture.pdf'});
    if(url.endsWith('/text')){await pdfGate;return reply({text:'Synthetic PDF source',scope:'Synthetic extract; first 40 pages maximum.'});}
    if(url.endsWith('/chat')){
      modelCalls++;await modelGate;
      if(route.request().postDataJSON().messages.at(-1).content==='fail')return reply({error:{message:'Synthetic model failure.'}},503);
      return reply({message:{role:'assistant',content:markdown},model:'granite4.1:8b',usage:{total_tokens:123},finishReason:'stop'});
    }
    throw new Error('Unexpected API request '+url);
  });
  try{
    await p.goto('http://127.0.0.1:5010/chat?source=patents&id=US1234567B1');
    await p.locator('#include-pdf').waitFor({state:'visible'});await p.locator('#include-pdf').check();
    const question='Summarize **the original** <img src=x>. Keep the Chinese names.';
    await p.locator('#chat-input').fill(question);await p.locator('#send-message').click();
    await p.locator('#pending-reply').waitFor({state:'visible'});
    assert((await p.locator('#pending-title').innerText()).includes('Preparing'),'PDF preparation has its own stage');
    assert(modelCalls===0,'Model waits for PDF preparation');
    assert(await p.locator('#chat-input').inputValue()==='','Composer clears immediately');
    assert(await p.locator('.chat-message.user .message-content').innerText()===question,'User message stays literal');
    assert(await p.locator('.chat-message.user strong').count()===1,'Only the user identity label is bold, not their Markdown');
    await p.waitForFunction(()=>document.getElementById('pending-elapsed').textContent!=='0s elapsed');
    releasePdf();await p.waitForFunction(()=>document.getElementById('pending-title').textContent.includes('Waiting'));
    assert(await p.locator('#pending-stage-context').evaluate(e=>e.classList.contains('done')),'Context stage finishes before awaiting AI');
    await p.screenshot({path:'/private/tmp/turncoat-ai-waiting.png'});
    releaseModel();await p.locator('.chat-message.assistant').waitFor({state:'visible'});
    assert(await p.locator('#pending-reply').count()===0,'Loading card disappears after success');
    const reply=p.locator('.chat-message.assistant');
    assert(await reply.locator('h2').innerText()==='Summary of the Patent Record','Markdown heading rendered');
    assert(await reply.locator('.markdown-body strong').first().innerText()==='bridge model updating','Bold rendered');
    assert(await reply.locator('ol li ul li').count()===2,'Nested Markdown lists rendered');
    assert(await reply.locator('blockquote').count()===1&&await reply.locator('table tbody tr').count()===2,'Quotes and tables rendered');
    assert(await reply.locator('pre code').innerText()==='echo "<script>not executable</script>"\n','Code is literal');
    assert(await reply.locator('img,script,iframe,style').count()===0,'HTML and remote images cannot execute');
    assert(await p.evaluate(()=>window.chatInjected===undefined),'Model HTML did not run');
    assert(await reply.locator('a[href^="javascript:"],a[href^="data:"]').count()===0,'Unsafe links rejected');
    assert(await reply.getByRole('link',{name:'Paper',exact:true}).getAttribute('href')==='/document?source=arxiv&id=1706.03762v7','Paper citations open in-app');
    assert((await reply.getByRole('link',{name:'reference',exact:true}).getAttribute('rel')).includes('noopener'),'External links isolated');
    await reply.getByRole('button',{name:'Copy reply',exact:true}).click();
    assert(await p.evaluate(()=>navigator.clipboard.readText())===markdown,'Copy reply preserves original Markdown');
    await reply.getByRole('button',{name:'Copy code block'}).click();
    assert(await p.evaluate(()=>navigator.clipboard.readText())==='echo "<script>not executable</script>"\n','Code copy preserves raw text');
    await p.screenshot({path:'/private/tmp/turncoat-markdown-reply.png'});
    const styles=await p.evaluate(()=>{const user=getComputedStyle(document.querySelector('.chat-message.user')),ai=getComputedStyle(document.querySelector('.chat-message.assistant'));return {user:user.backgroundColor,ai:ai.backgroundColor};});
    assert(styles.user!==styles.ai,'User and assistant have distinct surfaces');
    await p.reload();await p.locator('.chat-message.assistant h2').waitFor();
    assert(modelCalls===1,'Reload renders history without another model call');
    for(const width of [390,320]){
      await p.setViewportSize({width,height:844});
      assert(await p.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Markdown must fit mobile viewport');
    }
    await p.screenshot({path:'/private/tmp/turncoat-markdown-mobile.png'});
    await p.locator('#chat-input').fill('fail');await p.locator('#send-message').click();
    await p.waitForFunction(()=>document.getElementById('chat-status').classList.contains('error'));
    assert(await p.locator('#pending-reply').count()===0,'Loading card removed after failure');
    assert(await p.locator('#chat-input').inputValue()==='fail','Failed prompt restored for retry');
    assert(await p.locator('#messages').getAttribute('aria-busy')==='false','Busy state cleared');
    assert(!errors.length,errors.join('\n'));assert(!remote.length,'No remote image or script requests: '+remote.join(','));
    return {loadingStages:true,elapsedTimer:true,markdown:true,copy:true,hostileInputSafe:true,history:true,mobile:true,errorRecovery:true,modelCalls};
  }finally{releasePdf();releaseModel();await c.close();}
}

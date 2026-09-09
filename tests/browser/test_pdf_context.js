// Actual UI, synthetic PDF/model responses. No provider or model traffic.
async (page) => {
  const results=[],assert=(ok,message)=>{if(!ok)throw new Error(message);};
  for(const scenario of ['patents','arxiv','graph','failure']){
    const c=await page.context().browser().newContext({viewport:{width:1280,height:800}}),p=await c.newPage(),errors=[],sent=[];
    let extracts=0,fail=scenario==='failure',release;
    const gate=new Promise(resolve=>{release=resolve;});
    const source=scenario==='arxiv'?'arxiv':'patents',id=source==='arxiv'?'1706.03762v7':'US1234567B1';
    const reference={source,id,dataset:'saved',node:'saved:document'},record={...reference,title:'Automatic PDF fixture',authors:['杨超'],abstract:'Metadata only.',pdfUrl:'https://arxiv.org/pdf/1706.03762v7'};
    p.on('pageerror',error=>errors.push(error.message));
    await c.route('**/api/**',async route=>{
      const url=route.request().url(),reply=(data,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(data)});
      if(route.request().url().endsWith('/api/analysis/jobs'))return route.fulfill({contentType:'application/json',body:JSON.stringify({jobs:[],active:0})});
      if(url.endsWith('/api/llm/config'))return reply({model:'fixture',baseUrl:'http://fixture/v1',maxMessageBytes:16000,maxMessages:24,maxConversationBytes:64000});
      if(url.endsWith('/api/llm/context')||url.endsWith('/api/documents/record'))return reply(record);
      if(url.endsWith('/api/documents/text')){extracts++;await gate;return fail?reply({error:{message:'Synthetic OCR unavailable.'}},503):reply({text:'PDF evidence · 电磁干扰',scope:'Docling OCR fixture; first 40 pages.'});}
      if(url.endsWith('/api/llm/chat')){sent.push(route.request().postDataJSON());return reply({message:{role:'assistant',content:'Fixture analysis.'},model:'fixture'});}
      throw new Error('Unexpected API call: '+url);
    });
    try{
      const query=scenario==='graph'?'dataset=saved&node=saved%3Adocument':'source='+source+'&id='+id+'&dataset=saved&node=saved%3Adocument';
      await p.goto('http://127.0.0.1:5010/chat?'+query);
      await p.getByText('Preparing PDF context…',{exact:false}).waitFor();
      assert(await p.locator('#include-pdf').isChecked(),'PDF context is included by default: '+scenario);
      assert(extracts===1&&sent.length===0,'Opening chat prepares PDF once without calling the model');
      await p.locator('#chat-input').fill('Analyze the attached PDF.');await p.locator('#send-message').click();
      await p.locator('#pending-title').waitFor();assert(sent.length===0,'Sending waits for PDF extraction');
      release();
      if(fail){
        await p.locator('#chat-status.error').waitFor();assert(sent.length===0,'Extraction failure does not silently send metadata-only chat');
        assert(await p.locator('#chat-input').inputValue()==='Analyze the attached PDF.','Failed send keeps draft');
        fail=false;await p.locator('#retry-pdf-context').click();await p.getByText('PDF context ready ·',{exact:false}).waitFor();
        await p.locator('#send-message').click();
      }
      await p.locator('.chat-message.assistant').waitFor();
      assert(sent.length===1&&sent[0].context.includePdf===true&&sent[0].context.source===source&&sent[0].context.id===id,'Chat attaches the correct document PDF');
      assert(extracts===(scenario==='failure'?2:1),'Sending reuses automatic preparation');
      await p.reload();await p.getByText('PDF context ready ·',{exact:false}).waitFor();assert(sent.length===1,'Reload only prepares context');
      await p.goto('http://127.0.0.1:5010/document?source='+source+'&id='+id);
      await p.getByRole('tab',{name:'Extracted text',exact:true}).click();
      await p.getByRole('button',{name:'PDF context ready',exact:true}).waitFor();
      assert((await p.locator('#document-text').innerText()).includes('电磁干扰'),'Reader automatically exposes extracted UTF-8 text');
      assert(sent.length===1,'Opening reader does not invoke AI');
      assert(!errors.length,errors.join('\n'));results.push({scenario,automaticPdf:true,modelCalls:sent.length,retry:scenario==='failure'});
    }finally{release();await c.close();}
  }
  return results;
}

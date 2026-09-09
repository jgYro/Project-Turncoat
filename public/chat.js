(() => {
  'use strict';
  const el=id=>document.getElementById(id), params=new URLSearchParams(location.search);
  const token=document.querySelector('meta[name="turncoat-token"]').content;
  const saved=params.has('node')?{dataset:params.get('dataset'),node:params.get('node')}:null;
  const context=params.has('source')?{source:params.get('source'),id:params.get('id'),...(saved||{})}:saved;
  const analysisId=/^[a-f0-9-]{36}$/.test(params.get('analysis')||'')?params.get('analysis'):null;
  const key='turncoat-chat-v1:'+JSON.stringify(context)+(analysisId?':analysis:'+analysisId:''), tree=new TurncoatJsonTree(el('context-tree'));
  const analysisPrompt=`Review this attached patent or arXiv paper using only the supplied metadata and extracted PDF text, if present. Write in English, preserving original names and Chinese text beside any translations. Use concise Markdown sections:
1. Evidence scope: identify the source, whether PDF text is included, and any extraction or metadata limitations.
2. Summary: explain the problem, proposed method, and claimed contribution in accessible language. Attribute claims to the source; do not present them as independently verified.
3. People and organizations: list names and roles explicitly present. Distinguish a partial search-result inventor list from names in the PDF. Mark uncertain translations; do not infer identities or affiliations from name matches.
4. Key details and limitations: identify supported technical details, assumptions, and missing evidence. For a patent, distinguish claims from demonstrated results; for a paper, distinguish reported findings from your interpretation.
5. Follow-up questions: suggest questions to investigate without performing searches.
Cite source URLs and relevant metadata fields or PDF passages. Do not invent page numbers, legal conclusions, people, or relationships. Keep the review under 600 words.`;
  const autoAnalysis=(()=>{
    if(!analysisId||!context?.source)return false;
    try{
      const intentKey='turncoat-analysis-intent:'+analysisId;
      const intent=JSON.parse(sessionStorage.getItem(intentKey)||'null');
      sessionStorage.removeItem(intentKey); // Consume before any async work, including model calls.
      const age=Date.now()-intent?.createdAt;
      return age>=0&&age<300000&&['source','id','dataset','node'].every(k=>(intent?.reference?.[k]||null)===(context[k]||null));
    }catch{return false;}
  })();
  const encoder=new TextEncoder();
  let config=null, messages=[], busy=false, contextReady=!context, pdfReady=false, pdfContext=null, draft='', analysisScope='';
  let pendingTimer=null,pendingStarted=0,pendingPhase='context';
  const welcome=el('chat-welcome');
  function status(text,error=false){el('chat-status').textContent=text;el('chat-status').classList.toggle('error',error);}
  async function request(path,body) {
    const response=await fetch(path,{method:body===undefined?'GET':'POST',headers:{'Accept':'application/json',...(body===undefined?{}:{'Content-Type':'application/json','X-Turncoat-Token':token})},body:body===undefined?undefined:JSON.stringify(body)});
    const data=await response.json();if(!response.ok)throw new Error(data.error?.message||`Request failed (${response.status}).`);return data;
  }
  function analysisStatus(text,error=false){if(!analysisId)return;analysisScope=text;el('analysis-status').hidden=!text;el('analysis-status').textContent=text;el('analysis-status').classList.toggle('error',error);}
  function save(){try{sessionStorage.setItem(key,JSON.stringify({messages,includePdf:el('include-pdf').checked,draft,analysisScope,pdfScope:el('pdf-context-status').textContent}));}catch{status('Browser storage is unavailable; this conversation will last until you leave this page.',true);}}
  function messageIdentity(role,model){
    const identity=document.createElement('div');identity.className='message-identity';
    const avatar=document.createElement('span');avatar.className='message-avatar';avatar.setAttribute('aria-hidden','true');avatar.textContent=role==='user'?'↗':'✳';
    const names=document.createElement('div'),label=document.createElement('strong'),detail=document.createElement('span');
    label.textContent=role==='user'?'You':'AI assistant';detail.textContent=role==='user'?'YOUR QUESTION':model||config?.model||'MODEL';
    names.append(label,detail);identity.append(avatar,names);return identity;
  }
  function pendingCard(){
    const card=document.createElement('div');card.id='pending-reply';card.className='chat-pending';
    const header=document.createElement('header');header.append(messageIdentity('assistant'));
    const elapsed=document.createElement('span');elapsed.id='pending-elapsed';elapsed.setAttribute('aria-hidden','true');header.append(elapsed);
    const body=document.createElement('div');body.className='pending-body';
    const orbit=document.createElement('div');orbit.className='pending-orbit';orbit.textContent='✳';orbit.setAttribute('aria-hidden','true');
    const description=document.createElement('div'),title=document.createElement('h3'),note=document.createElement('p');
    title.id='pending-title';title.setAttribute('role','status');note.id='pending-note';
    description.append(title,note);body.append(orbit,description);
    const stages=document.createElement('ol');stages.className='pending-stages';stages.setAttribute('aria-label','Request progress');
    for(const [id,label] of [['context','Prepare context'],['model','Await AI response']]){const stage=document.createElement('li');stage.id='pending-stage-'+id;stage.textContent=label;stages.append(stage);}
    card.append(header,body,stages);return card;
  }
  function updatePending(){
    if(!el('pending-reply'))return;
    const seconds=Math.floor((performance.now()-pendingStarted)/1000);
    el('pending-elapsed').textContent=(seconds<60?seconds+'s':Math.floor(seconds/60)+'m '+seconds%60+'s')+' elapsed';
    const title=pendingPhase==='context'?'Preparing your document…':'Waiting for the AI response…';
    if(el('pending-title').textContent!==title)el('pending-title').textContent=title;
    el('pending-note').textContent=pendingPhase==='context'?'Loading and extracting PDF text for this review.':seconds>=30?'The request is still pending. Larger documents and local models can take longer.':'Your request has been sent. The reply will appear here when ready.';
    for(const phase of ['context','model']){
      const stage=el('pending-stage-'+phase);stage.classList.toggle('active',phase===pendingPhase);stage.classList.toggle('done',phase==='context'&&pendingPhase==='model');
      if(phase===pendingPhase)stage.setAttribute('aria-current','step');else stage.removeAttribute('aria-current');
    }
  }
  function stopPending(){clearInterval(pendingTimer);pendingTimer=null;pendingStarted=0;el('pending-reply')?.remove();el('messages').setAttribute('aria-busy','false');}
  function draw(){
    el('messages').replaceChildren();
    if(!messages.length)el('messages').append(welcome);
    for(const message of messages){
      const article=document.createElement('article');article.className='chat-message '+message.role;
      article.setAttribute('aria-label',message.role==='user'?'Your message':'AI response');
      const head=document.createElement('header');head.append(messageIdentity(message.role,message.model));
      const content=document.createElement('div');content.className='message-content';
      if(message.role==='assistant'){
        content.classList.add('markdown-body');window.TurncoatMarkdown(content,message.content);
        const copy=document.createElement('button');copy.type='button';copy.className='copy-reply';copy.textContent='Copy reply';
        copy.addEventListener('click',async()=>{try{await navigator.clipboard.writeText(message.content);copy.textContent='Copied';}catch{copy.textContent='Select text to copy';}});head.append(copy);
      }else if(message.kind==='analysis'){
        const title=document.createElement('p');title.className='analysis-request-title';title.textContent=context?.source==='arxiv'?'Analyze this paper':'Analyze this patent';
        const details=document.createElement('details'),summary=document.createElement('summary'),request=document.createElement('div');
        summary.textContent='View review request';request.textContent=message.content;details.append(summary,request);content.append(title,details);
      }else content.textContent=message.content;
      article.append(head,content);
      if(message.role==='assistant' && (message.usage || message.finishReason==='length')){
        const usage=document.createElement('p');usage.className='message-usage';
        const count=message.usage?.total_tokens;
        usage.textContent=(Number.isFinite(count)?`${count} tokens reported by the model server. `:'')+(message.finishReason==='length'?'Output limit reached; ask a follow-up to continue.':'');
        article.append(usage);
      }
      el('messages').append(article);
    }
    if(pendingStarted){el('messages').append(pendingCard());updatePending();}
    const latest=el('messages').lastElementChild;
    if(latest)el('messages').scrollTop+=latest.getBoundingClientRect().top-el('messages').getBoundingClientRect().top-16;
    el('include-pdf').disabled=busy||messages.length>0;
  }
  function controls(){el('send-message').disabled=busy||!config||!contextReady;el('new-chat').disabled=busy;el('chat-input').disabled=busy;el('include-pdf').disabled=busy||messages.length>0;document.body.classList.toggle('is-generating',busy);}
  async function preparePdf(){
    if(!context?.source||!el('include-pdf').checked||pdfReady)return;
    const text=await pdfContext?.prepare();
    if(!text)throw new Error((pdfContext?.error?.message||'No PDF is listed for this record.')+' Retry PDF context or turn off Include extracted PDF text to use metadata only.');
    pdfReady=true;
  }
  async function sendMessage(text,automatic=false){
    if(!text||busy||!config||!contextReady)return;
    const history=messages.map(({role,content})=>({role,content}));history.push({role:'user',content:text});
    if(encoder.encode(text).length>config.maxMessageBytes||history.length>config.maxMessages||history.reduce((n,m)=>n+encoder.encode(m.content).length,0)>config.maxConversationBytes){status('This conversation has reached its size limit. Shorten the question or start a new chat.',true);return;}
    draft=text;save();el('chat-input').value='';busy=true;controls();status('Reading context and waiting for the model…');
    pendingStarted=performance.now();pendingPhase=context?.source&&el('include-pdf').checked&&!pdfReady?'context':'model';
    el('messages').setAttribute('aria-busy','true');pendingTimer=setInterval(updatePending,1000);
    if(analysisId)analysisStatus('Reviewing the attached document…');
    messages.push({role:'user',content:text,...(automatic?{kind:'analysis'}:{})});draw();
    try {
      try{await preparePdf();}
      catch(error){
        if(!automatic)throw error;
        el('include-pdf').checked=false;
        el('pdf-context-status').textContent='PDF text unavailable: '+error.message+' Reviewing metadata only.';
        text+='\n\nEvidence scope: PDF extraction failed. Only the attached metadata is available. Explicitly label this a metadata-only review.';
        history[history.length-1].content=text;messages[messages.length-1].content=text;draft=text;draw();
      }
      pendingPhase='model';updatePending();
      const data=await request('/api/llm/chat',{messages:history,context:context?{...context,includePdf:el('include-pdf').checked}:null});
      stopPending();
      messages.push({...data.message,model:data.model,usage:data.usage,finishReason:data.finishReason});el('chat-input').value='';draft='';
      analysisStatus('AI review complete · '+(el('include-pdf').checked?'Metadata and extracted PDF text.':'Metadata only; PDF text was not included.')+' Ask a follow-up below.');
      save();draw();status('Reply received.');
    }catch(error){stopPending();messages.pop();el('chat-input').value=draft;draw();status(error.message,true);analysisStatus('The review could not finish. Your request is ready to retry with Send message.',true);save();}
    finally{stopPending();busy=false;controls();el('chat-input').focus();}
  }
  el('chat-form').addEventListener('submit',event=>{event.preventDefault();sendMessage(el('chat-input').value.trim());});
  el('chat-input').addEventListener('keydown',event=>{if(event.key==='Enter'&&(event.ctrlKey||event.metaKey)){event.preventDefault();el('chat-form').requestSubmit();}});
  document.querySelectorAll('[data-prompt]').forEach(button=>button.addEventListener('click',()=>{el('chat-input').value=button.dataset.prompt;el('chat-input').focus();}));
  el('new-chat').addEventListener('click',()=>{messages=[];draft='';el('chat-input').value='';el('include-pdf').checked=!!pdfContext;pdfContext?.prepare();analysisStatus('New conversation. Type a question to continue.');save();draw();status('New conversation.');el('chat-input').focus();});
  el('check-connection').addEventListener('click',async()=>{
    el('check-connection').disabled=true;el('connection-status').textContent='Checking model server…';el('connection-status').classList.remove('error');
    try{const data=await request('/api/llm/check',{});el('connection-status').textContent=data.modelAvailable?'Connected · model available':'Connected, but the configured model is not loaded. Available: '+data.models.join(', ');el('connection-status').classList.toggle('error',!data.modelAvailable);}
    catch(error){el('connection-status').textContent=error.message;el('connection-status').classList.add('error');}
    finally{el('check-connection').disabled=false;}
  });
  el('include-pdf').addEventListener('change',()=>{if(el('include-pdf').checked)pdfContext?.prepare();save();});
  el('retry-pdf-context').addEventListener('click',()=>pdfContext?.prepare(true));
  async function start(){
    config=await request('/api/llm/config');el('model-name').textContent=config.model;el('model-endpoint').textContent=config.baseUrl;
    try{const saved=JSON.parse(sessionStorage.getItem(key)||'null');if(Array.isArray(saved?.messages)&&saved.messages.length<=config.maxMessages&&saved.messages.every(m=>['user','assistant'].includes(m.role)&&typeof m.content==='string')){messages=saved.messages;el('include-pdf').checked=!!saved.includePdf;draft=typeof saved.draft==='string'?saved.draft:'';analysisScope=typeof saved.analysisScope==='string'?saved.analysisScope:'';el('pdf-context-status').textContent=typeof saved.pdfScope==='string'?saved.pdfScope:'';}}catch{}
    if(analysisId){el('conversation-title').textContent='AI Analysis';analysisStatus(analysisScope);}
    el('chat-input').value=draft;
    draw();
    let hasPdf=false;
    if(context){
      el('remove-context').hidden=false;el('context-title').textContent='Loading attachment…';
      const record=await request('/api/llm/context',context);tree.update(record,'context');
      if(['patents','arxiv'].includes(record.source)&&record.id){context.source=record.source;context.id=record.id;}
      hasPdf=!!record.pdfUrl;
      el('context-title').textContent=record.properties?.title||record.properties?.name||record.title||record.id;
      el('context-note').textContent='This record is included with each message. Source text is preserved.';
      if(context.source){el('pdf-option').hidden=false;el('context-document').href='/document?'+new URLSearchParams(context);el('context-document').hidden=false;el('context-note').textContent=record.recordScope||el('context-note').textContent;}
      else{const url=TurncoatDocumentLink(record.properties?.sourceUrl);if(url){el('context-document').href=url+'&'+new URLSearchParams(context);el('context-document').hidden=false;}}
      if(hasPdf&&context.source){
        if(!messages.length)el('include-pdf').checked=true;
        pdfContext=new TurncoatPdfContext(context,state=>{
          pdfReady=state.state==='ready';el('pdf-context-status').textContent=state.description;
          el('pdf-context-status').classList.toggle('error',state.state==='error');
          el('retry-pdf-context').hidden=state.state!=='error';
        });
        pdfContext.prepare();
      }else{el('include-pdf').checked=false;el('pdf-option').hidden=true;el('pdf-context-status').textContent='No PDF is listed. Chat will use the attached metadata.';}
      contextReady=true;
    }else{el('context-tree').hidden=true;}
    controls();
    if(autoAnalysis&&!messages.length){
      el('include-pdf').checked=hasPdf;
      const prompt=analysisPrompt+(hasPdf?'':'\n\nEvidence scope: no PDF is listed for this record. Explicitly label this a metadata-only review.');
      if(!hasPdf)el('pdf-context-status').textContent='No PDF is listed. Reviewing metadata only.';
      el('chat-input').value=prompt;
      await sendMessage(prompt,true);
    }
  }
  controls();start().catch(error=>{status(error.message,true);el('context-note').textContent=context?'Attachment unavailable. Detach it to start a general chat.':'';controls();});
  window.addEventListener('pagehide',()=>clearInterval(pendingTimer));
})();

/* Small shared DOM/API helpers for research workspaces. Never insert source HTML. */
(() => {
  const make=(tag,cls,text)=>{const node=document.createElement(tag);if(cls)node.className=cls;if(text!==undefined)node.textContent=text;return node;};
  const button=(text,action,cls='')=>{const node=make('button',cls,text);node.type='button';node.addEventListener('click',action);return node;};
  async function request(path,body){
    const response=await fetch(path,{method:body===undefined?'GET':'POST',headers:{Accept:'application/json',...(body===undefined?{}:{'Content-Type':'application/json','X-Turncoat-Token':document.querySelector('meta[name="turncoat-token"]').content})},body:body===undefined?undefined:JSON.stringify(body)});
    const data=await response.json();if(!response.ok)throw new Error(data.error?.message||`Request failed (${response.status}).`);return data;
  }
  const api=(action,body)=>request('/api/drilldown/'+action,body);
  let catalog;
  const getCatalog=()=>catalog||(catalog=request('/api/drilldown/catalog').catch(error=>{catalog=null;throw error;}));
  const link=(text,href)=>{
    const node=make('a','',text);
    try{const url=new URL(href,location.origin);if(!url.username&&!url.password&&((url.protocol==='http:'||url.protocol==='https:')&&url.origin===location.origin||url.protocol==='https:'&&['arxiv.org','export.arxiv.org','patents.google.com'].includes(url.hostname))){node.href=url.href;if(url.origin!==location.origin){node.target='_blank';node.rel='noopener noreferrer';}}}catch{}
    return node;
  };
  const table=headings=>{const node=make('table','research-table'),head=make('thead'),row=make('tr'),body=make('tbody');for(const heading of headings){const cell=make('th','',heading);cell.scope='col';row.append(cell);}head.append(row);node.append(head,body);return {node,body};};
  const note=text=>make('p','research-note',text);
  const bucketName=bucket=>bucket==='direct'?'Direct terms':bucket==='indirect'?'Potential indirect relevance':bucket==='context'?'Broad context terms':'Custom phrase';
  const prose=text=>{const node=make('div','markdown-body review-prose');window.TurncoatMarkdown(node,typeof text==='string'?text:'');return node;};
  function findingCard(value,evidence,{verified=false,reason='',bucket='',readOnly=false}={}){
    const finding=value&&typeof value==='object'&&!Array.isArray(value)?value:{};
    const card=make('article','finding-card ai-finding'+(verified?'':' unverified'));
    const head=make('header','finding-heading');head.append(make('strong','','AI finding'),make('span','citation-badge',verified?'Quote located':'Citation unverified'));card.append(head);
    if(bucket)card.append(note(bucket==='direct'?'Reported direct reference':'Reported potential indirect relevance'));
    const summary=prose(finding.finding||'The model returned an incomplete finding.');summary.classList.add('finding-summary');card.append(summary);
    if(reason)card.append(make('p','research-warning citation-reason',reason));
    if(typeof finding.quote==='string'&&finding.quote){
      const citation=make('figure','finding-citation markdown-body');
      citation.append(make('figcaption','',verified?'Quoted source passage':'Model-supplied quotation · not verified'));
      // Preserve the literal source quotation, including Chinese text and whitespace.
      citation.append(make('blockquote','',finding.quote));
      const footer=make('div','citation-actions'),field=typeof finding.field==='string'?finding.field:'unspecified';
      footer.append(make('span','citation-field',field==='pdf'?'PDF extract':field));
      const url=evidence?.record?.sourceUrl;if(url)footer.append(link('Open source ↗',url));
      const ref=evidence?.reference;
      if(!readOnly&&['patents','arxiv'].includes(ref?.source)&&typeof ref.id==='string')footer.append(link('Read PDF →','/document?'+new URLSearchParams({...ref,view:'pdf'})));
      footer.append(button('Copy quotation',async event=>{const control=event.currentTarget;try{await navigator.clipboard.writeText(finding.quote);control.textContent='Copied';}catch{control.textContent='Select text to copy';}}));
      citation.append(footer);card.append(citation);
    }
    if(typeof finding.relevance==='string'&&finding.relevance){card.append(make('h4','','Relevance'),prose(finding.relevance));}
    if(typeof finding.caveat==='string'&&finding.caveat){const caveat=prose(finding.caveat);caveat.classList.add('finding-caveat');card.append(make('h4','','Caveat'),caveat);}
    const raw=make('details','finding-raw');raw.append(make('summary','','Citation details & raw JSON'));
    if(verified&&Number.isInteger(finding.startByte)&&Number.isInteger(finding.endByte))raw.append(note('Exact passage located in '+finding.field+' · UTF-8 bytes '+finding.startByte+'–'+finding.endByte));
    raw.append(make('pre','research-raw',JSON.stringify(value,null,2)));card.append(raw);return card;
  }
  function renderAiFindings(container,result,evidence,options={}){
    for(const [bucket,label] of [['direct','Direct references'],['indirect','Potential indirect relevance']]){
      const section=make('section','finding-section');section.append(make('h3','',label));
      const findings=result?.[bucket]||[];if(!findings.length)section.append(note('No findings with a located quote in this section.'));
      for(const finding of findings)section.append(findingCard(finding,evidence,{...options,verified:true}));container.append(section);
    }
    if(result?.unverified?.length){
      const section=make('section','finding-section unverified-findings');section.append(make('h3','','Unverified citations'),note(result.unverified.length+' model findings need source verification.'));
      for(const finding of result.unverified)section.append(findingCard(finding.output,evidence,{...options,reason:finding.reason,bucket:finding.bucket}));container.append(section);
    }
    container.append(make('h3','','Limitations'),prose(result?.limitations||'Review the original document and extraction scope.'));
  }
  window.TurncoatResearch={make,button,request,api,getCatalog,link,table,note,bucketName,prose,renderAiFindings};
})();

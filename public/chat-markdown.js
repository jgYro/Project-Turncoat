/* Parse Markdown into text nodes and a small set of structural DOM elements. */
(() => {
  'use strict';
  const parser=window.markdownit({html:false,linkify:true,typographer:false,maxNesting:20});
  const tags=new Set(['p','h1','h2','h3','h4','h5','h6','ul','ol','li','blockquote','table','thead','tbody','tr','th','td','strong','em','s','a']);
  function linkTarget(value){
    if(typeof value!=='string'||!value.trim())return null;
    try{
      const url=new URL(value,location.origin);
      if(!['http:','https:','mailto:'].includes(url.protocol)||url.username||url.password)return null;
      return url;
    }catch{return null;}
  }
  function setLink(node,value){
    const url=linkTarget(value);if(!url)return;
    const reader=window.TurncoatDocumentLink?.(url.href);
    node.href=reader||url.href;
    if(!reader&&url.origin!==location.origin){node.target='_blank';node.rel='noopener noreferrer';}
  }
  function codeBlock(token){
    const block=document.createElement('figure');block.className='markdown-code';
    const bar=document.createElement('figcaption'),label=document.createElement('span'),copy=document.createElement('button');
    label.textContent=token.info?.trim().split(/\s+/)[0]||'text';
    copy.type='button';copy.textContent='Copy code';copy.setAttribute('aria-label','Copy code block');
    copy.addEventListener('click',async()=>{
      try{await navigator.clipboard.writeText(token.content);copy.textContent='Copied';}
      catch{copy.textContent='Select text to copy';}
    });
    bar.append(label,copy);const pre=document.createElement('pre'),code=document.createElement('code');
    code.textContent=token.content;pre.append(code);block.append(bar,pre);return block;
  }
  window.TurncoatMarkdown=(container,text)=>{
    container.replaceChildren();
    if(typeof text!=='string')return;
    // Bound expensive rich rendering while keeping oversized replies readable.
    if(text.length>100000){container.textContent=text;container.classList.add('plain-reply');return;}
    container.classList.remove('plain-reply');
    try{
      const root=document.createDocumentFragment(),stack=[root];let count=0;
      const append=node=>stack[stack.length-1].append(node);
      function render(tokens){
        for(const token of tokens){
          if(++count>20000)throw new Error('Markdown rendering limit');
          if(token.hidden)continue;
          if(token.type==='inline'){render(token.children||[]);continue;}
          if(token.type==='fence'||token.type==='code_block'){append(codeBlock(token));continue;}
          if(token.type==='code_inline'){const code=document.createElement('code');code.textContent=token.content;append(code);continue;}
          if(token.type==='softbreak'){append(document.createTextNode('\n'));continue;}
          if(token.type==='hardbreak'||token.type==='hr'){append(document.createElement(token.type==='hr'?'hr':'br'));continue;}
          if(token.type==='image'){
            const label=document.createElement('a');label.textContent='[Image: '+(token.content||'linked image')+']';
            setLink(label,token.attrGet('src'));append(label);continue;
          }
          if(token.nesting===-1){if(stack.length>1)stack.pop();continue;}
          if(token.nesting===1){
            const node=document.createElement(tags.has(token.tag)?token.tag:'span');
            if(token.tag==='a')setLink(node,token.attrGet('href'));
            if(token.tag==='ol'){
              const start=Number(token.attrGet('start'));if(Number.isSafeInteger(start)&&start>0)node.start=start;
            }
            if(['th','td'].includes(token.tag)){
              const align=token.attrGet('style');
              if(['text-align:left','text-align:center','text-align:right'].includes(align))node.className='align-'+align.slice(11);
            }
            append(node);stack.push(node);continue;
          }
          append(document.createTextNode(token.content||''));
        }
      }
      render(parser.parse(text,{}));container.append(root);
      for(const table of container.querySelectorAll('table')){
        const scroller=document.createElement('div');scroller.className='markdown-table';scroller.tabIndex=0;
        scroller.setAttribute('role','region');scroller.setAttribute('aria-label','Scrollable table');
        table.replaceWith(scroller);scroller.append(table);
      }
    }catch{container.textContent=text;container.classList.add('plain-reply');}
  };
})();

/* Shared DOM-only JSON inspector. Source values are never interpreted as HTML. */
(() => {
  'use strict';
  const make = (tag, cls, text) => {const e=document.createElement(tag); if(cls)e.className=cls; if(text!==undefined)e.textContent=text; return e;};
  function documentLink(value) {
    try {
      const u=new URL(value); if(u.protocol!=='https:' || u.username || u.password) return null;
      if(u.hostname==='patents.google.com') {
        const id=u.pathname.match(/^\/patent\/([A-Z]{2}[A-Z0-9]+)(?:\/|$)/)?.[1];
        if(id)return '/document?source=patents&id='+encodeURIComponent(id);
      }
      if(['arxiv.org','export.arxiv.org'].includes(u.hostname)) {
        const m=u.pathname.match(/^\/(abs|pdf)\/(.+?)(?:\.pdf)?$/);
        if(m)return '/document?source=arxiv&id='+encodeURIComponent(m[2])+(m[1]==='pdf'?'&view=pdf':'');
      }
      if(u.hostname==='patentimages.storage.googleapis.com') {
        const id=u.pathname.match(/\/([A-Z]{2}[A-Z0-9]+)\.pdf$/)?.[1];
        if(id)return '/document?source=patents&id='+encodeURIComponent(id)+'&view=pdf';
      }
    } catch {}
    return null;
  }
  window.TurncoatDocumentLink=documentLink;
  window.TurncoatJsonTree=class {
    constructor(container, resolveLink=link=>link) {
      this.container=container; this.value=null; this.signature=undefined;
      this.resolveLink=resolveLink;
      container.classList.add('json-inspector');
      const bar=make('div','json-toolbar');
      this.copy=make('button','','Copy JSON'); this.copy.type='button';
      this.copy.addEventListener('click',async()=>{try{await navigator.clipboard.writeText(JSON.stringify(this.value,null,2));this.note.textContent='JSON copied';}catch{this.note.textContent='Clipboard unavailable. Use Raw JSON to select and copy.';}});
      const collapse=make('button','','Collapse'); collapse.type='button'; collapse.addEventListener('click',()=>this.tree.querySelectorAll('details').forEach(e=>e.open=false));
      this.rawToggle=make('button','','Raw JSON'); this.rawToggle.type='button'; this.rawToggle.setAttribute('aria-pressed','false');
      this.rawToggle.addEventListener('click',()=>{const show=this.raw.hidden;this.raw.hidden=!show;this.tree.hidden=show;this.rawToggle.setAttribute('aria-pressed',String(show));});
      this.note=make('span','json-copy-status');this.note.setAttribute('role','status');
      bar.append(this.copy,collapse,this.rawToggle);
      this.tree=make('div','json-tree');this.raw=make('pre','json-raw');this.raw.hidden=true;
      container.replaceChildren(bar,this.note,this.tree,this.raw);
    }
    update(value, identity='') {
      const signature=JSON.stringify(value);if(signature===this.signature && identity===this.identity)return;
      const same=identity===this.identity, opened=new Set();
      if(same)this.tree.querySelectorAll('details[open]').forEach(e=>opened.add(e.dataset.path));
      this.identity=identity;this.signature=signature;this.value=value;this.note.textContent='';
      this.raw.textContent=JSON.stringify(value,null,2);this.tree.replaceChildren();
      if(value==null){this.tree.append(make('p','json-empty','Select a record to inspect its source fields.'));return;}
      const branch=(key,v,path,depth)=>{
        const collection=v!==null && typeof v==='object';
        const row=make(collection?'details':'div',collection?'json-branch':'json-leaf');
        const label=collection?make('summary'):row;
        if(key!==null)label.append(make('span','json-key',key),make('span','json-punctuation',': '));
        if(collection) {
          const array=Array.isArray(v), entries=Object.entries(v);
          label.append(make('span','json-type',array?'array':'object'),make('span','json-count',`${entries.length} ${array?'items':'fields'}`));
          row.dataset.path=path;row.append(label);
          const children=make('div','json-children');row.append(children);let offset=0;
          const fill=()=>{
            if(depth>=32){children.append(make('span','json-empty','Nested data continues in Raw JSON.'));return;}
            const end=Math.min(offset+80,entries.length);
            for(;offset<end;offset++){const [k,item]=entries[offset];children.append(branch(array?`[${k}]`:k,item,path+'/'+k.replaceAll('~','~0').replaceAll('/','~1'),depth+1));}
            if(offset<entries.length){const more=make('button','json-more',`Show more (${entries.length-offset} remaining)`);more.type='button';more.addEventListener('click',()=>{more.remove();fill();});children.append(more);}
          };
          let loaded=false;const load=()=>{if(!loaded){loaded=true;fill();}};
          row.addEventListener('toggle',()=>{if(row.open)load();});
          if((same && opened.has(path)) || (!same && depth<2) || (this.signature===signature && !same && depth===0)){row.open=true;load();}
        } else {
          const type=v===null?'null':typeof v;
          const text=type==='string'?v:JSON.stringify(v);
          const link=type==='string'?documentLink(v):null;
          const span=make(link?'a':'span','json-value json-'+type,text);
          if(link)span.href=this.resolveLink(link);
          label.append(span);
        }
        return row;
      };
      this.tree.append(branch(null,value,'',0));
    }
  };
})();

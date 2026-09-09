/* Server-owned jobs; this view can be closed without cancelling their work. */
(() => {
  'use strict';
  const header=document.querySelector('.site-header');if(!header)return;
  const make=(tag,cls,text)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n;};
  const pending=job=>['queued','preparing','running'].includes(job.state);
  const states={queued:'Queued',preparing:'Preparing PDF',running:'Running',succeeded:'Complete',failed:'Failed',interrupted:'Interrupted'};
  const label=job=>job.kind==='ai'?'AI review':'Keyword analysis';
  const read=key=>{try{return JSON.parse(localStorage.getItem(key)||'[]');}catch{return [];}};
  const remember=(key,ids)=>{try{localStorage.setItem(key,JSON.stringify([...new Set([...read(key),...ids])].slice(-300)));}catch{}};
  const trackedKey='turncoat-tracked-jobs-v1',notifiedKey='turncoat-notified-jobs-v1';
  const nav=make('div','jobs-nav'),toggle=make('button','jobs-toggle','Jobs'),panel=make('section','jobs-panel'),list=make('div','jobs-list'),summary=make('p','jobs-summary','Checking background jobs…');
  toggle.type='button';toggle.id='jobs-toggle';toggle.setAttribute('aria-expanded','false');toggle.setAttribute('aria-controls','jobs-panel');panel.id='jobs-panel';panel.hidden=true;panel.setAttribute('aria-label','Background analysis jobs');
  panel.append(make('h2','','Background analysis'),summary,list);nav.append(toggle,panel);header.querySelector('.local-indicator')?.replaceWith(nav);if(!nav.isConnected)header.append(nav);
  const toasts=make('div','jobs-toasts');toasts.setAttribute('aria-live','polite');toasts.setAttribute('aria-atomic','false');document.body.append(toasts);
  let jobs=[],timer=null,fetching=null,viewing=null,closed=false;
  function href(job){return '/graph?'+new URLSearchParams({dataset:job.dataset,document:job.node,...(job.reportId?{report:job.reportId}:{})});}
  function open(job){
    if(window.TurncoatDrilldown){window.TurncoatDrilldown.openReference(job,job.reportId).catch(error=>{summary.textContent=error.message;});panel.hidden=true;toggle.setAttribute('aria-expanded','false');}
    else location.assign(href(job));
  }
  function action(job,text){const a=make('a','',text);a.href=href(job);a.addEventListener('click',event=>{if(!event.ctrlKey&&!event.metaKey&&!event.shiftKey&&event.button===0){event.preventDefault();open(job);}});return a;}
  function toast(job){
    const card=make('section','job-toast '+job.state);card.setAttribute('role','status');card.append(make('strong','',label(job)+(job.state==='succeeded'?' complete':' '+states[job.state].toLowerCase())),make('p','',job.title),action(job,job.reportId?'View results →':'Open investigation →'));
    const close=make('button','job-toast-close','×');close.type='button';close.setAttribute('aria-label','Dismiss notification');close.addEventListener('click',()=>card.remove());card.append(close);toasts.append(card);while(toasts.children.length>3)toasts.firstElementChild.remove();
  }
  function notify(){
    if(document.hidden)return;
    const tracked=new Set(read(trackedKey)),notified=new Set(read(notifiedKey)),done=[];
    for(const job of jobs){
      if(pending(job)||!tracked.has(job.id)||notified.has(job.id))continue;
      if(!viewing||viewing.dataset!==job.dataset||viewing.node!==job.node)toast(job);
      done.push(job.id);
    }
    remember(notifiedKey,done);
  }
  function render(){
    const count=jobs.filter(pending).length;toggle.textContent=count?'◌ '+count+' running':'✓ Jobs';toggle.classList.toggle('has-running',count>0);toggle.setAttribute('aria-label',count?count+' background analysis jobs running':'Background analysis jobs');
    summary.textContent=count?count+' jobs active. You can keep browsing.':'No analysis jobs running.';list.replaceChildren();
    for(const job of jobs){const row=make('article','job-row '+job.state);row.append(action(job,job.title),make('span','job-kind',label(job)+(job.preset?' · '+job.preset:'')),make('span','job-state',states[job.state]||job.state));if(job.error)row.append(make('p','job-error',job.error));if(job.warning)row.append(make('p','job-error','PDF unavailable; keyword scan used metadata.'));list.append(row);}
    if(!jobs.length)list.append(make('p','','Investigate a paper or patent to start keyword screening and AI review.'));
  }
  function ingest(incoming,replace=false){
    if(!Array.isArray(incoming))return;
    const map=new Map((replace?[]:jobs).map(j=>[j.id,j]));for(const job of incoming)map.set(job.id,job);jobs=[...map.values()].sort((a,b)=>Number(pending(b))-Number(pending(a))||b.createdAt.localeCompare(a.createdAt)).slice(0,100);
    remember(trackedKey,jobs.filter(pending).map(j=>j.id));render();notify();document.dispatchEvent(new CustomEvent('turncoat:analysis-jobs',{detail:{jobs}}));
  }
  async function refresh(){
    if(fetching)return fetching;
    clearTimeout(timer);fetching=(async()=>{
      try{const response=await fetch('/api/analysis/jobs',{cache:'no-store'});const data=await response.json();if(!response.ok)throw new Error(data.error?.message||'Job status unavailable.');ingest(data.jobs,true);}
      catch(error){summary.textContent=error.message;toggle.textContent='Jobs · offline';}
      finally{fetching=null;if(!closed)timer=setTimeout(refresh,jobs.some(pending)?1500:8000);}
    })();return fetching;
  }
  async function start(reference,options={}){
    const token=document.querySelector('meta[name="turncoat-token"]')?.content;if(!token)throw new Error('Open the graph workspace to start analysis.');
    const response=await fetch('/api/analysis/jobs',{method:'POST',headers:{'Content-Type':'application/json','X-Turncoat-Token':token},body:JSON.stringify({...reference,...options})});const data=await response.json();if(!response.ok)throw new Error(data.error?.message||'Could not start background analysis.');ingest(data.jobs);refresh();return data.jobs;
  }
  toggle.addEventListener('click',()=>{panel.hidden=!panel.hidden;toggle.setAttribute('aria-expanded',String(!panel.hidden));if(!panel.hidden)refresh();});
  document.addEventListener('pointerdown',event=>{if(!nav.contains(event.target)){panel.hidden=true;toggle.setAttribute('aria-expanded','false');}});
  document.addEventListener('keydown',event=>{if(event.key==='Escape'&&!panel.hidden){panel.hidden=true;toggle.setAttribute('aria-expanded','false');toggle.focus();}});
  document.addEventListener('visibilitychange',()=>{if(!document.hidden){notify();refresh();}});
  window.addEventListener('pagehide',()=>{closed=true;clearTimeout(timer);});window.addEventListener('pageshow',()=>{closed=false;refresh();});
  window.TurncoatJobs={start,refresh,ingest,items:()=>jobs,setViewing:reference=>{viewing=reference;}};
  refresh();
})();

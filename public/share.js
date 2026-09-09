/* Sharing creates an immutable local snapshot; it never launches discovery. */
(() => {
  const {make,button,request,note}=TurncoatResearch,trigger=document.getElementById('share-investigation');
  const dialog=make('dialog','share-dialog'),title=make('h2','','Share investigation'),message=make('p','research-status');message.setAttribute('role','status');title.id='share-title';dialog.setAttribute('aria-labelledby',title.id);
  const include=make('input');include.type='checkbox';include.checked=true;const label=make('label','research-check');label.append(include,document.createTextNode('Include latest saved keyword scans and AI reviews'));
  const address=make('input');address.readOnly=true;address.setAttribute('aria-label','Sharing link');address.hidden=true;
  let dataset='',busy=false;
  function status(text,error=false){message.textContent=text;message.classList.toggle('error',error);}
  async function copy(){try{await navigator.clipboard.writeText(address.value);status('Link copied.');}catch{address.focus();address.select();status('Link ready. Copy the selected address.');}}
  const copyButton=button('Copy link',copy),create=button('Create link & copy',async()=>{
    if(busy)return;busy=true;create.disabled=true;status('Saving investigation snapshot…');
    try{const data=await request('/api/shares/create',{dataset,includeReports:include.checked});address.value=new URL(data.path,location.origin).href;address.hidden=false;copyButton.hidden=false;await copy();if(data.reportsOmitted)status('Link ready. '+data.reportsOmitted+' reports exceeded the snapshot limit.');await load();}
    catch(error){status(error.message,true);}finally{busy=false;create.disabled=false;}
  },'research-primary'),list=make('div','share-links');copyButton.hidden=true;
  async function load(){
    try{const data=await request('/api/shares/list',{dataset});list.replaceChildren();
      for(const share of data.shares){const row=make('div','share-link-row'),pick=button(share.createdAt,()=>{address.value=new URL(share.path,location.origin).href;address.hidden=false;copyButton.hidden=false;copy();});
        row.append(pick,button('Revoke',async event=>{event.currentTarget.disabled=true;try{await request('/api/shares/revoke',{dataset,token:share.token});if(address.value.endsWith(share.path)){address.hidden=true;address.value='';copyButton.hidden=true;}status('Link revoked. Downloaded copies are unaffected.');await load();}catch(error){status(error.message,true);event.target.disabled=false;}}));list.append(row);}
    }catch(error){status(error.message,true);}
  }
  dialog.append(title,note('Create a read-only snapshot of the saved graph. Later searches and reviews will not change this link. PDF files and chat conversations are not included.'),label,create,address,copyButton,message,note('Recipients need access to this Turncoat server. A localhost or 127.0.0.1 address works only on your computer. This does not publish the app to the internet.'),make('h3','','Existing links'),list,button('Close',()=>dialog.close()));document.body.append(dialog);
  trigger.addEventListener('click',()=>{dataset=trigger.dataset.investigation;address.hidden=true;copyButton.hidden=true;message.textContent='';list.replaceChildren();dialog.showModal();load();});
})();

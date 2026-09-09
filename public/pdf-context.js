// Shared preparation state for readers, chat and document screening.
// The server coalesces extraction across browser tabs and queues different PDFs.
(() => {
  'use strict';
  window.TurncoatPdfContext=class {
    constructor(reference,onChange){this.reference=reference;this.onChange=onChange;this.state='idle';this.data=null;this.error=null;this.pending=null;}
    async prepare(retry=false){
      if(this.pending)return this.pending;
      if(this.state==='ready')return this.data;
      if(this.state==='error'&&!retry)return null;
      this.state='loading';this.error=null;this.onChange(this);
      this.pending=(async()=>{
        try{
          const response=await fetch('/api/documents/text',{method:'POST',headers:{'Content-Type':'application/json','X-Turncoat-Token':document.querySelector('meta[name="turncoat-token"]').content},body:JSON.stringify(this.reference)});
          const data=await response.json();
          if(!response.ok)throw new Error(data.error?.message||'PDF context is unavailable.');
          if(typeof data.text!=='string'||!data.text.trim())throw new Error('The PDF returned no readable text.');
          this.data=data;this.state='ready';return data;
        }catch(error){this.error=error;this.state='error';return null;}
        finally{this.pending=null;this.onChange(this);}
      })();
      return this.pending;
    }
    get description(){
      if(this.state==='ready')return 'PDF context ready · '+this.data.scope;
      if(this.state==='error')return 'PDF context unavailable · '+this.error.message;
      return 'Preparing PDF context… Downloading or waiting for extraction; Docling OCR runs if needed.';
    }
  };
})();

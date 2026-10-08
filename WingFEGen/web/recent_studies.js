/* Recent portable Studies. This catalogue never writes or deletes Study files. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.WingRecentStudies = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";
  const DATABASE = "wingfegen-recent-studies", STORE = "studies", CONTENTS = "snapshots", PREFIX = "wingfegen.recent-study.";
  const valid = row => row && typeof row.id === "string" && typeof row.name === "string" && Number.isFinite(row.updatedAt);
  const sort = rows => rows.sort((a,b) => b.updatedAt-a.updatedAt || a.name.localeCompare(b.name));
  function create(options = {}) {
    const doc = options.document || globalThis.document, host = options.host || doc.defaultView || globalThis;
    if(typeof options.onOpen!=="function")throw new Error("Recent Studies requires an onOpen Study loader.");
    const entries = new Map(); let db = null, stopped = false, dialog = null, list = null, status = null, busy = false;
    let queue = Promise.resolve(), warning = "", lastTime = 0, startupPromise = null;
    const el = (tag, cls, text) => { const node=doc.createElement(tag); if(cls)node.className=cls; if(text!==undefined)node.textContent=text; return node; };
    function notice(message, error) {
      warning=message; if(status) {status.textContent=message; status.hidden=!message;}
      if(error) { try { options.onError?.(message,error); } catch(_) {} }
    }
    function transaction(mode, action, stores = [STORE]) {
      return new Promise((resolve,reject) => {
        let tx, request;
        try {
          tx=db.transaction(stores,mode);
          tx.oncomplete=()=>resolve(request?.result);tx.onabort=tx.onerror=()=>reject(tx.error || request?.error || new Error("Recent Studies storage failed."));
          request=action(...stores.map(name=>tx.objectStore(name)));
        } catch(error) {
          // A later put can throw synchronously after an earlier put was
          // queued. Abort both stores before returning the original failure.
          try{tx?.abort();}catch(_){}reject(error);
        }
      });
    }
    function localRows() {
      const rows=[];
      try { const storage=host.localStorage; for(let i=0;i<storage.length;i++) {const key=storage.key(i);if(!key?.startsWith(PREFIX))continue;try { const row=JSON.parse(storage.getItem(key));if(valid(row)&&typeof row.text==="string")rows.push({...row,persisted:true}); } catch(_) {} } }
      catch(_) {} return rows;
    }
    async function initialize() {
      for(const row of localRows()) entries.set(row.id,row);
      try {
        db=await new Promise((resolve,reject) => {
          let request, settled=false;
          const timer=host.setTimeout(()=>finish(new Error("Recent Studies storage is unavailable or blocked.")),2500);
          function finish(error,value) {if(settled){value?.close();return;}settled=true;host.clearTimeout(timer);error?reject(error):resolve(value);}
          try { if(!host.indexedDB)throw new Error("IndexedDB is unavailable.");request=host.indexedDB.open(DATABASE,2); }
          catch(error) {finish(error);return;}
          request.onupgradeneeded=()=>{
            const database=request.result;
            if(!database.objectStoreNames.contains(STORE))database.createObjectStore(STORE,{keyPath:"id"});
            if(!database.objectStoreNames.contains(CONTENTS))database.createObjectStore(CONTENTS,{keyPath:"id"});
            // Version 1 embedded every body in its catalogue row. Migrate one
            // record at a time so upgrading does not materialize all snapshots.
            const metadata=request.transaction.objectStore(STORE),bodies=request.transaction.objectStore(CONTENTS),cursor=metadata.openCursor();
            cursor.onsuccess=()=>{const item=cursor.result;if(!item)return;const row=item.value;if(typeof row.text==="string"){bodies.put({id:row.id,text:row.text});row.contentLength=row.text.length;delete row.text;item.update(row);}item.continue();};
          };
          request.onsuccess=()=>finish(null,request.result);request.onerror=()=>finish(request.error);request.onblocked=()=>finish(new Error("Close other WingFEGen tabs to unlock Recent Studies storage."));
        });
        db.onversionchange=()=>{db?.close();db=null;};
        for(const row of await transaction("readonly",s=>s.getAll())) if(valid(row)&&(!entries.has(row.id)||entries.get(row.id).updatedAt<row.updatedAt))entries.set(row.id,{...row,persisted:true});
      } catch(error) { notice("Browser storage is limited. Saved copies use available local storage; entries that cannot be stored are marked Session only.",error); }
      if(stopped) {db?.close();db=null;}
    }
    const ready=initialize();
    function serial(action) {const result=queue.then(()=>ready).then(action);queue=result.catch(()=>{});return result;}
    function stored(row, withHandle=true, withText=false) {
      const {persisted,...data}=row;if(!withHandle)delete data.handle;if(!withText)delete data.text;return data;
    }
    async function body(row) {
      if(typeof row.text==="string")return row.text;
      if(!db)throw new Error("The stored Study copy is unavailable. Browse for its disk file or relink it.");
      const saved=await transaction("readonly",s=>s.get(row.id),[CONTENTS]);
      if(typeof saved?.text!=="string")throw new Error("The stored Study copy is missing. Browse for its disk file or relink it.");
      return saved.text;
    }
    async function writeIndexed(row,withHandle=true) {
      await transaction("readwrite",(metadata,bodies)=>{bodies.put({id:row.id,text:row.text});return metadata.put(stored(row,withHandle));},[STORE,CONTENTS]);
      row.persisted=true;delete row.text;try{host.localStorage.removeItem(PREFIX+row.id);}catch(_){}
    }
    async function persist(row) {
      let error;
      if(db) {
        try {await writeIndexed(row);return;}
        catch(e) {error=e;}
        // Some browsers support IndexedDB but cannot clone filesystem handles.
        if(row.handle) try {await writeIndexed(row,false);notice("Saved copy recorded. This browser could not retain the disk link; relink the file after restarting.",error);return;}catch(e){error=e;}
      }
      try {host.localStorage.setItem(PREFIX+row.id,JSON.stringify(stored(row,false,true)));row.persisted=true;return;}
      catch(e) {error=e;row.persisted=false;notice("Recent Study is available for this session only: browser storage is unavailable or full. The Study file itself is unaffected.",error);}
    }
    async function sameHandle(handle) {
      for(const row of entries.values()) if(row.handle===handle)return row;
      for(const row of entries.values()) if(row.handle&&typeof handle.isSameEntry==="function")try{if(await handle.isSameEntry(row.handle))return row;}catch(_){}
      return null;
    }
    function record(input) {
      return serial(async()=>{
        try {
          if(!input||typeof input.name!=="string"||typeof input.text!=="string")throw new Error("A recent Study needs its filename and saved text.");
          let existing=input.id?entries.get(input.id):null;
          if(existing?.name!==input.name&&!input.replaceLink)existing=null;
          if(input.handle)existing=await sameHandle(input.handle) || (input.replaceLink?existing:null);
          if(!existing&&!input.handle)for(const candidate of entries.values())if(!candidate.handle&&candidate.name===input.name&&(candidate.contentLength??candidate.text?.length)===input.text.length){try{if(await body(candidate)===input.text){existing=candidate;break;}}catch(_){}}
          const id=existing?.id || host.crypto?.randomUUID?.() || "study-"+Date.now().toString(36)+"-"+Math.random().toString(36).slice(2);
          let updatedAt=Math.max(Date.now(),lastTime+1);for(const row of entries.values())updatedAt=Math.max(updatedAt,row.updatedAt+1);lastTime=updatedAt;
          const handle=input.handle||(input.replaceLink?null:existing?.handle)||null;
          const row={id,name:input.name,text:input.text,contentLength:input.text.length,updatedAt,source:input.source==="saved"?"saved":"loaded",handle,
            diskLinked:!!(handle||!input.replaceLink&&existing?.diskLinked),persisted:false};
          entries.set(id,row);await persist(row);render();
          const info={id,persisted:row.persisted,name:row.name};try{options.onRecorded?.(info);}catch(_){}return info;
        } catch(error) {notice("The Study was opened or saved, but could not be added to Recent Studies.",error);return {id:null,persisted:false};}
      });
    }
    function remove(id) {
      return serial(async()=>{
        let failed=false;
        if(db)try{await transaction("readwrite",(metadata,bodies)=>{bodies.delete(id);return metadata.delete(id);},[STORE,CONTENTS]);}catch(_){failed=true;}
        try{host.localStorage.removeItem(PREFIX+id);}catch(_){if(!db)failed=true;}
        if(failed){notice("Could not remove the stored recent entry. Browser storage is unavailable; no Study file was changed.");return false;}
        entries.delete(id);render();return true;
      });
    }
    function button(label,action,cls="") {const node=el("button",cls,label);node.type="button";node.addEventListener("click",action);return node;}
    function setBusy(value) {busy=value;if(dialog)for(const node of dialog.querySelectorAll("button"))node.disabled=value;}
    function close() {if(dialog?.open)dialog.close();}
    async function deliver(file,context) {
      const text=await file.text();close();
      const result=await options.onOpen?.(file,context);
      if(result===false)return false;
      await record({name:file.name,text,handle:context.handle,id:context.id,source:"loaded",replaceLink:context.source==="relink"});return true;
    }
    async function run(action) {
      if(busy||stopped)return false;setBusy(true);
      try{return await action();}catch(error){if(error?.name!=="AbortError"){notice(error.message||"Could not open the Study.",error);if(!dialog?.open)await open();}return false;}
      finally{setBusy(false);}
    }
    async function disk(row) {
      return run(async()=>{
        const handle=row.handle;if(!handle)throw new Error("This disk link is unavailable. Relink the file or explicitly open its stored copy.");
        let permission=typeof handle.queryPermission==="function"?await handle.queryPermission({mode:"read"}):"granted";
        if(permission!=="granted"&&typeof handle.requestPermission==="function")permission=await handle.requestPermission({mode:"read"});
        if(permission!=="granted")throw new Error("Disk access was not granted. Relink the file or explicitly open its stored copy.");
        let file;try{file=await handle.getFile();}catch(_){throw new Error("The disk file is unavailable or has moved. Relink it, or explicitly open the stored copy.");}
        return deliver(file,{id:row.id,handle,source:"disk"});
      });
    }
    function snapshot(row) {return run(async()=>deliver(new host.File([await body(row)],row.name,{type:"application/json",lastModified:row.updatedAt}),{id:row.id,handle:row.handle,source:"snapshot"}));}
    // Startup must never trigger a permission prompt or silently open a
    // different older project. Only the newest entry's disk/snapshot is used.
    let startupSettled=false;
    function restoreLatest(settings = {}) {
      if(startupPromise&&!(settings.retry&&startupSettled))return startupPromise;
      startupSettled=false;
      const automatic=settings.automatic!==false;
      startupPromise=(async()=>{
        const allowed=()=>!stopped&&(typeof settings.canRestore!=="function"||settings.canRestore());
        const emit=info=>{try{settings.onNotice?.(info);}catch(_){}return info;};
        const timestamp=value=>new Date(value).toLocaleString();
        let row=null,source=null,acquired=false;
        try{
          await ready;await queue;
          if(!allowed()||busy)return{status:"skipped"};
          row=sort(Array.from(entries.values()))[0];
          if(!row)return warning?emit({status:"failed",message:"The latest Study could not be checked. "+warning+(automatic?" The server input will be used.":" Choose another startup option or try again.")}):{status:"empty"};
          setBusy(true);acquired=true;
          emit({status:"loading",name:row.name,recordedAt:row.updatedAt,message:"Restoring latest Study: "+row.name+" (last "+(row.source==="saved"?"saved":"opened")+" "+timestamp(row.updatedAt)+")."});
          let file=null,reason="No retained disk link is available.";
          if(row.handle){
            let timer;
            try{
              file=await Promise.race([(async()=>{
                if(typeof row.handle.queryPermission!=="function")throw Error("The browser cannot check existing disk permission.");
                const permission=await row.handle.queryPermission({mode:"read"});
                if(permission!=="granted")throw Error("Disk access is not already granted; no permission prompt was opened.");
                return await row.handle.getFile();
              })(),new Promise((_,reject)=>{timer=host.setTimeout(()=>reject(Error("The disk file did not respond in time.")),settings.diskTimeoutMs??4000);})]);
              if(!file||typeof file.text!=="function")throw Error("The linked disk file is unavailable.");
              source="disk";
            }catch(error){file=null;reason=error?.message||"The linked disk file is unavailable.";}
            finally{host.clearTimeout(timer);}
          }
          if(!allowed())return{status:"skipped"};
          if(!file){source="snapshot";file=new host.File([await body(row)],row.name,{type:"application/json",lastModified:row.updatedAt});}
          if(!allowed())return{status:"skipped"};
          const info={name:file.name||row.name,source,recordedAt:row.updatedAt,fileModifiedAt:Number.isFinite(file.lastModified)?file.lastModified:null,
            ...(source==="snapshot"?{reason}:{}),id:row.id};
          emit({...info,status:"loading",message:source==="disk"?"Loading latest Study "+info.name+" from its accessible disk file.":"Loading stored browser copy of "+info.name+" from "+timestamp(row.updatedAt)+". "+reason});
          const result=await options.onOpen(file,{id:row.id,handle:source==="disk"?row.handle:null,source,automatic});
          if(result===false)throw Error("The Study loader rejected the latest Study. Check the Log for details.");
          // The application has accepted the complete Study before its cache
          // is refreshed. No disk file is ever written by automatic restore.
          if(!stopped)await record({id:row.id,name:info.name,text:await file.text(),handle:source==="disk"?row.handle:null,source:"loaded"});
          if(stopped)return{...info,status:"skipped"};
          const location=source==="disk"?"its disk file"+(info.fileModifiedAt?" (modified "+timestamp(info.fileModifiedAt)+")":""):
            "the stored browser copy captured "+timestamp(row.updatedAt)+". "+reason.replace(/\.$/,"");
          return emit({...info,status:"restored",message:(automatic?"Automatically restored ":"Restored ")+info.name+" from "+location+". Verify this is the intended Study; use Load Study to choose another project."});
        }catch(error){
          if(stopped)return{status:"skipped"};
          const info={status:"failed",name:row?.name,source,recordedAt:row?.updatedAt,message:(automatic?"Could not automatically restore ":"Could not restore ")+(row?.name||"the latest Study")+": "+(error?.message||String(error))+(automatic?" The server input will be used.":" Choose another startup option or try again.")};
          return emit(info);
        }finally{if(acquired)setBusy(false);}
      })().finally(()=>{startupSettled=true;});
      return startupPromise;
    }
    function pickerRequest() {
      return host.showOpenFilePicker({id:"wingfegen-study",multiple:false,types:[{description:"WingFEGen Study",accept:{"application/json":[".wingfem.json"]}}]});
    }
    function browse(row=null) {
      if(busy||stopped)return Promise.resolve(false);
      // Request immediately within the button activation, before any await.
      if(typeof host.showOpenFilePicker==="function"&&host.isSecureContext!==false) {
        let request;try{request=pickerRequest();}catch(error){request=Promise.reject(error);}
        return run(async()=>{const handles=await request;if(!handles?.length)return false;const handle=handles[0],file=await handle.getFile();return deliver(file,{id:row?.id,handle,source:row?"relink":"browse"});});
      }
      if(!row&&typeof options.onBrowse==="function"){close();options.onBrowse();return Promise.resolve(false);}
      const input=el("input");input.type="file";input.accept=".wingfem.json,application/json";input.hidden=true;doc.body.appendChild(input);
      input.addEventListener("change",()=>{const file=input.files?.[0];input.remove();if(file)run(()=>deliver(file,{id:row?.id,handle:null,source:"relink"}));},{once:true});
      input.addEventListener("cancel",()=>input.remove(),{once:true});input.click();return Promise.resolve(false);
    }
    function render() {
      if(!list||stopped)return;list.replaceChildren();
      const rows=sort(Array.from(entries.values()));
      if(!rows.length)list.append(el("p","recent-studies-empty","No recent Studies yet. Save or load a .wingfem.json Study to add it here."));
      for(const row of rows) {
        const item=el("article","recent-study");item.dataset.recentId=row.id;
        const name=el("h3","recent-study-name",row.name),meta=el("p","recent-study-meta",(row.source==="saved"?"Saved":"Opened")+" "+new Date(row.updatedAt).toLocaleString());
        const description=row.handle?"Disk link: opens the latest file after browser permission. Stored copy is the last successful save or load.":row.diskLinked?"Disk link needs relinking. Stored copy is the last successful save or load.":"Stored browser copy from the last successful save or load. Later changes to the disk file are not included.";
        item.append(name,meta,el("p","recent-study-description",description));
        if(!row.persisted)item.append(el("strong","recent-study-session","Session only"));
        const actions=el("div","recent-study-actions");
        if(row.handle)actions.append(button("Open latest disk file",()=>disk(row),"recent-study-disk"));
        actions.append(button("Open stored copy",()=>snapshot(row),"recent-study-copy"),button("Relink file\u2026",()=>browse(row),"recent-study-relink"));
        const removeButton=button("Remove",()=>remove(row.id),"recent-study-remove");removeButton.title="Remove this recent entry only. The Study file on disk is not deleted.";actions.append(removeButton);
        item.append(actions);list.append(item);
      }
      setBusy(busy);
    }
    function mount() {
      if(dialog)return;
      dialog=el("dialog","recent-studies-dialog");dialog.setAttribute("aria-labelledby","recent-studies-title");
      const head=el("header","recent-studies-header"),title=el("h2","","Load Study");title.id="recent-studies-title";
      const dismiss=button("Close",close);dismiss.setAttribute("aria-label","Close recent Studies");head.append(title,dismiss);
      const intro=el("p","recent-studies-intro","Recent Studies are stored in this browser for this WingFEGen address. Clearing browser data removes this list and its stored copies; your disk files remain unchanged.");
      const browseButton=button("Browse for a Study\u2026",()=>browse(),"recent-studies-browse");
      status=el("p","recent-studies-status",warning);status.setAttribute("role","status");status.hidden=!warning;
      list=el("div","recent-studies-list");dialog.append(head,intro,browseButton,status,list);doc.body.appendChild(dialog);
      dialog.addEventListener("cancel",event=>{if(busy)event.preventDefault();});
    }
    async function open() {if(stopped)return;mount();if(!dialog.open)dialog.showModal();status.textContent="Loading recent Studies\u2026";status.hidden=false;await ready;if(stopped)return;status.textContent=warning;status.hidden=!warning;render();}
    function destroy() {stopped=true;close();dialog?.remove();dialog=list=status=null;db?.close();db=null;}
    return {open,close,browse,record,remove,destroy,ready,restoreLatest,list:async()=>{await ready;await queue;return sort(Array.from(entries.values())).map(row=>({id:row.id,name:row.name,updatedAt:row.updatedAt,persisted:row.persisted,diskLinked:row.diskLinked,hasHandle:!!row.handle}));}};
  }
  return {create,DATABASE,STORE,CONTENTS};
});

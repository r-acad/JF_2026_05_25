/* A startup choice reads recent metadata only. No Study opens before a click. */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingStartupStudy=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 function choose({recentStudies,parent=globalThis.document.body,onChoose,message=""}={}){
  const doc=parent.ownerDocument;
  return new Promise((resolve,reject)=>{
   const el=(tag,text)=>{const node=doc.createElement(tag);if(text)node.textContent=text;return node;},dialog=el("dialog"),title=el("h2","Start a Study"),intro=el("p","Choose the model definition to work with."),recent=el("p","Checking recent Studies…"),choices=el("div");
   dialog.className="startup-study-dialog";title.id="startup-study-heading";dialog.setAttribute("aria-labelledby",title.id);choices.className="startup-study-choices";recent.className="startup-study-recent";recent.setAttribute("role","status");
   let chosen=false;
   const pick=choice=>{if(chosen)return;chosen=true;dialog.close();dialog.remove();try{onChoose?.(choice);resolve(choice);}catch(error){reject(error);}};
   for(const[value,label]of[["new","Start new study"],["last","Load last study"],["open","Open existing study"]]){const button=el("button",label);button.type="button";button.dataset.choice=value;button.onclick=()=>pick(value);if(value==="last")button.disabled=true;choices.append(button);}
   dialog.addEventListener("cancel",event=>event.preventDefault());dialog.append(title,intro);if(String(message).trim()){const notice=el("p",String(message));notice.className="startup-study-error";notice.setAttribute("role","alert");dialog.append(notice);}dialog.append(choices,recent);parent.append(dialog);dialog.showModal();choices.firstElementChild.focus();
   Promise.resolve().then(()=>recentStudies?.list?.()||[]).then(rows=>{if(chosen)return;const last=rows?.[0];choices.querySelector('[data-choice="last"]').disabled=!last;recent.textContent=last?"Last Study: "+last.name+" · "+new Date(last.updatedAt).toLocaleString()+". The accessible file or its stored browser copy will be offered.":"No previously saved or loaded Study is available in this browser.";}).catch(error=>{if(chosen)return;recent.textContent="Recent Studies could not be checked: "+(error?.message||String(error))+". Start new or open an existing file.";});
  });
 }
 return{choose};
});

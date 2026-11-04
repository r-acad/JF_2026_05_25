/* A startup choice reads recent metadata only. No Study opens before a click. */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingStartupStudy=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
 "use strict";
 function identificationFields(doc,initial={text:"",visible:false}){
  const group=doc.createElement("fieldset"),legend=doc.createElement("legend"),label=doc.createElement("label"),input=doc.createElement("input"),toggle=doc.createElement("label"),check=doc.createElement("input");
  group.className="startup-study-identification";legend.textContent="New study identification (optional)";label.textContent="Short text";input.type="text";input.maxLength=120;input.autocomplete="off";input.value=initial.text||"";input.placeholder="Name / student ID / CONFIDENTIAL";input.setAttribute("data-study-identification","text");input.title="Saved in the Study. Use a name, assignment identifier or short classification text.";label.append(input);
  check.type="checkbox";check.checked=initial.visible===true;check.setAttribute("data-study-identification","visible");toggle.className="startup-study-watermark-choice";toggle.append(check,doc.createTextNode("Show as a watermark in 2D and 3D views"));toggle.title="The text can be edited or hidden later in Display / Axes & labels.";group.append(legend,label,toggle);
  return{group,input,capture:()=>({text:input.value.trim(),visible:check.checked})};
 }
 function identify({document:doc=globalThis.document,initial}={}){
  const dialog=doc.createElement("dialog"),title=doc.createElement("h2"),fields=identificationFields(doc,initial),actions=doc.createElement("div"),cancel=doc.createElement("button"),create=doc.createElement("button");dialog.className="startup-study-dialog";title.id="new-study-identification-heading";title.textContent="Start new study";dialog.setAttribute("aria-labelledby",title.id);actions.className="startup-study-identification-actions";cancel.type=create.type="button";cancel.textContent="Cancel";create.textContent="Create study";create.className="startup-study-create";actions.append(cancel,create);dialog.append(title,fields.group,actions);doc.body.append(dialog);
  return new Promise(resolve=>{let closed=false;const finish=value=>{if(closed)return;closed=true;dialog.close();dialog.remove();resolve(value);};cancel.onclick=()=>finish(null);create.onclick=()=>finish(fields.capture());dialog.addEventListener("cancel",e=>{e.preventDefault();finish(null);});dialog.showModal();fields.input.focus();});
 }
 function choose({recentStudies,parent=globalThis.document.body,onChoose,message=""}={}){
  const doc=parent.ownerDocument;
  return new Promise((resolve,reject)=>{
   const el=(tag,text)=>{const node=doc.createElement(tag);if(text)node.textContent=text;return node;},dialog=el("dialog"),title=el("h2","Study Options"),intro=el("p","Choose the model definition to work with."),recent=el("p","Checking recent Studies…"),choices=el("div");
   dialog.className="startup-study-dialog";title.id="startup-study-heading";dialog.setAttribute("aria-labelledby",title.id);choices.className="startup-study-choices";recent.className="startup-study-recent";recent.setAttribute("role","status");
   let chosen=false;const identification=identificationFields(doc);
   const pick=choice=>{if(chosen)return;chosen=true;dialog.close();dialog.remove();try{onChoose?.(choice,choice==="new"?identification.capture():null);resolve(choice);}catch(error){reject(error);}};
   for(const[value,label]of[["new","Start new study"],["last","Load last study"],["open","Open existing study"],["reference","Read Nastran file"],["abaqus","Read Abaqus input"],["results","Open JFEM results"]]){const button=el("button",label);button.type="button";button.dataset.choice=value;button.onclick=()=>pick(value);if(value==="last")button.disabled=true;choices.append(button);}
   choices.insertBefore(identification.group,choices.firstElementChild);dialog.addEventListener("cancel",event=>event.preventDefault());dialog.append(title,intro);if(String(message).trim()){const notice=el("p",String(message));notice.className="startup-study-error";notice.setAttribute("role","alert");dialog.append(notice);}dialog.append(choices,recent);parent.append(dialog);dialog.showModal();choices.querySelector("button").focus();
   Promise.resolve().then(()=>recentStudies?.list?.()||[]).then(rows=>{if(chosen)return;const last=rows?.[0];choices.querySelector('[data-choice="last"]').disabled=!last;recent.textContent=last?"Last Study: "+last.name+" · "+new Date(last.updatedAt).toLocaleString()+". The accessible file or its stored browser copy will be offered.":"No previously saved or loaded Study is available in this browser.";}).catch(error=>{if(chosen)return;recent.textContent="Recent Studies could not be checked: "+(error?.message||String(error))+". Start new or open an existing file.";});
  });
 }
 return{choose,identify,identificationFields};
});

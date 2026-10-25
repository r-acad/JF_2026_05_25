/* Review only the local property assignments affected by a changed panel layout. */
(function(root,factory){
  const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingPanelOverrideReview=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';
  function label(key){const m=/^(upper|lower):bay(\d+):stringer(\d+):segment(\d+)$/.exec(key||'');return m?`${m[1]==='upper'?'Upper':'Lower'} / R${m[2]}-R${Number(m[2])+1} / Stringer ${m[3]} / Segment ${m[4]}`:String(key||'Unknown panel');}
  function open(conflict,{document:doc=globalThis.document,isCurrent=()=>true,onApply}={}){
    const el=(tag,text,cls)=>{const n=doc.createElement(tag);if(text!==undefined)n.textContent=text;if(cls)n.className=cls;return n;};
    const dialog=el('dialog',undefined,'study-comments-dialog panel-override-review'),title=el('h2','Review changed panel assignments');title.id='panel-override-review-title';dialog.setAttribute('aria-labelledby',title.id);
    const info=conflict.details||{},affected=conflict.affected_rows||[],canApply=conflict.can_reconcile!==false&&Array.isArray(conflict.compatible_rows);
    dialog.append(title,el('p',conflict.message||conflict.error||'Some local panel properties need review.'));
    if(canApply){
      dialog.append(el('p','A valid geometry edit can move a runout or change the panels bounded by ribs and stringers. Assignments with unchanged physical membership are retained. Only the listed assignments need your decision.'));
      const counts=el('p',`${conflict.compatible_rows.length} compatible override row(s) retained; ${affected.length} affected assignment(s) listed below.`);counts.className='study-comments-intro';dialog.append(counts);
    }else dialog.append(el('p','The saved assignments could not be matched to a verified baseline. Reopen the original Study or undo the layout edit and create its FEM first. Your current assignments have not been removed.'));
    if(info.old_rib_count!==undefined&&info.new_rib_count!==undefined)dialog.append(el('p',`Physical ribs: ${info.old_rib_count} → ${info.new_rib_count}. Stringers: ${info.old_stringer_count} → ${info.new_stringer_count}.`));
    const list=el('div',undefined,'study-comments-history');list.style.maxHeight='45vh';list.style.overflow='auto';
    for(const item of [...affected].sort((a,b)=>String(a.key).localeCompare(String(b.key),undefined,{numeric:true}))){const section=el('section'),heading=el('h3',label(item.key));section.append(heading,el('p',item.reason||'Panel membership changed.'));
      for(const part of item.parts||['skin','stringer'])if(item.row?.[part])section.append(el('pre',part+': '+JSON.stringify(item.row[part],null,2)));
      list.append(section);
    }
    dialog.append(list);
    const error=el('p');error.setAttribute('role','alert');error.hidden=true;dialog.append(error);
    const actions=el('div',undefined,'study-comments-actions'),cancel=el('button','Keep all and return','study-comments-cancel'),apply=el('button','Keep compatible assignments and rebuild','study-comments-save');cancel.type=apply.type='button';actions.append(cancel);
    if(affected.length){const backup=el('button','Download affected assignments');backup.type='button';backup.onclick=()=>{const win=doc.defaultView,url=win.URL.createObjectURL(new win.Blob([JSON.stringify({affected_rows:affected,details:info},null,2)],{type:'application/json'})),a=el('a');a.href=url;a.download='panel-assignments-review.json';doc.body.append(a);a.click();a.remove();win.setTimeout(()=>win.URL.revokeObjectURL(url),1000);};actions.append(backup);}
    if(canApply){dialog.append(el('p','Rebuild removes only the affected skin/stringer assignments listed here; those regions use their shared defaults. Compatible assignments remain. The saved Study file is unchanged until you save it.'));actions.append(apply);}
    dialog.append(actions);doc.body.append(dialog);
    return new Promise((resolve,reject)=>{
      let closed=false;const close=result=>{if(closed)return;closed=true;dialog.close();dialog.remove();resolve(result);};
      cancel.onclick=()=>close(false);dialog.addEventListener('cancel',event=>{event.preventDefault();close(false);});
      apply.onclick=()=>{if(!isCurrent()){error.textContent='The inputs changed after this review was prepared. Keep all and return, then Create FEM again to review the current layout.';error.hidden=false;apply.disabled=true;return;}
        closed=true;dialog.close();dialog.remove();try{resolve(onApply(conflict.compatible_rows));}catch(e){reject(e);}};
      dialog.showModal();cancel.focus();
    });
  }
  return{open,label};
});

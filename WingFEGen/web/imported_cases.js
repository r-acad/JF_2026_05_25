/* Read-only native case control and boundary conditions, synchronized to the viewport. */
(function(root,factory){
  const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingImportedCases=api;
})(globalThis,function(){
  'use strict';
  function selected(data,id){return data?.load_cases?.find(row=>Number(row.id)===Number(id))||data?.load_cases?.[0]||null;}
  function supports(data,id){return selected(data,id)?.spc||data?.spc||null;}
  function create({casesHost,supportsHost,read,selectCase,inspectNode,showSupports,showLoads}){
    const doc=casesHost.ownerDocument,hosts=[casesHost,supportsHost];let previous=null,previousCase=null;
    const make=(tag,text,cls)=>{const el=doc.createElement(tag);if(text!==undefined)el.textContent=text;if(cls)el.className=cls;return el;};
    const fmt=value=>typeof value==='number'?(globalThis.WingNumbers?.format(value,6)||String(value)):value==null?'—':typeof value==='object'?JSON.stringify(value):String(value);
    function button(text,action){const el=make('button',text,'mini');el.type='button';el.onclick=action;return el;}
    function note(host,text){if(text)host.append(make('p',text,'pick-note'));}
    function definition(host,values){const dl=make('dl',undefined,'imported-definition');for(const [key,value]of Object.entries(values||{})){dl.append(make('dt',key),make('dd',value!=null&&typeof value!=='object'?String(value):fmt(value)));}host.append(dl);}
    function table(host,headings,rows,{search=false,empty='None in this case.'}={}){
      if(!rows.length){note(host,empty);return;}
      const wrapper=make('div',undefined,'imported-table-wrapper'),tbl=make('table'),thead=make('thead'),tr=make('tr'),body=make('tbody');
      for(const label of headings)tr.append(make('th',label));thead.append(tr);tbl.append(thead,body);wrapper.append(tbl);
      let pattern='',page=0;const limit=80,controls=make('div',undefined,'imported-table-controls'),status=make('span');
      const back=button('Previous',()=>{page--;render();}),next=button('Next',()=>{page++;render();});
      if(search){const input=make('input');input.type='search';input.placeholder='Filter rows…';input.setAttribute('aria-label','Filter '+headings.join(', '));input.oninput=()=>{pattern=input.value.trim().toLowerCase();page=0;render();};controls.append(input);}
      controls.append(back,status,next);host.append(controls,wrapper);
      function render(){const filtered=pattern?rows.filter(row=>row.some(cell=>String(cell?.label??cell??'').toLowerCase().includes(pattern))):rows;page=Math.max(0,Math.min(page,Math.ceil(filtered.length/limit)-1));body.replaceChildren();
        for(const cells of filtered.slice(page*limit,(page+1)*limit)){const row=make('tr');for(const cell of cells){const td=make('td');if(cell&&typeof cell==='object'&&cell.action)td.append(button(cell.label,cell.action));else td.textContent=fmt(cell);row.append(td);}body.append(row);}
        status.textContent=filtered.length?`${page*limit+1}–${Math.min((page+1)*limit,filtered.length)} of ${filtered.length}`:'No matches';back.disabled=page===0;next.disabled=(page+1)*limit>=filtered.length;
      }render();
    }
    function heading(host,label,context){host.append(make('h2',label));const row=make('label','Load case ','display-control'),picker=make('select');picker.setAttribute('aria-label',label+' load case');
      for(const item of context.data.load_cases||[]){const option=make('option',item.id+' · '+item.label);option.value=item.id;picker.append(option);}picker.value=String(context.caseId);picker.onchange=()=>selectCase(Number(picker.value));row.append(picker);host.append(row);
    }
    function sourceInventory(host,deck){const details=make('details'),summary=make('summary','Source cards and parser coverage');details.append(summary);host.append(details);
      note(details,'The Study and written deck retain all source cards. The inventory distinguishes parsed cards from cards with no native interpretation; keeping a source card does not imply solver support.');
      const unprocessed=new Map((deck.unprocessed_cards||[]).map(row=>[row.name,row]));
      table(details,['Card','Count','Parser status'],Object.entries(deck.card_inventory||{}).sort(([a],[b])=>a.localeCompare(b)).map(([name,count])=>[name,String(count),unprocessed.get(name)?.message||unprocessed.get(name)?.status||'Parsed']),{search:true});
    }
    function refresh(force=false){const context=read(),deck=context.deck;
      if(!force&&previous===context.data&&previousCase===context.caseId&&hosts[0].hidden===!deck)return;
      previous=context.data;previousCase=context.caseId;for(const host of hosts){host.replaceChildren();host.hidden=!deck;}
      if(!deck||!context.data)return;
      const c=selected(context.data,context.caseId);if(!c)return;
      const constraints=supports(context.data,c.id)||{},control=c.case_control||{};
      heading(casesHost,'Imported load cases',context);note(casesHost,'Read-only source definition. Selecting a case updates applied loads and supports in the 3D view. Edit the BDF and read it again to change the analysis.');
      definition(casesHost,{'Solution':'SOL '+deck.solution,'Subcase':c.id,'Label':c.label,...control});
      for(const warning of c.warnings||[])note(casesHost,warning);
      const actions=make('div',undefined,'hud-row');actions.append(button('Show applied loads',showLoads),button('Show supports',showSupports));casesHost.append(actions);
      const cards=make('details'),cardTitle=make('summary','Selected load cards');cards.append(cardTitle);cards.open=true;casesHost.append(cards);
      table(cards,['Card','Set','Count','Scale'],(c.load_cards||[]).map(row=>[row.type,String(row.set_id),String(row.count),row.scale]));
      note(casesHost,c.loads?.note);const forces=c.loads?.force_stations||[],moments=c.loads?.moment_stations||[];
      const vectors=make('details');vectors.append(make('summary','Applied nodal force and moment components'));casesHost.append(vectors);
      note(vectors,'Equivalent applied loads before constraint redistribution, in BASIC axes and the source deck unit system. These are loads, not support reactions.');
      table(vectors,['GRID','Type','X','Y','Z'],[...forces.map(row=>[row,'Force',row.force]),...moments.map(row=>[row,'Moment',row.moment])].map(([row,type,v])=>[{label:String(row.gid),action:()=>inspectNode(row.gid)},type,...(v||[0,0,0])]),{search:true});
      sourceInventory(casesHost,deck);
      heading(supportsHost,'Imported boundary conditions',context);
      definition(supportsHost,{'Selected SPC set':constraints.selected_spc_id??control.SPC??'None','Expanded sets':constraints.expanded_sets||[], 'Supported GRID nodes':constraints.count||0,'Constrained DOFs':constraints.constrained_dofs??'Not reported'});
      note(supportsHost,constraints.note);for(const warning of constraints.warnings||[])note(supportsHost,warning);
      note(supportsHost,'DOFs 1–3 are translations; 4–6 are rotations, in each GRID displacement coordinate system (CD). Colors identify local x/y/z. Values use the source deck units; rotational values are radians. Click a GRID number to inspect it.');
      supportsHost.append(button('Show supports in 3D',showSupports));
      const rows=[];for(const row of constraints.assignments||[]){for(const dof of String(row.components||'')){rows.push([{label:String(row.grid),action:()=>inspectNode(row.grid)},dof,row.values?.[dof]??0,String(row.coordinate_id??0),(row.source_sets||[]).join(', ')||((row.sources||[]).map(s=>s.type).join(', '))]);}}
      table(supportsHost,['GRID','DOF','Value','CD','Source sets'],rows,{search:true,empty:'No SPC constraints are selected in this subcase.'});
    }
    return{refresh,destroy(){for(const host of hosts)host.replaceChildren();}};
  }
  return{selected,supports,create};
});

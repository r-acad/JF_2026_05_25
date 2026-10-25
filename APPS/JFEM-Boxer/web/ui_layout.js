(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingUILayout=api;})(globalThis,function(){
 'use strict';
 // Reparent the canonical controls, preserving IDs, listeners and Study keys.
 // No copied inputs, observers or per-frame layout work are needed.
 function group(doc,parent,id,title,items,{details=false,open=false}={}){
  const nodes=items.filter(Boolean);if(!parent||!nodes.length)return null;
  let box=doc.getElementById(id);
  if(!box){box=doc.createElement(details?'details':'fieldset');box.id=id;box.className=details?'ui-form-disclosure':'ui-form-section';const label=doc.createElement(details?'summary':'legend');label.textContent=title;box.append(label);if(details)box.open=open;parent.append(box);}
  for(const node of nodes)if(node!==box&&!node.contains(box))box.append(node);
  return box;
 }
 function help(doc,parent,id,title,items){const box=group(doc,parent,id,title,items,{details:true});if(box)box.classList.add('ui-form-help');return box;}
 function generated(doc){
  const row=key=>doc.getElementById('row-'+key),host=id=>doc.getElementById(id);
  const mesh=host('group-mesh');
  group(doc,mesh,'mesh-structural-fields','Structural subdivisions',['mesh.elements_between_ribs','mesh.elements_between_stringers','mesh.elements_spar_height','mesh.elements_stringer_height','leading_edge.chord_elements'].map(row));
  group(doc,mesh,'mesh-aero-fields','Aerodynamic loft sampling',[row('mesh.aero_chord_points')]);
  const fuel=host('group-fuel-tank'),density=row('fuel.density');
  if(fuel&&density){const parameters=fuel.querySelector('.drawing-parameters')||fuel;parameters.append(density);const weights=host('group-weights');if(weights&&!Array.from(weights.querySelectorAll('.row')).some(el=>!el.hidden))weights.classList.add('ui-empty-group');}
  const analysis=host('group-analysis');
  group(doc,analysis,'analysis-solution-fields','Solution',[row('output.solution')]);
  group(doc,analysis,'analysis-eigen-fields','Eigenvalue extraction',[row('output.n_modes'),row('output.buckling_max_factor'),host('analysis-eigrl-note')]);
  group(doc,analysis,'analysis-nonlinear-fields','Nonlinear solution',['load_steps','max_iterations','max_cutbacks','displacement_tolerance','residual_tolerance'].map(key=>row('nonlinear.'+key)));
  group(doc,analysis,'analysis-buckling-fields','Buckling output',['output.buckling_deformation_energy','output.buckling_compact'].map(row));
  // Technical file/export settings remain together, below the solve controls.
  const source=host('panel-input');
  const deckFields=group(doc,source,'analysis-deck-fields','Deck export settings',['output.title','output.reference_file','output.include_aero_shells','output.t_aero_shell'].map(row),{details:true});
  if(deckFields)deckFields.dataset.generatedOnly='';
  const solver=host('group-jfem-solver');
  group(doc,solver,'analysis-files-fields','Results files',[row('jfem.output_dir'),row('jfem.output_formats'),row('jfem.repo')],{details:true});
  // Integrated JFEM always uses its enclosing repository. This legacy input
  // remains readable/serializable, but is not a second solver-location choice.
  if(row('jfem.repo'))row('jfem.repo').hidden=!doc.getElementById('p-jfem.repo')?.value.trim();
  if(solver)solver.querySelector('.parameter-heading')?.setAttribute('hidden','');
  const nsm=host('group-non-structural-mass');
  if(nsm){const rows=[...nsm.querySelectorAll('.row')];for(const [id,title,unit]of[['surface','Surface densities','kg/m2'],['linear','Linear densities','kg/m']])group(doc,nsm,'nsm-'+id+'-fields',title,rows.filter(el=>el.querySelector('.unit')?.textContent.replace('²','2').trim()===unit));}
  const constraints=host('group-rbe3-and-supports'),editor=host('support-definitions');
  group(doc,constraints,'constraint-load-transfer','Load-transfer connections',[row('rbe3.enabled'),row('rbe3.ref_xc')]);
  group(doc,constraints,'constraint-definition-fields','Structural constraints',[row('supports.mode'),editor]);
  if(editor)help(doc,editor,'constraint-definition-help','Choosing constraints and reading their symbols',[...editor.querySelectorAll(':scope > p.group-note,:scope > p.pick-note:not(:last-child)')]);
  sync(doc);
 }
 function sync(doc){
  const solution=doc.getElementById('p-output.solution')?.value;
  for(const[id,shown]of[['analysis-eigen-fields',['103','105'].includes(solution)],['analysis-nonlinear-fields',solution==='106'],['analysis-buckling-fields',solution==='105']]){const el=doc.getElementById(id);if(el)el.hidden=!shown;}
  const aeroThickness=doc.getElementById('row-output.t_aero_shell');if(aeroThickness)aeroThickness.hidden=!doc.getElementById('p-output.include_aero_shells')?.checked;
  const panels=doc.getElementById('panel-inspection-options'),toggle=doc.getElementById('show-panels');if(panels)panels.hidden=!toggle||toggle.disabled;
 }
 function cases(doc){
  const host=doc.getElementById('load-cases-editor');if(!host)return;
  const loading=[],aircraft=[],scaling=[],inertia=[];let target=null;
  for(const child of Array.from(host.children)){
   if(child.id.startsWith('case-row-')){const key=child.id.slice(9);target=['match_aircraft_lift','aircraft_mass','maneuver_factor'].includes(key)?aircraft:['fuel_percent','structure_inertia','fuel_accel_x','fuel_accel_y','fuel_accel_z'].includes(key)?inertia:['torque_y','load_factor','follower_forces'].includes(key)?scaling:loading;}
   if(target&&(child.classList.contains('case-field')||child.classList.contains('case-method-note')||child.id==='case-follower-status'||child.id==='case-aircraft-lift-target'||child.classList.contains('flight-conditions')))target.push(child);
  }
  for(const[id,title,items]of[['loading','Applied loading',loading],['aircraft','Aircraft lift target',aircraft],['scaling','Load scale and direction',scaling],['inertia','Fuel and inertia',inertia]]){
   const box=group(doc,host,'case-'+id+'-fields',title,items);if(!box)continue;
   help(doc,box,'case-'+id+'-help','How these settings work',[...box.children].filter(el=>el.classList.contains('case-method-note')));
  }
  const note=doc.getElementById('case-analysis-note');if(note)host.append(note);
 }
 function staticPanels(doc){
  const row=id=>doc.getElementById(id)?.closest('label'),byId=id=>doc.getElementById(id);
  const properties=byId('panel-displayproperties'),explosion=byId('panel-explosion-controls');
  if(properties&&explosion){
   const box=group(doc,properties,'panel-inspection-options','Panel isolation and labels',[row('show-panels'),row('show-panel-ids'),byId('stiffened-panel-note')],{details:true});
   if(box)explosion.before(box);
   help(doc,explosion,'panel-explosion-help','About spread distances',[...explosion.querySelectorAll(':scope > p:not([role])')]);
  }
  const axes=byId('display-axes-labels');
  if(axes){
   group(doc,axes,'display-element-axes','Element axes',[row('show-shell-axes'),row('show-material-axes'),row('show-material-axis-labels'),row('show-bar-axes'),axes.querySelector('.display-axis-key')]);
   const coordinates=group(doc,axes,'display-coordinate-axes','Coordinate systems',[row('show-coordinate-labels'),byId('coordinate-inspection')]);
   const note=axes.querySelector(':scope > p.pick-note');if(note)help(doc,coordinates,'display-coordinate-help','Reading coordinate labels',[note]);
   group(doc,axes,'display-entity-labels','Entity labels',[row('show-node-ids'),row('show-element-ids'),row('show-actuator-stiffness'),row('id-label-size'),byId('id-label-status')]);
   const legend=axes.querySelector(':scope > legend');if(legend)legend.hidden=true;axes.classList.add('ui-section-container');
  }
  const input=byId('panel-input');if(input)input.querySelector('.parameter-heading')?.setAttribute('hidden','');
  // A visible status or warning must never be folded into explanatory help.
  for(const[id,title,selector]of[
   ['panel-displayloads','Reading loads and reactions',':scope > p.pick-note:not([role])'],
   ['panel-vlm-view','About aerodynamic contours',':scope > p.pick-note:not([id]):not([role])'],
   ['panel-fuel-volume','About fuel display',':scope > p.pick-note:not([id]):not([role])']]){
   const parent=byId(id);if(parent)help(doc,parent,id+'-help',title,[...parent.querySelectorAll(selector)]);
  }
  sync(doc);
 }
 return{generated,sync,cases,staticPanels};
});

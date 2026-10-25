(function(root,factory){const common=typeof module==='object'&&module.exports,api=factory(common?require('./spar_view.js'):root.WingSparView,common?require('./aero_display.js'):root.WingAeroDisplay);if(common)module.exports=api;else root.WingMovableSurfaces=api;})(typeof globalThis!=='undefined'?globalThis:this,function(Spar,Aero){
 'use strict';
 const KEY='movable_surfaces.items',MAX_SURFACES=100;
 const KINDS=['aileron','flap','slat','elevator','rudder','tab','other'];
 const STYLES=['translucent','solid','wireframe','metallic'];
 const LEGACY_FIELDS=['name','kind','edge','eta_start','eta_end','hinge_start','hinge_end','deflection','color'];
 const FIELDS=[...LEGACY_FIELDS,'front_spar_start','front_spar_end','hinge_z_start','hinge_z_end'];
 const HELP=[
  'Define each movable surface on the generated lifting-surface loft. Eta is the fraction of semi-span: 0 is the root and 1 is the tip. Start eta must be smaller than End eta. Several adjacent surfaces can share an endpoint; their footprints must not overlap. Add movable surface starts beyond the outermost existing end station on either edge. If the tip has been reached, shorten that surface to make room.',
  'The control front spar defines its loft cut: a trailing-edge surface extends from this spar to x/c = 1; a leading-edge surface extends from x/c = 0 to this spar. Front-spar and hinge coordinates are separate x/c values measured from the local refined leading edge. Each interpolates between its inboard and outboard endpoints. The hinge sets the true rotation axis and can lie ahead of a trailing-edge control front spar. Older Studies initially retain their previous cut and rotation axis at the same position.',
  'The straight 3D hinge axis joins the inboard and outboard hinge points. Each hinge z/t shifts that endpoint along the local airfoil-thickness direction (following section twist) by the specified ratio times the local airfoil thickness at the hinge x/c. Zero is the midpoint of the lower and upper surfaces, +0.5 is the upper surface, -0.5 the lower surface, and -2 is two local thicknesses below the midpoint. The thickness and midpoint include the loft thickness scaling. The hinge line remains straight between these endpoints. The preview rigidly rotates the trimmed upper and lower loft about that axis. Positive deflection is a right-handed rotation from the inboard toward the outboard hinge point: on a horizontal surface, a positive angle lowers the trailing edge and raises the leading edge. Twist or a curved loft can leave a gap along an intermediate cut; this preview does not design seals or hinge fittings.',
  'The translucent plan drawing shows the neutral footprint, with dashed hinge axes, leaving reference images visible. Choose a translucent, solid, wireframe or metallic 3D preview finish; the finish is saved with the Study and changes no structural properties. The colored 3D preview shows the specified deflection in the undeformed geometry. Definitions, colors and angles are saved in the Study and TOML. Add optional shells, ribs and attachments in Structure / Movable surfaces to include a surface in the FE model. Surfaces without enabled structures remain geometry previews. VLM still uses the original common aerodynamic loft.'
 ];
 function normalize(value){
  if(!Array.isArray(value)||value.length>MAX_SURFACES)throw Error('Use a table of at most '+MAX_SURFACES+' movable surfaces.');
  const names=new Set(),rows=value.map((raw,i)=>{
   const r=raw&&typeof raw==='object'&&!Array.isArray(raw)?{...raw,front_spar_start:Object.hasOwn(raw,"front_spar_start")?raw.front_spar_start:raw.hinge_start,front_spar_end:Object.hasOwn(raw,"front_spar_end")?raw.front_spar_end:raw.hinge_end,hinge_z_start:Object.hasOwn(raw,"hinge_z_start")?raw.hinge_z_start:0,hinge_z_end:Object.hasOwn(raw,"hinge_z_end")?raw.hinge_z_end:0}:raw;
   if(!r||typeof r!=='object'||Array.isArray(r)||Object.keys(r).sort().join('|')!==[...FIELDS].sort().join('|'))throw Error('Movable surface '+(i+1)+' has missing or unknown fields.');
   const name=typeof r.name==='string'?r.name.trim():'';
   if(!name||[...name].length>80||/[\x00-\x1f\x7f-\x9f]/.test(name))throw Error('Each surface needs a name of 1 to 80 characters without control characters.');
   if(names.has(name.toLowerCase()))throw Error('Movable surface names must be unique: '+name);names.add(name.toLowerCase());
   if(!KINDS.includes(r.kind))throw Error(name+': choose a surface type.');
   if(!['leading','trailing'].includes(r.edge))throw Error(name+': choose a leading or trailing edge.');
   for(const k of ['eta_start','eta_end','hinge_start','hinge_end','front_spar_start','front_spar_end','hinge_z_start','hinge_z_end','deflection'])if(typeof r[k]!=='number'||!Number.isFinite(r[k]))throw Error(name+': '+k+' must be a finite number.');
   if(!(r.eta_start>=0&&r.eta_end<=1&&r.eta_end-r.eta_start>=1e-6))throw Error(name+': require 0 ≤ Start eta < End eta ≤ 1, separated by at least 0.000001.');
   if(['hinge_start','hinge_end','front_spar_start','front_spar_end'].some(k=>!(r[k]>0&&r[k]<1)))throw Error(name+': hinge and control-spar x/c must be strictly between 0 and 1.');
   if(Math.abs(r.deflection)>90)throw Error(name+': deflection must be between −90 and 90 degrees.');
   if(typeof r.color!=='string'||!/^#[0-9a-f]{6}$/i.test(r.color))throw Error(name+': choose a six-digit hex color.');
   return {...r,name,color:r.color.toLowerCase()};
  });
  const cut=(s,eta)=>s.front_spar_start+(s.front_spar_end-s.front_spar_start)*(eta-s.eta_start)/(s.eta_end-s.eta_start);
  for(let i=0;i<rows.length;i++)for(let j=i+1;j<rows.length;j++){
   const a=rows[i],b=rows[j],lo=Math.max(a.eta_start,b.eta_start),hi=Math.min(a.eta_end,b.eta_end);if(hi<=lo)continue;
   if(a.edge===b.edge)throw Error(a.name+' and '+b.name+' overlap on the same edge.');
   const [front,rear]=a.edge==='leading'?[a,b]:[b,a];
   if([lo,hi].some(eta=>cut(front,eta)>=cut(rear,eta)))throw Error(a.name+' and '+b.name+' have overlapping chordwise footprints.');
  }
  return rows;
 }
 function nextSurface(rows){
  let name='Surface 1',serial=1;while(rows.some(r=>r.name.trim().toLowerCase()===name.toLowerCase()))name='Surface '+(++serial);
  const edge='trailing';let a=.2,b=.7;
  // Append beyond every existing footprint, including those on the other
  // edge. Filling an earlier gap makes a newly added surface hard to find.
  if(rows.length){a=Math.max(...rows.map(r=>r.eta_end));if(1-a<1e-6)return null;b=Math.min(1,Number((a+.2).toPrecision(12)));}
  return{name,kind:edge==='leading'?'slat':'flap',edge,eta_start:a,eta_end:b,hinge_start:edge==='leading'?.18:.7,hinge_end:edge==='leading'?.18:.7,front_spar_start:edge==='leading'?.15:.75,front_spar_end:edge==='leading'?.15:.75,hinge_z_start:0,hinge_z_end:0,deflection:0,color:['#29b6d1','#f5a742','#b388ff','#ee72ac'][rows.length%4]};
 }
 function createDisplay({BABYLON:B,scene,parent,data,visible=true,style='translucent'}){
  if(!STYLES.includes(style))throw Error('Unknown movable-surface preview finish.');
  const meshes=[],vector=p=>new B.Vector3(p[1],p[2],p[0]);let environment=null;
  if(style==='metallic'&&(data?.surfaces||[]).length){
   const faces=Aero.studioFaces();environment=new B.RawCubeTexture(scene,faces,64,B.Engine.TEXTUREFORMAT_RGBA,B.Engine.TEXTURETYPE_UNSIGNED_BYTE,true,false,B.Texture.TRILINEAR_SAMPLINGMODE);environment.name='movable-local-studio';environment.coordinatesMode=B.Texture.CUBIC_MODE;environment.gammaSpace=false;
   // These pixels already exist on the CPU. Derive diffuse lighting directly,
   // without a deferred GPU readback that could finish after a rapid style
   // switch or Study reload has disposed the preview's cube texture.
   environment.sphericalPolynomial=B.CubeMapToSphericalPolynomialTools.ConvertCubeMapToSphericalPolynomial({size:64,right:faces[0],left:faces[1],up:faces[2],down:faces[3],front:faces[4],back:faces[5],format:B.Engine.TEXTUREFORMAT_RGBA,type:B.Engine.TEXTURETYPE_UNSIGNED_BYTE,gammaSpace:false});
  }
  for(const s of data?.surfaces||[]){
   const positions=[];for(let i=0;i<s.xyz.length;i+=3)positions.push(s.xyz[i+1],s.xyz[i+2],s.xyz[i]);
   const mesh=new B.Mesh('movable-surface-'+s.definition.name,scene),vd=new B.VertexData();vd.positions=positions;vd.indices=s.triangles;vd.normals=[];B.VertexData.ComputeNormals(positions,vd.indices,vd.normals);vd.applyToMesh(mesh);
   const color=B.Color3.FromHexString(s.definition.color),mat=style==='metallic'?new B.PBRMaterial(mesh.name+'-material',scene):new B.StandardMaterial(mesh.name+'-material',scene);
   if(style==='metallic'){mat.albedoColor=color;mat.metallic=1;mat.roughness=.23;mat.reflectionTexture=environment;mat.environmentIntensity=1.5;mat.directIntensity=.9;}
   else{mat.diffuseColor=color.scale(.96);mat.emissiveColor=color.scale(.045);mat.specularColor=new B.Color3(.065,.065,.065);mat.specularPower=48;}
   mat.maxSimultaneousLights=6;mat.backFaceCulling=false;mat.twoSidedLighting=true;mat.alpha=style==='translucent'?.3:1;mat.transparencyMode=style==='translucent'?B.Material.MATERIAL_ALPHABLEND:B.Material.MATERIAL_OPAQUE;mat.wireframe=style==='wireframe';
   // WebGPU line-list pipelines reject nonzero polygon depth bias. Only the
   // filled preview needs an offset from the coincident aerodynamic loft.
   mat.zOffset=mat.wireframe?0:-2;mat.zOffsetUnits=0;mat.separateCullingPass=false;mat.disableDepthWrite=false;mesh.material=mat;
   const hinge=B.MeshBuilder.CreateLines(mesh.name+'-hinge',{points:s.hinge.map(vector)},scene);hinge.color=new B.Color3(.14,.18,.24);hinge.renderingGroupId=1;
   meshes.push(mesh,hinge);
  }
  for(const mesh of meshes){mesh.parent=parent;mesh.isPickable=false;mesh.metadata={wingViewHelper:true,movableSurfacePreview:true};mesh.setEnabled(visible);}
  return{meshes,style,setVisible(v){for(const m of meshes)m.setEnabled(v);},dispose(){for(const m of meshes){const mat=m.material;m.dispose(false,false);mat?.dispose(false,false);}environment?.dispose();}};
 }
 function install(host,{onEdit,onHelp,readValues,requestPreview,onPreview,isLocked=()=>false}={}){
  const doc=host.ownerDocument,stored=doc.getElementById('p-'+KEY);if(!stored)return null;
  const make=(tag,cls,text)=>{const e=doc.createElement(tag);if(cls)e.className=cls;if(text!==undefined)e.textContent=text;return e;};
  const intro=make('p','group-note','Define leading- and trailing-edge movable surfaces. Add their optional load-carrying shells and hinge attachments in Structure / Movable surfaces. VLM retains the original common loft.');
  const help=make('button','mini','?');help.type='button';help.title='Span, hinge interpolation, deflection sign, preview and analysis scope';help.setAttribute('aria-label','Help: movable surfaces');help.onclick=()=>onHelp?.({title:'Movable surfaces',paragraphs:HELP});intro.append(' ',help);
  const preview=make('div','movable-preview'),toolbar=make('div','movable-actions'),showLabel=make('label','layer'),show=make('input'),svg=doc.createElementNS('http://www.w3.org/2000/svg','svg');show.type='checkbox';show.checked=show.defaultChecked=true;show.id='show-movable-preview';show.dataset.parameterLockExempt='true';showLabel.append(show,make('span','','Preview in 3D · undeformed geometry'));toolbar.append(showLabel);svg.id='movable-plan-view';svg.setAttribute('viewBox','0 0 900 430');svg.setAttribute('aria-label','Movable surfaces neutral plan view');svg.setAttribute('role','img');preview.append(toolbar,svg);
  const finishLabel=make('label','movable-finish','3D preview finish'),finish=make('select');finish.id='movable-preview-style';finish.dataset.parameterLockExempt='true';finish.setAttribute('aria-label','Movable surface preview finish');finish.title='Translucent shows the structure behind the surface. Solid is opaque, Wireframe shows mesh edges, and Metallic uses the local studio reflections. This changes the geometry preview only.';for(const value of STYLES){const option=make('option','',value[0].toUpperCase()+value.slice(1));option.value=value;option.defaultSelected=value==='translucent';finish.append(option);}finishLabel.append(finish);toolbar.append(finishLabel);
  const status=make('p','pick-note'),error=make('p','loft-error'),list=make('div','movable-list'),actions=make('div','movable-actions'),add=make('button','mini primary','+ Add movable surface'),editLabel=make('label','movable-editor-picker','Edit movable surface'),editSelect=make('select');editSelect.id='movable-surface-edit';editSelect.dataset.parameterLockExempt='true';editSelect.setAttribute('aria-label','Movable surface geometry to edit');editLabel.append(editSelect);add.type='button';add.id='movable-add';error.setAttribute('role','alert');error.hidden=true;status.id='movable-status';status.setAttribute('role','status');actions.append(add);host.append(intro,preview,status,error,editLabel,list,actions);
  const viewport=globalThis.WingSVGViewport?.install(svg,{key:'movable-surfaces-plan',host:preview,toolbarHost:toolbar,exportName:'movable-surfaces.svg'});
  let rows=[],timer=null,revision=0,destroyed=false,cache=null,parseError='',requestKey=null,selectedRow=null;
  function draft(){return rows.map(({inputs})=>Object.fromEntries(FIELDS.map(k=>[k,['eta_start','eta_end','hinge_start','hinge_end','front_spar_start','front_spar_end','hinge_z_start','hinge_z_end','deflection'].includes(k)?inputs[k].value.trim()===''?null:Number(inputs[k].value):inputs[k].value])));}
  function chooseRow(row){selectedRow=rows.includes(row)?row:rows[0]||null;for(const r of rows)r.box.hidden=r!==selectedRow;editSelect.replaceChildren();for(const [i,r]of rows.entries()){const o=make('option','',r.inputs.name.value||'Unnamed surface '+(i+1));o.value=String(i);editSelect.append(o);}editSelect.value=selectedRow?String(rows.indexOf(selectedRow)):'';editSelect.disabled=!rows.length;editLabel.hidden=!rows.length;}
  editSelect.onchange=()=>chooseRow(rows[Number(editSelect.value)]);
  function validate(){let message=parseError;try{if(!message)normalize(draft());}catch(e){message=e.message;}host.dataset.invalidMessage=message;error.textContent=message;error.hidden=!message;return message;}
  function draw(data,context=null){
   // The same untwisted plan is used by every structural editor. Backend
   // loft coordinates include camber/twist and belong to the 3D preview.
   const outline=context?.planform?.right||data?.outline;
   const surfaces=context?context.movables.map(s=>({outline:s.outline,hinge_curve:s.hinge,front_spar_curve:s.front_spar,definition:s})):data?.surfaces||[];
   svg.replaceChildren();if(!outline?.length){viewport?.refresh();return;}const pts=outline,xs=pts.map(p=>p[1]),ys=pts.map(p=>p[0]),xmin=Math.min(...xs),ymin=Math.min(...ys),w=Math.max(...xs)-xmin,h=Math.max(...ys)-ymin,scale=Math.min(800/(w||1),325/(h||1));
   const map=p=>[50+(p[1]-xmin)*scale,45+(p[0]-ymin)*scale];
   const node=(tag,attrs,text)=>{const e=doc.createElementNS(svg.namespaceURI,tag);for(const[k,v]of Object.entries(attrs))e.setAttribute(k,v);if(text!==undefined)e.textContent=text;svg.append(e);return e;};
   node('polygon',{points:pts.map(p=>map(p).join(',')).join(' '),fill:'#e5edf4','fill-opacity':.14,stroke:'#637b90','stroke-width':1.7});
   for(const s of surfaces)node('polygon',{'data-movable-footprint':s.definition.name,points:s.outline.map(p=>map(p).join(',')).join(' '),fill:s.definition.color,'fill-opacity':.2,stroke:s.definition.color,'stroke-width':2});
   if(context)svg.insertAdjacentHTML('beforeend',Spar.contextDrawing({...context,movables:[]},{transform:{map}}));
   for(const s of surfaces){if(s.front_spar_curve)node('polyline',{'data-movable-front-spar':s.definition.name,points:s.front_spar_curve.map(p=>map(p).join(',')).join(' '),fill:'none',stroke:s.definition.color,'stroke-width':2.5});node('polyline',{points:s.hinge_curve.map(p=>map(p).join(',')).join(' '),fill:'none',stroke:'#263e50','stroke-width':2,'stroke-dasharray':'7 4'});const mid=map(s.hinge_curve[Math.floor(s.hinge_curve.length/2)]);node('text',{x:mid[0],y:mid[1]-9,fill:'#132e44','font-size':15,'text-anchor':'middle','paint-order':'stroke',stroke:'#fff','stroke-width':4,'stroke-linejoin':'round'},s.definition.name);}
   node('text',{x:50,y:410,fill:'#304a60','font-size':14},'Neutral footprints · dashed hinge cuts · span → · x aft ↓');
   viewport?.setMetric({origin:{x:50-xmin*scale,y:45-ymin*scale},x:{x:scale,y:0},y:{x:0,y:scale},unit:'m',horizontalLabel:'Δy',verticalLabel:'Δx',gridSpacing:1});viewport?.refresh();
  }
  function controls(){chooseRow(selectedRow);const locked=isLocked();for(const row of rows){for(const input of Object.values(row.inputs))input.disabled=locked;row.remove.disabled=locked;}const noRoom=!validate()&&nextSurface(normalize(draft()))===null;add.disabled=locked||rows.length>=MAX_SURFACES||noRoom;add.title=noRoom?'No outboard span remains. Shorten the outermost surface before adding another.':'Add a surface outboard of every existing surface; earlier gaps are left unchanged.';}
  function clearPreview(){cache=null;requestKey=null;draw(null);onPreview?.(null,false);}
  async function updatePreview(){
   clearTimeout(timer);const id=++revision;if(destroyed)return;
   if(validate()){clearPreview();status.textContent='Correct the definition to preview the movable surfaces.';return;}
   let params;try{params={...readValues(),[KEY]:normalize(draft())};}catch(e){clearPreview();status.textContent=e.message;return;}
   const key=JSON.stringify(params);if(key===requestKey&&cache){onPreview?.(cache,show.checked);return;}
   let context=null;try{context=Spar?.contextGeometry(params);}catch(_){/* An unrelated incomplete structural draft must not block the loft preview. */}
   if(!rows.length){clearPreview();draw(null,context);status.textContent='No movable surfaces defined. Add a surface to set its span, hinge and deflection.';return;}
   // Clear old geometry immediately: an invalid or pending edit must never show
   // a previous surface as if it represented the current definition.
   clearPreview();status.textContent='Preparing movable-surface geometry…';
   try{const data=await requestPreview(params);if(destroyed||id!==revision)return;cache=data;requestKey=key;draw(data,context);onPreview?.(data,show.checked);status.textContent=rows.length+' movable surface'+(rows.length===1?'':'s')+' · plan shows neutral footprints; 3D shows preview deflection. Geometry preview only; enabled structures are controlled in Structure → Movable surfaces.';}
   catch(e){if(destroyed||id!==revision)return;clearPreview();status.textContent='Geometry preview failed: '+e.message;}
  }
  function refresh(){if(destroyed)return;controls();clearTimeout(timer);++revision;timer=setTimeout(updatePreview,250);}
  function sync(){parseError='';stored.value=JSON.stringify(draft());validate();clearPreview();refresh();onEdit?.(KEY);}
  function addRow(value){
   const box=make('fieldset','movable-surface'),legend=make('legend','',value.name),grid=make('div','movable-grid'),inputs={};
   const specs=[['name','Name','text','Unique surface name, saved with this definition.'],['kind','Type',KINDS,'Flap attachment lugs normally lie in the line of flight; other types are perpendicular to the true hinge. Hinge z/t at or above -0.5 keeps the attachment on the control front spar. Only a hinge below the lower airfoil contour uses a hinge-normal underside fitting, extending to the front spar. Joint restraint is defined separately in Structure.'],['edge','Edge',['trailing','leading'],'Trailing: control front spar to trailing edge. Leading: leading edge to control spar.'],['eta_start','Start eta','number','Inboard fraction of semi-span: 0 = root, 1 = tip.'],['eta_end','End eta','number','Outboard fraction of semi-span; greater than Start eta.'],['front_spar_start','Inboard control front spar x/c','number','Control box closure and aerodynamic footprint cut at Start eta; separate from the rotation axis.'],['front_spar_end','Outboard control front spar x/c','number','Control front spar position at End eta; interpolates linearly from the inboard value.'],['hinge_start','Inboard hinge x/c','number','True hinge rotation axis at Start eta, measured from the refined local leading edge and divided by local chord.'],['hinge_end','Outboard hinge x/c','number','True hinge axis at End eta. The 3D axis is the straight line between the endpoints, including their hinge z/t offsets.'],['hinge_z_start','Inboard hinge z/t','number','At Start eta and hinge x/c: shift in the local thickness direction, following section twist, above the airfoil midpoint as a ratio of local thickness. 0 = midpoint; +0.5 = upper surface; -0.5 = lower surface; -2 = two thicknesses below the midpoint.'],['hinge_z_end','Outboard hinge z/t','number','At End eta and hinge x/c: the same local-thickness ratio as the inboard offset. The 3D hinge is straight between these endpoints. Negative values are allowed.'],['deflection','Preview deflection (deg)','number',HELP[2]],['color','Color','color','Color of the neutral footprint and deflected 3D preview.']];
   for(const[k,label,kind,title]of specs){const wrap=make('label','',label),input=make(Array.isArray(kind)?'select':'input');if(Array.isArray(kind))for(const v of kind){const o=make('option','',v[0].toUpperCase()+v.slice(1));o.value=v;input.append(o);}else input.type=kind;input.value=value[k]??'';input.title=title;input.setAttribute('aria-label',label);input.dataset.movableField=k;if(kind==='number'){input.step=k==='deflection'?'1':'0.1';if(!k.startsWith('hinge_z_')){input.min=k==='deflection'?'-90':'0';input.max=k==='deflection'?'90':'1';}}if(k==='name')input.maxLength=80;wrap.append(input);grid.append(wrap);inputs[k]=input;input.addEventListener('input',()=>{if(!isLocked()){legend.textContent=inputs.name.value||'Unnamed surface';sync();}});}
   const remove=make('button','mini ghost','Remove surface');remove.type='button';remove.onclick=()=>{if(isLocked())return;rows=rows.filter(r=>r.box!==box);box.remove();sync();};box.append(legend,grid,remove);list.append(box);rows.push({box,inputs,remove});
  }
  add.onclick=()=>{if(isLocked()||validate())return;const next=nextSurface(normalize(draft()));if(!next){error.textContent='No outboard span remains. Shorten the outermost surface before adding another.';error.hidden=false;return;}addRow(next);chooseRow(rows.at(-1));sync();rows.at(-1).inputs.name.focus();};
  show.onchange=()=>onPreview?.(cache,show.checked);
  finish.onchange=()=>onPreview?.(cache,show.checked);
  const lockChange=()=>controls();host.addEventListener('parameterlockchange',lockChange);
  try{const initial=normalize(JSON.parse(stored.value||'[]'));for(const row of initial)addRow(row);}catch(e){parseError='Cannot read saved movable surfaces: '+e.message;}
  validate();refresh();
  return{readDrafts:()=>({[KEY]:draft()}),assertValidDraft(){const message=validate();if(message)throw Error(message);},refresh,redraw3D(){onPreview?.(cache,show.checked);},destroy(){destroyed=true;++revision;clearTimeout(timer);viewport?.destroy();host.removeEventListener('parameterlockchange',lockChange);onPreview?.(null,false);}};
 }
 return{KEY,KINDS,STYLES,FIELDS,MAX_SURFACES,HELP,normalize,nextSurface,createDisplay,install};
});

'use strict';
const assert=require('node:assert/strict');
const data=require('../web/reserve_factor_table_data.js');
let passed=0;
function test(name,run){run();passed++;console.log('PASS '+name);}
const row=(pid,value=1.5,extra={})=>({pid,label:'P'+pid,names:[],propertyType:'PSHELL',materialIds:[1],reserveFactor:value,reserveFactorReason:'',complete:true,coverage:{recovered:8,total:8},allowableStress:300e6,envelopeStress:300e6/value,envelopeCaseLabel:'Case 2 · SOL101',status:'complete',...extra});
const report=rows=>({rows,includedCases:[{label:'Case 2 · SOL101'}],excludedCases:[],missingCases:[],method:'maximum',percentile:95,stressUnit:'MPa',stressFactor:1e-6,note:'Property-region envelope.',complete:true});
const panel=(id,bay=1,extra={})=>({id,key:'upper:bay'+bay+':stringer1:segment1',skin:'upper',rib_bay:bay,stringer:1,segment:1,shell_pid:5000000+id,stringer_pid:7000000+id,...extra});

test('Physical panel metadata maps skins and beam stringers separately in a rib-bay cell',()=>{
 const model=data.build({generated:true,report:report([row(5000001,.8),row(7000001,1.4)]),panels:[panel(1)],group:'upper',view:'grid'});
 assert.equal(model.view,'grid');assert.deepEqual(model.matrix.rows.map(r=>r.label),['U1']);assert.equal(model.matrix.columns[0].label,'R1–R2');
 const items=model.matrix.cells.get('stringer:1:1');assert.equal(items.length,2);assert.deepEqual(items.map(i=>i.value),[.8,1.4]);assert.deepEqual(items.map(i=>i.cellLabel),['P1 · Skin','P1 · Stringer']);
});
test('Shell stringer blade and attached flange keep their own actual PIDs',()=>{
 const p=panel(7,3,{stringer_pid:19000007,stringer_web_pid:19000007,stringer_flange_pid:20000007});
 const model=data.build({generated:true,report:report([row(5000007),row(19000007,.7),row(20000007,2.8)]),panels:[p],group:'upper'});
 const items=model.matrix.cells.get('stringer:1:3');assert.equal(items.length,3);assert.equal(items[1].cellLabel,'P7 · Stringer blade');assert.equal(items[2].cellLabel,'P7 · Attached flange');
 assert.deepEqual(items.map(i=>i.pid),[5000007,19000007,20000007]);
});
test('Blade-only panels create no phantom flange result',()=>{
 const locations=data.panelLocations(panel(2,1,{stringer_pid:19000002,stringer_web_pid:19000002,stringer_flange_pid:null}));assert.deepEqual(locations.map(i=>i.part),['skin','stringer_web']);
});
test('Ordinary generated element-group names never override explicit panel ownership',()=>{
 const model=data.build({generated:true,report:report([row(5000001,.8),row(7000001,1.5)]),panels:[panel(1)],componentGroups:[{pid:5000001,name:'UPPER_SKIN_P5000001'},{pid:7000001,name:'STRINGERS_P7000001'}],group:'upper'});
 assert.equal(model.matrix.shared.length,0);assert.ok(model.matrix.cells.get('stringer:1:1').every(item=>!item.sharedReference&&item.value!==null));
});
test('All generated local component families map with correct row order and rib labels',()=>{
 const parts=['front_upper_cap','front_lower_cap','rear_upper_cap','rear_lower_cap','leading_upper_skin','leading_lower_skin','leading_rib','rib_web','rib_stiffener','front_web','rear_web'];
 const groups=parts.map((part,i)=>({pid:(i+8)*1000000+2,name:data.PARTS[part][2][0]+'_P'+((i+8)*1000000+2)}));
 for(const [i,part]of parts.entries()){
  const model=data.build({generated:true,report:report(groups.map(g=>row(g.pid))),componentGroups:groups,group:data.PARTS[part][0]});
  const item=model.rows.find(r=>r.pid===groups[i].pid);assert.equal(item.locations[0].part,part);
  assert.equal(item.locations[0].columnLabel,['rib_web','rib_stiffener','leading_rib'].includes(part)?'R2':'R2–R3');
 }
 const caps=data.build({generated:true,report:report(groups.map(g=>row(g.pid))),componentGroups:groups,group:'sparcaps'});
 assert.deepEqual(caps.matrix.rows.map(r=>r.key),parts.slice(0,4));
});
test('Legacy local families and kink groups retain their physical location without duplication',()=>{
 const groups=[{pid:3000002,name:'FRONT_SPAR_WEB_P3000002'},{pid:3000002,name:'FRONT_SPAR_WEB_P3000002_KINKS'},{pid:1000003,name:'RIB_WEBS_P1000003'}];
 const model=data.build({generated:true,report:report(groups.map(g=>row(g.pid))),componentGroups:groups,group:'sparwebs'});
 assert.equal(model.rows.length,1);assert.equal(model.rows[0].shared,false);assert.equal(model.matrix.cells.get('front_web:2').length,1);
});
test('Imported IDs and suggestive names never manufacture generated component locations',()=>{
 const model=data.build({generated:false,report:report([row(17000001)]),componentGroups:[{pid:17000001,name:'FRONT_SPAR_WEB_P17000001'}],panels:[panel(1)],group:'sparwebs',view:'grid'});
 assert.equal(model.view,'flat');assert.equal(model.group,'all');assert.deepEqual(model.groups,[{id:'all',label:'All properties'}]);assert.equal(model.rows[0].locations.length,0);
});
test('Unverified group names do not decode arbitrary property families in generated models',()=>{
 const model=data.build({generated:true,report:report([row(17000001)]),componentGroups:[{pid:17000001,name:'MOVABLE_SURFACE_CUSTOM'}],group:'sparwebs'});
 assert.equal(model.group,'all');assert.equal(model.rows[0].locations.length,0);
});
test('A shared property is shown once and is never copied into invented local reserve factors',()=>{
 const model=data.build({generated:true,report:report([row(17,.6)]),componentGroups:[{pid:17,component_key:'front_web:1'},{pid:17,component_key:'front_web:2'}],group:'sparwebs'});
 assert.equal(model.rows.length,1);assert.equal(model.matrix.shared.length,1);assert.equal(model.matrix.shared[0].value,.6);assert.equal(model.scale.count,1);
 for(const cell of model.matrix.cells.values()){assert.equal(cell[0].sharedReference,true);assert.equal(cell[0].value,null);assert.equal(cell[0].status,'shared');}
 assert.equal(data.table(model).rows.length,1);
});
test('Legacy shared base properties remain available in the correct structural group without invented bays',()=>{
 const model=data.build({generated:true,report:report([row(3,.7)]),componentGroups:[{pid:3,name:'FRONT_SPAR_WEB'},{pid:3,name:'REAR_SPAR_WEB'}],group:'sparwebs'});
 assert.equal(model.group,'sparwebs');assert.equal(model.rows.length,1);assert.equal(model.matrix.shared.length,1);assert.equal(model.matrix.shared[0].value,.7);
 assert.equal(model.matrix.columns.length,0);assert.equal(model.matrix.cells.size,0);assert.equal(model.scale.count,1);assert.match(data.csv(model),/Whole property region/);
});
test('Missing properties, missing recovery and laminate criteria remain visibly unassessed',()=>{
 const rows=[row(5000001,.8,{complete:false,coverage:{recovered:7,total:8},reserveFactorReason:'Missing element recovery.'}),row(7000001,2,{propertyType:'PCOMP',reserveFactor:null,reserveFactorReason:'Laminate criteria required.'})];
 const model=data.build({generated:true,report:report(rows),panels:[panel(1),panel(2,2)],group:'upper'});
 assert.equal(model.rows.length,4);assert.equal(model.scale.count,0);assert.ok(model.rows.every(r=>r.value===null));
 assert.match(model.rows.find(r=>r.pid===5000002).reason,/No stress-report result/);assert.match(model.rows.find(r=>r.pid===7000001).reason,/Laminate/);
});
test('A stale supplied reserve factor cannot bypass coverage or assessment guards',()=>{
 for(const r of [row(1,3,{complete:false}),row(1,3,{coverage:{recovered:7,total:8}}),row(1,3,{reserveFactorReason:'Missing cases.'}),row(1,Infinity),row(1,-2),row(1,null)])assert.equal(data.reserveValue(r).value,null);
 assert.equal(data.reserveValue(row(1,0)).status,'below');assert.equal(data.reserveValue(row(1,1)).status,'limit');
});
test('Panel segment ordering preserves every real panel and excludes invalid metadata',()=>{
 const p1=panel(1,2,{segment:2,key:'upper:bay2:stringer1:segment2'}),p2=panel(2,2),bad=panel(3,0);
 const model=data.build({generated:true,report:report([]),panels:[p1,p2,bad],group:'upper'});
 assert.equal(model.rows.length,4);assert.deepEqual(model.matrix.cells.get('stringer:1:2').map(i=>i.location.segment),[1,1,2,2]);
});
test('Threshold colors are red below one, blue above one and neutral exactly at one',()=>{
 const model=data.build({report:report([row(1,.4),row(2,1),row(3,3)])}),bounds=model.scale;
 assert.deepEqual(bounds,{min:0,max:2,actualMin:.4,actualMax:3,count:3,threshold:1,unit:'dimensionless'});
 const rgb=v=>data.valueColor(v,bounds).match(/\d+/g).map(Number);
 assert.ok(rgb(.4)[0]>rgb(.4)[2]);assert.ok(rgb(3)[2]>rgb(3)[0]);assert.deepEqual(rgb(1),[245,246,248]);
 assert.ok(rgb(.999999)[0]-rgb(.999999)[2]>60);assert.ok(rgb(1.000001)[2]-rgb(1.000001)[0]>60);
 for(const palette of ['signed','coolwarm']){
  const below=data.valueColor(.999,bounds,palette).match(/\d+/g).map(Number),above=data.valueColor(1.001,bounds,palette).match(/\d+/g).map(Number);
  assert.ok(below[0]-below[2]>60,palette+' remains visibly red below one');assert.ok(above[2]-above[0]>60,palette+' remains visibly blue above one');
  assert.equal(data.valueColor(1,bounds,palette),'rgb(245, 246, 248)');assert.equal(data.colorStops(bounds,palette).find(s=>s.value===1).position,.5);
 }
 const stops=data.colorStops(bounds);assert.equal(stops.find(s=>s.value===1).position,.5);assert.equal(stops[0].value,0);assert.equal(stops.at(-1).value,2);
});
test('One-sided and constant RF scales retain fixed zero-to-two colors and separate actual bounds',()=>{
 for(const values of [[2,4],[.2,.7],[1,1],[2,2]]){
  const scale=data.build({report:report(values.map((v,i)=>row(i+1,v)))}).scale;
  assert.equal(scale.min,0);assert.equal(scale.max,2);assert.equal(scale.actualMin,Math.min(...values));assert.equal(scale.actualMax,Math.max(...values));assert.ok(data.colorStops(scale).length);
  assert.equal(data.valueColor(null,scale),null);
 }
 assert.deepEqual(data.colorStops({min:null,max:null}),[]);
});
test('Group and text filters bound the scale by relevant displayed properties only',()=>{
 const groups=[{pid:17000001,name:'FRONT_SPAR_WEB_P17000001'},{pid:18000001,name:'REAR_SPAR_WEB_P18000001'}];
 const model=data.build({generated:true,report:report([row(17000001,.8),row(18000001,2),row(88,1000)]),componentGroups:groups,group:'sparwebs',filter:'front spar'});
 assert.equal(model.rows.length,1);assert.equal(model.scale.max,2);assert.equal(model.scale.min,0);assert.equal(model.scale.actualMin,.8);assert.equal(model.scale.actualMax,.8);
});
test('CSV, Markdown and HTML exports keep coverage, units, cases and five-digit numeric formatting',()=>{
 const r=row(17,1.23456789);r.allowableStress=300e6;r.envelopeStress=243e6;
 const model=data.build({report:{...report([r]),method:'trimmed_mean',percentile:95,missingCases:[{label:'Case 3',reason:'Not run'}]}});
 const t=data.table(model);assert.equal(t.rows[0][5],'1.2346');assert.equal(t.rows[0][6],'300');assert.equal(t.rows[0][7],'243');
 for(const text of [data.csv(model),data.markdown(model),data.html(model)]){assert.match(text,/Case 3/);assert.match(text,/95th percentile/);assert.match(text,/dimensionless/);assert.match(text,/1\.2346/);assert.match(text,/8 \/ 8/);}
});
test('Imported source stress units are preserved without assuming SI',()=>{
 const model=data.build({report:{...report([row(12,2,{allowableStress:400,envelopeStress:200})]),stressUnit:'source stress units',stressFactor:1}});
 assert.equal(data.table(model).rows[0][6],'400');assert.match(data.csv(model),/source stress units/);
});
test('HTML export keeps readable text on dark red/blue and light neutral reserve-factor cells',()=>{
 const model=data.build({report:report([row(1,.4),row(2,1),row(3,3),row(4,null)])}),html=data.html(model);
 assert.match(html,/<td style="background:rgb\([\d, ]+\);color:#[a-f\d]+">0\.4<\/td>/);
 assert.match(html,/<td style="background:rgb\(42, 105, 181\);color:#963e00"><span style="background:#fff1df;color:#963e00;[^"]+">3<\/span><\/td>/);
 assert.match(html,/<td style="background:rgb\(245, 246, 248\);color:#102235">1<\/td>/);
 assert.ok(!/<td style="[^"]+">Unavailable<\/td>/.test(html));
});
test('Exported user text is escaped for HTML, Markdown and CSV formulas',()=>{
 const model=data.build({report:report([row(1,2,{label:'=BAD|<script>alert(1)</script>'})])});
 assert.ok(!data.html(model).includes('<script>'));assert.match(data.html(model),/&lt;script&gt;/);assert.match(data.markdown(model),/\\\|/);assert.match(data.csv(model),/"'=BAD/);
});
test('Detached snapshots strip mesh connectivity and remain independent of source edits',()=>{
 const raw={generated:true,caseScopeLabel:'Case 2',error:'Model changed',report:report([row(17,2)]),panels:[{...panel(1),shell_eids:[1,2,3]}],componentGroups:[{pid:17,name:'FRONT_SPAR_WEB',eids:[4,5],conn:[1,2,3]}]};
 const snapshot=data.compact(raw);raw.report.rows[0].reserveFactor=.1;raw.panels[0].shell_pid=99;
 assert.equal(snapshot.report.rows[0].reserveFactor,2);assert.equal(snapshot.panels[0].shell_pid,5000001);assert.ok(!('shell_eids' in snapshot.panels[0]));assert.ok(!('conn' in snapshot.componentGroups[0]));
 assert.equal(snapshot.caseScopeLabel,'Case 2');assert.equal(snapshot.error,'Model changed');
});
test('A missing report returns an empty honest flat table',()=>{
 const snapshot=data.compact({report:null,caseScopeLabel:'All eligible cases'});assert.equal(snapshot.report,null);const model=data.build(snapshot);
 assert.equal(model.view,'flat');assert.deepEqual(model.rows,[]);assert.equal(model.scale.count,0);assert.equal(model.scale.min,null);
 assert.deepEqual(model.groups,[{id:'all',label:'All properties'}]);assert.match(data.csv(model),/All eligible cases/);
 const invalid=data.compact({report:null,requestedFailureMode:'minimum_rf',error:'Invalid percentile',generated:true,panels:[panel(1)],componentGroups:[{pid:3000001,name:'FRONT_SPAR_WEB_P3000001'}]});assert.equal(invalid.requestedFailureMode,'minimum_rf');const cleared=data.build(invalid);assert.deepEqual(cleared.rows,[]);assert.equal(cleared.scale.count,0);assert.equal(cleared.error,'Invalid percentile');
});
test('RF colors saturate at two while high numbers retain dark-orange readable text in every palette',()=>{
 const bounds=data.scale([{pid:1,value:.7},{pid:2,value:99}]);
 for(const [palette]of data.PALETTES){assert.equal(data.valueColor(2,bounds,palette),data.valueColor(99,bounds,palette));const ink=data.valueInk(99,bounds,palette);assert.equal(ink.color,'#963e00');assert.equal(ink.backing,'#fff1df');assert.equal(data.colorStops(bounds,palette)[0].value,0);assert.equal(data.colorStops(bounds,palette).at(-1).value,2);}
 const linear=x=>x<=.04045?x/12.92:((x+.055)/1.055)**2.4,luma=hex=>{const rgb=hex.match(/[a-f\d]{2}/g).map(x=>linear(parseInt(x,16)/255));return rgb[0]*.2126+rgb[1]*.7152+rgb[2]*.0722;};assert((luma('fff1df')+.05)/(luma('963e00')+.05)>=4.5);
});
test('Euler columns sharing a property remain separate physical rows and do not populate skin RF cells',()=>{
 const make=(bay,rf)=>row(7000001,rf,{rowKey:'euler:upper:bay'+bay,panelKey:'upper:bay'+bay,locations:[{group:'upper',rowKey:'stringer:1',rowLabel:'U1',index:bay,columnLabel:'R'+bay+'-R'+(bay+1),key:'upper:bay'+bay,part:'stringer_column',stringer:1}],euler:{criticalLoad:12000,compressionDemand:6000,length:bay,endFactor:1,weakestEI:1200,noCompression:rf===99}});
 const model=data.build({report:{...report([make(1,.8),make(2,99)]),failureMode:'euler_column',forceUnit:'N',lengthUnit:'m'},generated:true,panels:[panel(1),panel(2,2)],group:'upper'});
 assert.equal(model.rows.length,2);assert.equal(model.scale.count,2);assert.equal(model.matrix.shared.length,0);assert.equal(model.matrix.cells.get('stringer:1:1')[0].value,.8);assert.equal(model.matrix.cells.get('stringer:1:2')[0].value,99);assert.equal(model.matrix.cells.get('stringer:1:1').length,1);assert.match(model.matrix.cells.get('stringer:1:2')[0].reason,/No compression/);
 const exported=data.table(model);assert.match(exported.headers[6],/Critical load \(N\)/);assert.equal(exported.rows[1][5],'99');assert.equal(exported.rows[1][11],'2');assert.match(data.csv(model),/Euler column buckling/);
});
test('Blade regions retain physical ownership even when two bays share a beam property',()=>{
 const make=(bay,rf)=>row(7000001,rf,{rowKey:'blade:upper:bay'+bay,panelKey:'upper:bay'+bay,locations:[{group:'upper',rowKey:'stringer:1',rowLabel:'U1',index:bay,columnLabel:'R'+bay+'-R'+(bay+1),key:'upper:bay'+bay,part:'stringer_blade',stringer:1}],blade:{criticalStress:120e6,compressionDemand:60e6,averageStress:-60e6,clearHeight:.03,thickness:.002,coefficient:.425,sourceCount:4,noCompression:rf===99}});
 const model=data.build({report:{...report([make(1,2),make(2,99)]),failureMode:'stringer_blade'},generated:true,panels:[panel(1),panel(2,2)],group:'upper'});
 assert.equal(model.rows.length,2);assert.equal(model.matrix.shared.length,0);assert.equal(model.matrix.cells.get('stringer:1:1').length,1);assert.equal(model.matrix.cells.get('stringer:1:2').length,1);assert.equal(model.scale.count,2);assert.match(model.rows[1].reason,/No average axial compression/);assert.match(model.rows[1].reason,/individual bars can still be compressive/);
 const exported=data.table(model);assert.match(exported.headers[6],/Critical buckling stress \(MPa\)/);assert.equal(exported.rows[0][6],'120');assert.equal(exported.rows[0][7],'60');assert.equal(exported.rows[0][11],'-60');assert.equal(exported.rows[0][12],'30');assert.equal(exported.rows[0][13],'2');assert.equal(exported.rows[0][14],'0.425');assert.equal(exported.rows[0][15],'4');
 for(const text of [data.csv(model),data.markdown(model),data.html(model)]){assert.match(text,/Stringer blade instability/);assert.match(text,/equal-weight arithmetic mean/);assert.match(text,/MPa/);assert.match(text,/Web thickness/);assert.match(text,/Source bars/);}
});
test('Unavailable blade recovery never becomes a colored RF99 and imported IDs do not imply ownership',()=>{
 const r=row(7000001,99,{rowKey:'blade:test',blade:{noCompression:true},complete:false,coverage:{recovered:3,total:4},reserveFactorReason:'One signed axial bar stress is unavailable.',locations:[{group:'upper',rowKey:'stringer:1',index:1}]});
 const model=data.build({report:{...report([r]),failureMode:'stringer_blade'},generated:false,panels:[panel(1)],group:'upper'});
 assert.equal(model.rows[0].value,null);assert.equal(model.scale.count,0);assert.equal(model.rows[0].locations.length,0);assert.equal(model.view,'flat');assert.equal(model.groups[0].label,'All stringer blades');assert.match(model.rows[0].reason,/unavailable/);
});
test('Skin buckling uses actual support strips with multiple properties rather than stringer half-skin ownership',()=>{
 const labels=['Front spar-S1','S1-S2','S2-S3','S3-Rear spar'],make=(strip,bay,rf)=>row(5000001,rf,{rowKey:'skin:upper:'+bay+':'+strip,label:labels[strip-1],propertyIds:[5000001,5000002],locations:[{group:'upper',rowKey:'skin_strip:'+strip,rowLabel:labels[strip-1],stripIndex:strip,index:bay,columnLabel:'R'+bay+'-R'+(bay+1),key:'upper:'+bay+':'+strip,part:'skin_panel'}],skinBuckling:{averageStressX:-30e6,averageStressY:5e6,averageShear:-8e6,length:.8,width:.12,fixityCoefficient:1.3,sourceCount:12,basisOrder:12,convergenceError:.0004,noDestabilizingLoad:false}});
 const rows=[make(4,2,2.5),make(2,1,.9),make(1,1,1.2),make(3,1,1.4),make(4,1,2.5)],model=data.build({report:{...report(rows),failureMode:'skin_buckling'},generated:true,panels:[panel(1)],group:'upper'});
 assert.equal(model.matrix.shared.length,0);assert.equal(model.rows.length,5);assert.deepEqual(model.matrix.rows.map(r=>r.label),labels);assert.equal(model.matrix.cells.get('skin_strip:4:1').length,1);assert.equal(model.matrix.cells.get('skin_strip:4:2').length,1);assert.equal(model.matrix.cells.has('stringer:1:1'),false);assert.equal(model.scale.count,5);
 const filtered=data.build({report:{...report(rows),failureMode:'skin_buckling'},generated:true,filter:'5000002'});assert.equal(filtered.rows.length,5,'Filter must include every actual property in the physical skin compartment.');
 const t=data.table(model);assert.equal(t.headers[0],'Skin panel');assert.equal(t.rows[0][6],'-30');assert.equal(t.rows[0][7],'5');assert.equal(t.rows[0][8],'-8');assert.equal(t.rows[0][12],'0.8');assert.equal(t.rows[0][13],'0.12');assert.equal(t.rows[0][14],'1.3');assert.equal(t.rows[0][18],'5000001; 5000002');
 for(const text of[data.csv(model),data.markdown(model),data.html(model)]){assert.match(text,/Skin panel buckling/);assert.match(text,/Average sigma x \(MPa\)/);assert.match(text,/Average tau xy \(MPa\)/);assert.match(text,/Convergence error/);assert.match(text,/5000002/);}
 assert.match(data.html(model),/<td style="background:rgb\(42, 105, 181\);color:#963e00"><span[^>]+>2\.5<\/span><\/td>/);
});
test('Skin RF99 describes an averaged-state sentinel and incomplete plate assessment remains uncolored',()=>{
 const r=row(5000001,99,{rowKey:'skin:one',skinBuckling:{noDestabilizingLoad:true}}),good=data.build({report:{...report([r]),failureMode:'skin_buckling'}});
 assert.equal(good.rows[0].value,99);assert.match(good.rows[0].reason,/No destabilizing averaged membrane state/);assert.match(good.rows[0].reason,/local element stresses/);assert.equal(good.groups[0].label,'All skin panels');
 for(const reason of['Missing signed membrane recovery.','Plate Ritz basis did not converge.','Panel boundary is not quadrilateral.']){const bad=data.build({report:{...report([{...r,complete:false,reserveFactorReason:reason}]),failureMode:'skin_buckling'}});assert.equal(bad.rows[0].value,null);assert.equal(bad.scale.count,0);assert.equal(bad.rows[0].reason,reason);}
});
test('Minimum-gauge yellow requires complete known floors and strictly RF above one in every palette',()=>{
 const make=(rf,extra={})=>row(5000001,rf,{minimumGauge:{known:true,atMinimum:true},...extra}),bounds=data.scale([{pid:5000001,value:.8},{pid:6000001,value:99}]);
 for(const[palette]of data.PALETTES){for(const rf of[1.001,2,8,99]){const r=make(rf,{combined:{sentinel:rf===99}});assert(data.atMinimumGauge(r));assert.equal(data.valueColor(rf,bounds,palette,r),data.MINIMUM_GAUGE_COLOR);}
  for(const r of[make(.999),make(1),make(2,{minimumGauge:{known:false,atMinimum:true}}),make(2,{minimumGauge:{known:true,atMinimum:false}}),make(2,{complete:false}),make(2,{coverage:{recovered:1,total:2}})]){assert(!data.atMinimumGauge(r));assert.equal(data.valueColor(r.reserveFactor,bounds,palette,r),data.valueColor(r.reserveFactor,bounds,palette));}}
 const model=data.build({report:report([make(3)])});assert.match(data.html(model),/background:rgb\(255, 222, 89\)/);assert.match(data.csv(model),/All relevant dimensions at minimum/);assert.equal(data.valueInk(3,bounds,'signed',make(3)).color,'#963e00');
});
test('Combined minima preserve shared property ownership and governing physical scope in every presentation',()=>{
 const r=row(5000001,1.3,{minimumGauge:{known:true,atMinimum:true},combined:{governingMode:'euler_column',governingModeLabel:'Euler column buckling',governingCase:'Case 4',governingScope:'Upper stringer 1 between ribs1-2, including tributary skin',knownMinimum:1.3,complete:true,sentinel:false},envelopeCaseLabel:'Case 4'});
 const snapshot={report:{...report([r]),failureMode:'minimum_rf'},generated:true,panels:[panel(1),{...panel(2,2),shell_pid:5000001}],group:'upper'};
 for(const[presentation]of data.PRESENTATIONS){const m=data.build({...snapshot,presentation});assert.equal(m.rows.length,3);assert.equal(m.rows.find(x=>x.pid===5000001).shared,true);assert.equal(m.matrix.shared.length,1);assert(m.matrix.cells.get('stringer:1:1').some(x=>x.sharedReference&&x.value===null));const t=data.table(m);assert.equal(t.headers[5],'Minimum reserve factor');const selected=t.rows.find(x=>x[0]===r.label);assert.equal(selected[5],'1.3');assert.equal(selected[6],'Case 4');assert.equal(selected[7],'Euler column buckling');assert.match(selected[8],/tributary skin/);assert.equal(m.presentation,presentation);for(const text of[data.csv(m),data.markdown(m),data.html(m)])assert.match(text,/Governing physical scope/);}
 assert.equal(data.presentationValue(r,'critical_case'),'Case 4');assert.equal(data.presentationValue(r,'failure_mode'),'Euler column buckling');assert.equal(data.presentationValue(r,'reserve_factor'),'1.3');
});
test('An incomplete combined minimum stays unassessed even when the known candidate is favorable and at minimum gauge',()=>{
 const r=row(17,2,{complete:false,reserveFactorReason:'An applicable skin-panel check is missing.',coverage:{recovered:1,total:2},minimumGauge:{known:true,atMinimum:true},combined:{knownMinimum:2,complete:false}}),m=data.build({report:{...report([r]),failureMode:'minimum_rf'},presentation:'failure_mode'});
 assert.equal(m.rows[0].value,null);assert.equal(m.scale.count,0);assert(!data.atMinimumGauge(r));assert(!data.html(m).includes('background:rgb(255, 222, 89)'));assert.match(data.csv(m),/missing/);assert.equal(data.table(m).rows[0][11],'2');
});
test('Component web panels retain physical compartments and spatial-field semantics in grids and exports',()=>{
 for(const [mode,group,part,label]of[['spar_web_buckling','sparwebs','front_web','Front spar'],['rib_web_buckling','ribwebs','rib_web','Main-box web']]){
  const make=(segment,rf)=>row(3000001,rf,{rowKey:mode+':'+segment,label:label+' compartment '+segment,propertyIds:[3000001,3000002],componentBuckling:{kind:part,method:'plate',scope:label+' compartment '+segment,note:'Spatial membrane force recovery.'},locations:[{group,rowKey:part,rowLabel:label,index:1,columnLabel:group==='ribwebs'?'R1':'R1–R2',key:mode+':'+segment,part,segment}],skinBuckling:{averageStressX:-30e6,averageStressY:5e6,averageShear:-8e6,length:.8,width:.12,fixityCoefficient:1.3,sourceCount:12,basisOrder:12,convergenceError:.0004,noDestabilizingLoad:rf===99}});
  const rows=[make(1,1.2),make(2,99)],model=data.build({report:{...report(rows),failureMode:mode},generated:true,group});
  assert.equal(model.rows.length,2);assert.equal(model.matrix.shared.length,0);assert.equal(model.matrix.cells.get(part+':1').length,2);assert.equal(model.scale.count,2);assert.equal(model.matrix.ribs,group==='ribwebs');assert.match(model.rows[1].reason,/spatial membrane field/);assert.match(model.note,/spatial/);assert.match(model.note,/Displayed stresses are area averages/);
  const t=data.table(model);assert.equal(t.headers[0],data.modeInfo(mode).entity);assert.equal(t.rows[0][6],'-30');assert.equal(t.rows[0][7],'5');assert.equal(t.rows[0][8],'-8');assert.equal(t.rows[0][12],'0.8');assert.equal(t.rows[0][13],'0.12');
  for(const text of[data.csv(model),data.markdown(model),data.html(model)]){assert(text.includes(data.FAILURE_MODES[mode]));assert.match(text,/spatial signed membrane-force field/);assert.match(text,/MPa/);}
  const imported=data.build({report:{...report(rows),failureMode:mode},generated:false,group});assert.equal(imported.view,'flat');assert(imported.rows.every(r=>r.locations.length===0));
 }
});
test('Cap and rib-stiffener columns expose loads, geometry and exact component locations',()=>{
 for(const [mode,group,part]of[['spar_cap_buckling','sparcaps','front_upper_cap'],['rib_stiffener_buckling','ribstiffeners','rib_stiffener']]){
  const r=row(8000001,2,{rowKey:mode+':physical',label:'Actual physical member',componentBuckling:{kind:part,method:'column',scope:'Member between restraints'},locations:[{group,rowKey:part,rowLabel:'Member A',index:2,columnLabel:group==='sparcaps'?'R2–R3':'R2',key:mode,part}],euler:{criticalLoad:12000,compressionDemand:6000,length:.6,endFactor:1.5,weakestEI:1200}});
  const m=data.build({report:{...report([r]),failureMode:mode,forceUnit:'N',lengthUnit:'m'},generated:true,group});assert.equal(m.view,'grid');assert.equal(m.rows.length,1);assert.equal(m.matrix.cells.get(part+':2')[0].value,2);const t=data.table(m);assert.match(t.headers[6],/Critical load \(N\)/);assert.equal(t.rows[0][6],'12000');assert.equal(t.rows[0][7],'6000');assert.equal(t.rows[0][11],'0.6');assert.equal(t.rows[0][12],'1.5');assert.match(m.note,/isolated-member/);assert.match(m.note,/does not include adjacent skin or web/);
  for(const presentation of['critical_case','failure_mode'])assert(data.table(data.build({...m,report:m.report,generated:true,presentation})).rows[0].includes(data.presentationValue(r,presentation,mode)));
 }
});
test('Rib-stiffener free-web assessment uses blade quantities without Euler end-fixity credit',()=>{
 const r=row(2000002,1.5,{rowKey:'ribblade:2:1',componentBuckling:{kind:'rib_stiffener',method:'blade'},locations:[{group:'ribstiffeners',rowKey:'stiffener:1',rowLabel:'Stiffener1',index:2,columnLabel:'R2',key:'2:1',part:'rib_stiffener'}],blade:{criticalStress:120e6,compressionDemand:80e6,averageStress:-80e6,clearHeight:.03,thickness:.002,coefficient:.425,sourceCount:4}}),m=data.build({report:{...report([r]),failureMode:'rib_stiffener_blade'},generated:true,group:'ribstiffeners'});
 assert.equal(m.view,'grid');assert.equal(m.rows.length,1);assert.equal(m.groups[0].label,'All rib stiffener blades');const t=data.table(m);assert.equal(t.rows[0][6],'120');assert.equal(t.rows[0][7],'80');assert.equal(t.rows[0][12],'30');assert.equal(t.rows[0][13],'2');assert.match(m.note,/no Euler end-fixity credit/);assert.equal(data.presentationValue(r,'failure_mode','rib_stiffener_blade'),'Rib-stiffener blade instability');
});
test('Incomplete component checks cannot become a colored or minimum-gauge RF99',()=>{
 for(const mode of['spar_web_buckling','rib_web_buckling','spar_cap_buckling','rib_stiffener_buckling','rib_stiffener_blade']){
  const r=row(3000001,99,{rowKey:mode,complete:false,coverage:{recovered:1,total:2},reserveFactorReason:'A physical member recovery is unavailable.',minimumGauge:{known:true,atMinimum:true}}),m=data.build({report:{...report([r]),failureMode:mode},generated:true});assert.equal(m.rows[0].value,null);assert.equal(m.scale.count,0);assert(!data.atMinimumGauge(r));assert(!data.html(m).includes('background:rgb(255, 222, 89)'));
 }
});
test('Certified non-governing cases retain lower bounds without inventing a resolved case RF',()=>{
 const c={label:'Weak compression',reserveFactor:null,converged:false,lowerBound:14.5,certifiedNonGoverning:true,boundReason:'Conservative bending bound exceeds the converged envelope.'},r=row(3000001,2,{componentBuckling:{kind:'spar_web'},caseResults:[c,{...c,label:'Uncertified',certifiedNonGoverning:false},{...c,label:'Unproven',certifiedNonGoverning:undefined}]});
 const notes=data.caseCertificateNotes(r);assert.equal(notes.length,1);assert.match(notes[0],/RF ≥ 14.5; certified non-governing; case eigenvalue unresolved/);assert.equal(c.reserveFactor,null);const m=data.build({report:{...report([r]),failureMode:'spar_web_buckling'}});assert.equal(m.rows[0].value,2);for(const text of[data.csv(m),data.markdown(m),data.html(m)]){assert.match(text,/Certified non-governing cases/);assert.match(text,/case eigenvalue unresolved/);}
 const combined={...r,caseResults:[],combined:{assessments:[{modeLabel:'Spar web buckling',scope:'Front spar R1–R2',certifiedCases:[c]}]}},summary=data.build({report:{...report([combined]),failureMode:'minimum_rf'}});assert.match(data.csv(summary),/Front spar R1–R2.*Weak compression/);assert.equal(data.caseCertificateNotes(combined).length,1);
});
test('Conservative stress recovery remains disclosed in direct and combined row tooltips and detached exports',()=>{
 const recovery={method:'thin_walled_t_section_envelope',description:'Conservative thin-walled T-section equivalent-stress envelope: maximum total axial+bending normal stress at both ends and all polygon vertices, combined with bounded VQ/I transverse shear and free-warping Saint-Venant torsion. Maxima may occur at different points.'};
 for(const combined of[false,true]){
  const r=row(7000123,combined?.51677:2.0419686,combined?{combined:{assessments:[{failureMode:'von_mises',recoveryMethods:[recovery],caseResults:[{recoveryMethods:[recovery]}]}]}}:{recoveryMethods:[recovery],caseResults:[{recoveryMethods:[recovery]}]});
  const model=data.build(data.compact({report:{...report([r]),failureMode:combined?'minimum_rf':'von_mises'}}));
  assert.deepEqual(data.recoveryMethods(r),[recovery]);assert.deepEqual(data.recoveryMethodNotes(r),[recovery.description]);assert.equal(model.rows[0].value,r.reserveFactor);assert.equal(model.rows[0].reason.split(recovery.description).length,2);
  for(const output of[data.csv(model),data.markdown(model),data.html(model)]){assert.match(output,/Conservative thin-walled T-section equivalent-stress envelope/);assert.match(output,/Maxima may occur at different points/);}
 }
 assert.deepEqual(data.recoveryMethodNotes({}),[]);assert.deepEqual(data.recoveryMethodNotes({recoveryMethods:[{method:'documented_recovery'}]}),['documented_recovery']);
});
console.log(passed+' reserve factor table data tests passed.');

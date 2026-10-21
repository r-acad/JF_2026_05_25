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
console.log(passed+' reserve factor table data tests passed.');

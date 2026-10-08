/* Portable offline smoke checks: Node.js builtins and the bundled web assets only. */
'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto');
const app=path.resolve(__dirname,'..'),web=path.join(app,'web'),checks=[];
function check(name,run){run();checks.push(name);console.log('PASS '+name);}
function files(directory){return fs.readdirSync(directory,{withFileTypes:true}).flatMap(entry=>entry.isDirectory()?files(path.join(directory,entry.name)):[path.join(directory,entry.name)]);}
const assets=files(web),scripts=assets.filter(file=>file.endsWith('.js')),own=assets.filter(file=>!file.startsWith(path.join(web,'vendor')+path.sep));
function asset(from,url){assert(!/^(?:https?:)?\/\//i.test(url),'Runtime asset must be local: '+url);const clean=url.split(/[?#]/)[0];if(!clean||/^(?:data:|blob:|#)/.test(clean))return;const file=path.resolve(path.dirname(from),clean);assert(file.startsWith(web+path.sep),'Asset escapes web directory: '+url);assert(fs.statSync(file).isFile(),'Missing asset: '+url);}
check('All four application/detached HTML pages resolve local scripts and styles',()=>{
 const pages=assets.filter(file=>file.endsWith('.html'));assert.deepEqual(pages.map(file=>path.basename(file)).sort(),['index.html','panel_table.html','plan_view.html','sensitivity_table.html']);
 for(const file of pages){const text=fs.readFileSync(file,'utf8');for(const match of text.matchAll(/<(?:script|link)\b[^>]*\b(?:src|href)=["']([^"']+)["']/g))asset(file,match[1]);}
 for(const file of own.filter(file=>file.endsWith('.css')))for(const match of fs.readFileSync(file,'utf8').matchAll(/url\(\s*["']?([^\s"')]+)/g))asset(file,match[1]);
 for(const name of ['decode-worker.js','plan_view.html','panel_table.html','sensitivity_table.html'])assert(fs.existsSync(path.join(web,name)));
 asset(path.join(web,'decode-worker.js'),'vendor/msgpack.min.js');
});
check('Every bundled JavaScript asset parses without a frontend build tool',()=>{
 for(const file of scripts)new vm.Script(fs.readFileSync(file,'utf8'),{filename:path.relative(app,file)});
});
check('Application runtime assets contain no development-workspace dependencies',()=>{
 const patterns=[/\b[A-Za-z]:[\\/]Users[\\/]/i,/\b[A-Za-z]:[\\/]RAUL[\\/]/i,/02_PROJECT_DEVELOPMENT/,/RUN_OUTPUTS[\\/]/,/node_modules[\\/]/];
 for(const file of own.filter(file=>/\.(?:js|css|html)$/.test(file))){const text=fs.readFileSync(file,'utf8');for(const pattern of patterns)assert(!pattern.test(text),path.relative(app,file)+' contains '+pattern);}
});
check('Pinned vendor files, licenses and upstream notices are complete and unchanged',()=>{
 const provenance=JSON.parse(fs.readFileSync(path.join(web,'vendor/provenance.json'),'utf8'));assert.equal(provenance.dependencies.length,3);
 for(const row of provenance.dependencies){const bytes=fs.readFileSync(path.join(web,'vendor',row.filename));assert.equal(bytes.length,row.local_bytes);assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),row.upstream_sha256);assert.equal(row.exact_match,true);}
 for(const name of ['babylon.LICENSE.md','babylon.NOTICE.md','babylonjs-loaders.LICENSE.md','msgpack.LICENSE'])assert(fs.readFileSync(path.join(web,'vendor',name),'utf8').trim().length>20);
 assert(fs.existsSync(path.join(app,'THIRD_PARTY_NOTICES.md')));
 const B=require(path.join(web,'vendor/babylon.js'));assert.equal(B.Engine.Version,'9.27.1');
 const sandbox={BABYLON:B,console,setTimeout,clearTimeout,TextDecoder,TextEncoder};try{vm.runInNewContext(fs.readFileSync(path.join(web,'vendor/babylonjs.loaders.min.js'),'utf8'),sandbox,{displayErrors:false,timeout:5000});}catch(error){throw Error('Bundled loaders could not initialize: '+error.message);}assert.equal(typeof B.STLFileLoader,'function');assert.equal(typeof B.OBJFileLoader,'function');assert.equal(typeof B.GLTFFileLoader,'function');
});
check('Bundled MessagePack preserves representative payload data without npm modules',()=>{
 const M=require(path.join(web,'vendor/msgpack.min.js')),payload={xyz:new Uint8Array([0,1,127,255]),loads:[{force:[12.5,-4,0],moment:[0,2,0]}],label:'Wing \u0394',enabled:true,nullable:null};
 assert.deepEqual(M.decode(M.encode(payload)),payload);
 const replies=[],worker={MessagePack:M,Uint8Array,ArrayBuffer,Set,self:{postMessage:message=>replies.push(message)},importScripts:resource=>assert.equal(resource,'vendor/msgpack.min.js')};vm.runInNewContext(fs.readFileSync(path.join(web,'decode-worker.js'),'utf8'),worker);worker.self.onmessage({data:M.encode(payload)});assert.deepEqual(replies[0].data,payload);
});
check('Planform presentations and physical rib-bay exclusions roundtrip',()=>{
 const P=require(path.join(web,'planform_inputs.js')),G=require(path.join(web,'leading_edge_gaps.js'));
 const params={'planform.area':24,'planform.aspect_ratio':6,'planform.taper_ratio':.5},d=P.dimensions(params);assert(d.valid);assert.equal(d.span,12);assert.equal(d.root,8/3);assert.equal(d.tip,4/3);const back=P.parameters(d);assert(back.valid);assert.deepEqual(back.canonical,params);assert.equal(P.parameters({root:2,tip:3,span:12}).valid,false);
 assert.deepEqual(G.parse('2,4-6,2'),[2,4,5,6]);assert.throws(()=>G.parse('0'));
});
check('Detached panel edits preserve SI dimensions, inheritance and validation',()=>{
 const P=require(path.join(web,'panel_table_data.js')),key='upper:bay1:stringer1:segment1',snapshot={layout_token:'portable-fixture',parameters:{'properties.t_skin_upper':.002,'properties.stringer_flange_width':.03,'properties.stringer_height':.04,'properties.stringer_flange_thickness':.002,'properties.stringer_web_thickness':.002,'properties.panels':[]},panels:[{key,id:1,skin:'upper',rib_bay:1,stringer:1,segment:1}]};
 snapshot.parameters['properties.panels']=P.update(snapshot,'stringers',key,'height','45');assert.equal(snapshot.parameters['properties.panels'][0].stringer.height,.045);assert.throws(()=>P.update(snapshot,'stringers',key,'flange_thickness','50'),/smaller/);assert.deepEqual(P.update(snapshot,'stringers',key,'height',''),[]);assert.equal(P.matrix(snapshot,'upper').cells.get('1:1')[0].id,1);
});
check('Sensitivity tables keep recorded derivatives and unavailable values distinct',()=>{
 const S=require(path.join(web,'sensitivity_table_data.js')),row={id:'properties.panels#lower:bay2:stringer3:segment1#skin#thickness',panel_key:'lower:bay2:stringer3:segment1',pids:[6000004],field_key:'shell.thickness',field_label:'Shell thickness',value:.002,derivative:-2,derivative_unit:'m / m',unit:'m',status:'ok'},result={case_id:1,baseline:{value:.02,unit:'m'},objective:{type:'displacement',node_id:1,component:'z'},rows:[row]};
 assert.equal(S.panel(row).id,4);assert.equal(S.value(result,row).value,-2);assert.equal(S.value(result,row,'normalized').value,-.2);assert.equal(S.value(result,{...row,status:'failed'}).value,null);assert.equal(S.value({...result,baseline:{value:0}},row,'normalized').value,null);assert(S.csv({result}).includes(row.id));assert.equal(S.matrix({result,compatibility:{topology_match:false},panels:[]},'lower',S.family(row).key).cells.get('3:2')[0].id,4);
});
console.log(JSON.stringify({passed:true,groups:checks.length,javascript_assets:scripts.length,html_pages:4,checks},null,2));

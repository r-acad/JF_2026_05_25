'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const Binary=require('../../jfem_binary.js'),Disk=require('../web/disk_results.js');
// Independent writer for the documented binary layout. Deliberately sparse
// native IDs expose accidental assumptions about contiguous IDs or PID order.
function fixture({version=4,eigen=false,preload=false,nonfinite=false}={}){
 const chunks=[],u=x=>{const b=Buffer.alloc(4);b.writeUInt32LE(x);chunks.push(b);},i=x=>{const b=Buffer.alloc(4);b.writeInt32LE(x);chunks.push(b);},f=x=>{const b=Buffer.alloc(4);b.writeFloatLE(x);chunks.push(b);},mark=s=>chunks.push(Buffer.from(s));
 if(preload)version=5;mark('JFEM');u(version);for(const n of[4,1,0,1,1,2])u(n);if(version>=3)for(const n of[0,1,1])u(n);if(version>=4)for(const n of[0,0,0])u(n);
 for(const [nid,x,y,z]of[[3,0,0,0],[10,2,0,0],[100,2,1,0],[1000,0,1,0]]){i(nid);f(x);f(y);f(z);}
 for(const n of[51,800,3,10,100,1000])i(n);if(version>=2)f(.01);
 for(const [eid,pid,ga,gb,area]of[[52,900,3,100,.02],[53,901,10,1000,.03]]){for(const n of[eid,pid,ga,gb])i(n);if(version>=2)f(area);}
 if(version>=3){for(const n of[61,3,123,1,10,62,100,123,2,3,1000])i(n);}
 for(let s=0;s<2;s++){u(s?700:7);for(let n=0;n<4;n++)for(let d=0;d<6;d++)f(nonfinite&&n===1&&d===0?NaN:(s+1)*.01*(n+1)*(d+1));for(const n of[11,12,13,14,15,16,99])f(n+s);for(const n of[21,22,23,24,25,26,199])f(n+s);for(const n of[31,32])f(n+s);if(version>=3){u(1);i(3);u(63);u(1);i(100);for(const n of[0,0,-30])f(n);u(1);i(10);for(const n of[5,0,0])f(n);}}
 if(eigen){mark('EVAL');u(2);for(const n of[4,9]){const b=Buffer.alloc(8);b.writeDoubleLE(n);chunks.push(b);}}
 if(preload){mark('STAT');for(let j=0;j<24;j++)f(j*.001);for(const n of[123,456,789])f(n);}
 return Buffer.concat(chunks);
}
function run(){let checks=0;const check=(ok,message)=>{assert(ok,message);checks++;};
 for(const version of[1,2,3,4]){const raw=Binary.parse(fixture({version})),p=Disk.prepare(raw,{signature:'test',name:'static.jfem'});check(p.mesh.nodes.count===4,'mesh count v'+version);check(p.results.load_cases.length===2,'cases retained');check(p.results.load_cases[1].id===700,'native subcase');check(new Int32Array(p.mesh.groups[0].conn.buffer)[3]===3,'native IDs mapped');check(new Float32Array(p.results.load_cases[0].contours[0].values.buffer)[0]===99,'shell von Mises occupies slot 6');check(p.results.contours.find(c=>c.name==='Bar axial force').max===21,'bar force distinct from stress');check(p.results.contours.find(c=>c.name==='Rod axial force').max===31,'rod force');check(!p.results.reactions.available,'missing reactions explicit');check(p.mesh.coordinate_systems.systems.length===0,'no invented material/coordinate data');if(version>=3){check(p.mesh.load_cases[0].spc.assignments[0].components==='123456','SPC bit mask');check(p.mesh.imported_connections.length===2,'RBE2/RBE3 topology');check(p.mesh.loads.stations.find(s=>s.gid===100).force[2]===-30,'force retained');}}
 const eig=Binary.parse(fixture({eigen:true}));assert.throws(()=>Disk.prepare(eig),/Select whether/);checks++;
 const modal=Disk.prepare(eig,{kind:'frequency'});check(modal.results.modes.length===2,'mode count');check(modal.results.modes[0].freq_hz===4,'SOL103 EVAL stores frequencies directly in Hz');check(!modal.results.modes[0].load_factor,'modal data not buckling data');check(modal.results.modes[0].energy_contours.every(c=>!c.name.includes('stress')),'mode energy never labeled stress');check(Math.abs(modal.results.modes[0].eigenvalue-64*Math.PI*Math.PI)<1e-12,'angular eigenvalue derived from stored frequency');
 // A binary exported from a PCOMP model retains only the PID and total shell
 // thickness. It is indistinguishable from a PSHELL source: never invent a
 // property-card type or laminate definition to support the geometric view.
 const archived=modal.mesh.groups,shell=archived.find(g=>g.kind==='quad'),bar=archived.find(g=>g.name.includes('CBAR')),rod=archived.find(g=>g.name.includes('CROD'));
 check(shell.pid===800&&shell.properties.pid===800,'composite-source archive retains native property ID');
 check(shell.properties.type==='ARCHIVED_SHELL','unknown shell property is not mislabeled PSHELL');
 check(shell.properties.original_property_type===null,'original composite/isotropic property type is explicitly unknown');
 check(shell.properties.note.includes('laminate plies')&&shell.properties.note.includes('equivalent geometric'),'missing laminate and offset provenance is explicit');
 check(Math.abs(shell.properties.thickness_m-.01)<1e-9&&Math.abs(shell.properties.z_top_m-shell.properties.z_bottom_m-.01)<1e-9,'archived shell thickness geometry remains available');
 check(bar.properties.type==='ARCHIVED_BAR'&&bar.properties.original_property_type===null&&bar.pid===900,'bar archive does not invent PBAR/PBARL provenance');
 check(rod.properties.type==='ARCHIVED_ROD'&&rod.properties.original_property_type===null&&rod.pid===901,'rod archive retains PID without inventing PROD provenance');
 check(Math.abs(rod.properties.section.area_m2-.03)<1e-8,'area-equivalent rod rendering retained with generic type');
 const staticArchive=Disk.prepare(Binary.parse(fixture()));
 check(staticArchive.mesh.imported_deck.solution===null,'static archive does not invent SOL101 for a possible SOL106 source');
 check(staticArchive.mesh.imported_deck.solution_label==='Static archive; original solution not stored','unknown original static solution is explicit');
 check(staticArchive.mesh.groups.every(g=>!g.material_orientation),'geometric archive axes do not imply stored material frames');
 const buckling=Disk.prepare(Binary.parse(fixture({eigen:true,preload:true})));check(buckling.kind==='buckling','v5 recognized');check(buckling.results.variants.length===2,'preload separate');check(buckling.results.variants[0].contours[0].max===123,'preload stress');check(buckling.results.variants[1].modes[1].load_factor===9,'buckling eigenvalue');
 assert.throws(()=>Disk.prepare(Binary.parse(fixture({nonfinite:true}))),/Nonfinite displacement/);checks++;
 assert.throws(()=>Binary.parse(fixture().subarray(0,50)),/Truncated/);checks++;
 assert.throws(()=>Disk.prepare(eig,{kind:'static'}),/disagrees/);checks++;
 const solid=Binary.parse(fixture());solid.tetras=[{eid:70,pid:2000,nodes:[3,10,100,1000]}];solid.nSolids=solid.nTetras=1;
 const solidView=Disk.prepare(solid).mesh.imported_connections.find(c=>c.card==='CTETRA');check(solidView.elements[0].nodes.join(',')==='0,1,2,3','solid native connectivity');check(solidView.elements[0].edges.length===6,'all tetrahedral edges');check(solidView.elements[0].properties.PID===2000,'solid PID retained');
 const duplicate=Binary.parse(fixture());duplicate.rbe2s[0].eid=51;assert.throws(()=>Disk.prepare(duplicate),/duplicate element ID/);checks++;
 check(Disk.prepare(Binary.parse(fixture()),{signature:'replacement'}).mesh.disk_signature==='replacement','repeated opens use fresh source identity');
 console.log('Stored results adapter: '+checks+' checks passed');return checks;
}
if(require.main===module){run();if(process.argv[2]){fs.mkdirSync(process.argv[2],{recursive:true});for(const [name,opts]of[['static',{}],['buckling',{eigen:true,preload:true}],['modes',{eigen:true}],['invalid',{nonfinite:true}]])fs.writeFileSync(path.join(process.argv[2],name+'.jfem'),fixture(opts));}}
module.exports={fixture,run};

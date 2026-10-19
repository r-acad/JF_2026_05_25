/* Volume elements remain volume elements. Only their external faces are
 * tessellated for display; triangle owner IDs preserve original inspection. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingSolidBoundary=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
 'use strict';
 const blob=values=>{const ints=Int32Array.from(values);return new Uint8Array(ints.buffer);};
 function prepare(elements,nodeCount){
  const faces=new Map(),edgeMap=new Map();let internal=0,nonmanifold=0;
  for(const e of elements){
   const n=e.nodes;if(!Array.isArray(n)||n.some(i=>!Number.isInteger(i)||i<0||i>=nodeCount)||new Set(n).size!==n.length)throw Error('Invalid solid connectivity at EID '+e.eid);
   let list;
   if(e.type==='CTETRA'&&[4,10].includes(n.length))list=n.length===10?[[0,2,1,6,5,4],[0,1,3,4,8,7],[1,2,3,5,9,8],[2,0,3,6,7,9]]:[[0,2,1],[0,1,3],[1,2,3],[2,0,3]];
   else if(e.type==='CHEXA'&&n.length===8)list=[[0,3,2,1],[4,5,6,7],[0,1,5,4],[1,2,6,5],[2,3,7,6],[3,0,4,7]];
   else if(e.type==='CPENTA'&&n.length===6)list=[[0,2,1],[3,4,5],[0,1,4,3],[1,2,5,4],[2,0,3,5]];
   else throw Error('Unsupported solid display topology at EID '+e.eid);
   for(const face of list){const points=face.map(i=>n[i]),key=points.slice().sort((a,b)=>a-b).join(':');const old=faces.get(key);if(old){old.count++;internal++;if(old.count===3)nonmanifold++;}else faces.set(key,{points,e,count:1});}
  }
  const conn=[],eids=[],pids=[];
  for(const {points:n,e,count}of faces.values())if(count===1){
   const tris=n.length===6?[[n[0],n[3],n[5]],[n[3],n[1],n[4]],[n[5],n[4],n[2]],[n[3],n[4],n[5]]]:n.length===4?[[n[0],n[1],n[2]],[n[0],n[2],n[3]]]:[n];
   for(const tri of tris){conn.push(...tri);eids.push(e.eid);pids.push(e.pid);}
   const perimeter=n.length===6?[n[0],n[3],n[1],n[4],n[2],n[5]]:n;
   for(let i=0;i<perimeter.length;i++){const a=perimeter[i],b=perimeter[(i+1)%perimeter.length],key=a<b?a+':'+b:b+':'+a;if(!edgeMap.has(key))edgeMap.set(key,[a,b]);}
  }
  return{format:'imported-solid-boundary-1',elements,triangles:{count:eids.length,eids:blob(eids),pids:blob(pids),conn:blob(conn)},edges:{count:edgeMap.size,conn:blob([...edgeMap.values()].flat())},topology_counts:{elements:elements.length,internal_faces:internal,nonmanifold_faces:nonmanifold},note:'External faces of original solid elements; quadratic tetrahedra retain their midside geometry. Interior faces are omitted only from display.'};
 }
 function groups(payload,decode){
  if(!payload)return[];const conn=decode(payload.triangles.conn),ids=decode(payload.triangles.eids),pids=decode(payload.triangles.pids),byPID=new Map(),edgeKeys=new Set(),edges=decode(payload.edges.conn);
  const edgeKey=(a,b)=>a<b?a+':'+b:b+':'+a;for(let i=0;i<edges.length;i+=2)edgeKeys.add(edgeKey(edges[i],edges[i+1]));
  if(conn.length!==3*ids.length||ids.length!==pids.length)throw Error('Invalid solid boundary triangle buffers.');
  for(let i=0;i<ids.length;i++){let g=byPID.get(pids[i]);if(!g){g={name:'IMPORTED_SOLIDS_P'+pids[i],kind:'solid',pid:pids[i],count:0,n_per_elem:3,ids:[],nodes:[],elements:[],edgePairs:new Map()};byPID.set(pids[i],g);}g.ids.push(ids[i]);g.nodes.push(conn[3*i],conn[3*i+1],conn[3*i+2]);for(let k=0;k<3;k++){const a=conn[3*i+k],b=conn[3*i+(k+1)%3],key=edgeKey(a,b);if(edgeKeys.has(key))g.edgePairs.set(key,[a,b]);}g.count++;}
  for(const e of payload.elements||[]){const g=byPID.get(e.pid);if(g)g.elements.push(e);}
  return[...byPID.values()].map(g=>({...g,eids:blob(g.ids),conn:blob(g.nodes),edge_conn:blob([...g.edgePairs.values()].flat())}));
 }
 return{prepare,groups};
});

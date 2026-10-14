/* Shared JFEM v1-v5 reader. Keep browser and server-backed viewers on the
 * same layout; v5 extends v4 with EVAL followed by the static STAT block. */
(function (root, factory) {
    const api = factory();
    if (typeof module === 'object' && module.exports) module.exports = api;
    else root.JFEMBinary = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
    'use strict';
    const littleEndian = new Uint8Array(new Uint32Array([1]).buffer)[0] === 1;

    function decodeLayout(input, legacyV5) {
        const bytes = input instanceof ArrayBuffer ? new Uint8Array(input) :
            ArrayBuffer.isView(input) ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength) : null;
        if (!bytes) throw new Error('JFEM input must be an ArrayBuffer or typed array');
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        let off = 0;
        function need(n) {
            if (!Number.isSafeInteger(n) || n < 0 || n > view.byteLength - off)
                throw new Error('Truncated or invalid JFEM data at byte ' + off);
        }
        function u32() { need(4); const x = view.getUint32(off, true); off += 4; return x; }
        function i32() { need(4); const x = view.getInt32(off, true); off += 4; return x; }
        function f32() { need(4); const x = view.getFloat32(off, true); off += 4; return x; }
        function marker() { need(4); const x = String.fromCharCode(...bytes.subarray(off, off + 4)); off += 4; return x; }
        function floats(n) {
            need(4 * n);
            let out;
            if (littleEndian && (bytes.byteOffset + off) % 4 === 0)
                out = new Float32Array(bytes.buffer, bytes.byteOffset + off, n);
            else { out = new Float32Array(n); for (let i = 0; i < n; i++) out[i] = view.getFloat32(off + 4 * i, true); }
            off += 4 * n;
            return out;
        }
        function ints(n) { need(4 * n); const a = []; for (let i = 0; i < n; i++) a.push(i32()); return a; }
        if (marker() !== 'JFEM') throw new Error('Not a JFEM binary file');
        const version = u32();
        if (version < 1 || version > 5) throw new Error('Unsupported JFEM version ' + version);
        const layout = legacyV5 && version === 5 ? 3 : version;
        const nNodes=u32(), nQuads=u32(), nTrias=u32(), nBars=u32(), nRods=u32(), nSubcases=u32();
        const nCelas=layout>=3?u32():0, nRBE2=layout>=3?u32():0, nRBE3=layout>=3?u32():0;
        const nTetras=layout>=4?u32():0, nHexas=layout>=4?u32():0, nPentas=layout>=4?u32():0;
        const nSolids=nTetras+nHexas+nPentas, nShells=nQuads+nTrias;
        // Check the minimum footprint before allocating from untrusted counts.
        const meshBytes=16*nNodes+(layout>=2?28:24)*nQuads+(layout>=2?24:20)*nTrias+
            (layout>=2?20:16)*(nBars+nRods)+28*nCelas+16*(nRBE2+nRBE3)+24*nTetras+40*nHexas+32*nPentas;
        const subcaseBytes=4+24*nNodes+28*nShells+28*nBars+8*nRods+4*nSolids+(layout>=3?12:0);
        need(meshBytes+nSubcases*subcaseBytes);
        const nodes=[], nidToIdx=Object.create(null);
        for (let i=0;i<nNodes;i++) {
            const nid=i32(), x=f32(), y=f32(), z=f32();
            if (nid<=0 || nidToIdx[nid]!==undefined) throw new Error('Invalid or duplicate GRID ' + nid);
            if (![x,y,z].every(Number.isFinite)) throw new Error('Nonfinite coordinates at GRID ' + nid);
            nodes.push({nid,x,y,z}); nidToIdx[nid]=i;
        }
        function shells(count, n) {
            const a=[];
            for (let i=0;i<count;i++) { const eid=i32(),pid=i32(),g=ints(n),thickness=layout>=2?f32():0; a.push({eid,pid,nodes:g,thickness}); }
            return a;
        }
        function lines(count) {
            const a=[];
            for (let i=0;i<count;i++) { const eid=i32(),pid=i32(),ga=i32(),gb=i32(),area=layout>=2?f32():0; a.push({eid,pid,ga,gb,area}); }
            return a;
        }
        const quads=shells(nQuads,4), trias=shells(nTrias,3), bars=lines(nBars), rods=lines(nRods);
        const celas=[],rbe2s=[],rbe3s=[];
        for (let i=0;i<nCelas;i++) { const eid=i32(),g1=i32(),c1=i32(),g2=i32(),c2=i32(),stiffness=f32(); f32(); celas.push({eid,g1,c1,g2,c2,stiffness}); }
        for (let i=0;i<nRBE2;i++) { const eid=i32(),gn=i32(),cm=i32(),slaves=ints(u32()); rbe2s.push({eid,gn,cm,slaves}); }
        for (let i=0;i<nRBE3;i++) { const eid=i32(),refgrid=i32(),refc=i32(),deps=ints(u32()); rbe3s.push({eid,refgrid,refc,deps}); }
        function solids(count,n) { const a=[]; for(let i=0;i<count;i++){const eid=i32(),pid=i32(); a.push({eid,pid,nodes:ints(n)});} return a; }
        const tetras=solids(nTetras,4),hexas=solids(nHexas,8),pentas=solids(nPentas,6);
        for (const elements of [quads,trias,tetras,hexas,pentas]) for (const e of elements)
            for (const nid of e.nodes) if(nidToIdx[nid]===undefined) throw new Error('Element '+e.eid+' references missing GRID '+nid);
        for (const e of [...bars,...rods]) if(nidToIdx[e.ga]===undefined||nidToIdx[e.gb]===undefined)
            throw new Error('Element '+e.eid+' references a missing GRID');
        const subcases=[];
        for(let s=0;s<nSubcases;s++) {
            const sid=u32(),disp=floats(nNodes*6),shellResults=floats(nShells*7),barResults=floats(nBars*7),rodResults=floats(nRods*2),solidResults=floats(nSolids);
            const spc=[],forces=[],moments=[];
            if(layout>=3) {
                let n=u32(); need(8*n); for(let i=0;i<n;i++)spc.push({nid:i32(),dofMask:u32()});
                n=u32(); need(16*n); for(let i=0;i<n;i++)forces.push({nid:i32(),fx:f32(),fy:f32(),fz:f32()});
                n=u32(); need(16*n); for(let i=0;i<n;i++)moments.push({nid:i32(),mx:f32(),my:f32(),mz:f32()});
            }
            subcases.push({sid,disp,shellResults,barResults,rodResults,solidResults,spc,forces,moments});
        }
        let eigenvalues=null,staticData=null;
        if(off<view.byteLength) {
            if(marker()!=='EVAL') throw new Error('Unexpected JFEM result trailer');
            const count=u32();
            if(count!==nSubcases) throw new Error('JFEM eigenvalue/mode count mismatch');
            need(8*count); eigenvalues=[];
            for(let i=0;i<count;i++) { const eig=view.getFloat64(off,true); off+=8; if(!Number.isFinite(eig))throw new Error('Nonfinite JFEM eigenvalue'); eigenvalues.push(eig); }
        }
        if(version===5) {
            if(!eigenvalues || marker()!=='STAT') throw new Error('Missing JFEM v5 static preload');
            const disp=floats(nNodes*6),fields=floats(nShells*3),vm=new Float32Array(nShells),est=new Float32Array(nShells),sed=new Float32Array(nShells);
            for(let i=0;i<nShells;i++){vm[i]=fields[3*i];est[i]=fields[3*i+1];sed[i]=fields[3*i+2];}
            staticData={disp,vm,est,sed};
        }
        if(off!==view.byteLength) throw new Error('Unexpected trailing JFEM bytes');
        let maxDisp=0,lo=[Infinity,Infinity,Infinity],hi=[-Infinity,-Infinity,-Infinity];
        for(const n of nodes) for(const [d,x] of [n.x,n.y,n.z].entries()){lo[d]=Math.min(lo[d],x);hi[d]=Math.max(hi[d],x);}
        if(subcases.length) for(let i=0;i<nNodes;i++){const u=subcases[0].disp;maxDisp=Math.max(maxDisp,Math.hypot(u[6*i],u[6*i+1],u[6*i+2]));}
        const size=nNodes?Math.hypot(hi[0]-lo[0],hi[1]-lo[1],hi[2]-lo[2]):0;
        return {version,legacyV5:legacyV5&&version===5,nNodes,nQuads,nTrias,nBars,nRods,nSubcases,nCelas,nRBE2,nRBE3,nTetras,nHexas,nPentas,nSolids,
            nodes,nidToIdx,quads,trias,bars,rods,tetras,hexas,pentas,celas,rbe2s,rbe3s,subcases,eigenvalues,staticData,_autoDefScale:maxDisp>0?size*0.1/maxDisp:1};
    }
    function parse(input) {
        try { return decodeLayout(input,false); }
        catch(error) {
            // Early JFEM v5 files omitted v4's solid extension. Accept that
            // archived layout only if its complete framing independently passes.
            const bytes=input instanceof ArrayBuffer?new Uint8Array(input):ArrayBuffer.isView(input)?new Uint8Array(input.buffer,input.byteOffset,input.byteLength):null;
            if(bytes&&bytes.length>=8&&new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength).getUint32(4,true)===5)
                try{return decodeLayout(input,true);}catch(legacyError){}
            throw error;
        }
    }
    return {parse};
});

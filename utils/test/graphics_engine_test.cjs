'use strict';
const assert=require('node:assert/strict');
const graphics=require('../../APPS/jfem_graphics.js');
const baseURI='http://127.0.0.1:8099/';
let passed=0;
function fixture({supported=true,supportError=null,initError=null,prepareError=null,isWebGPU=true,webGLError=null}={}){
  const calls=[],statuses=[],original={dataset:{},name:'original'},replacement={dataset:{},name:'replacement'};
  class GPU{
    static get IsSupportedAsync(){if(supportError)return Promise.reject(supportError);return Promise.resolve(supported);}
    constructor(canvas,options){calls.push(['gpu',canvas,options]);this.isWebGPU=isWebGPU;}
    async initAsync(...options){calls.push(['init',...options]);if(initError)throw initError;}
    async prepareGlslangAndTintAsync(){calls.push(['prepare']);if(prepareError)throw prepareError;}
    dispose(){calls.push(['dispose']);}
  }
  class GL{constructor(canvas){calls.push(['gl',canvas]);if(webGLError)throw webGLError;this.webGLVersion=2;}}
  const options={BABYLON:{WebGPUEngine:GPU,Engine:GL},canvas:original,baseURI,
    compilerLoader:async(_B,urls)=>{calls.push(['compilers',urls]);return {glslang:{glslang:{}},twgsl:{twgsl:{}}};},
    replaceFailedCanvas:canvas=>{assert.equal(canvas,original);calls.push(['replace']);return replacement;},
    onStatus:status=>statuses.push(status)};
  return {options,calls,statuses,original,replacement};
}
async function test(name,run){await run();passed++;console.log('PASS '+name);}
(async()=>{
  await test('Compiler glue initializes serially and preserves version-specific option types',async()=>{
    const prior={glslang:global.glslang,twgsl:global.twgsl},calls=[];let current='';
    try{
      const B={Tools:{LoadScriptAsync:async url=>{
        current=url.includes('/glslang/')?'glslang':'twgsl';const name=current;calls.push('load '+name);
        global[name]=async()=>{assert.equal(current,name,'Emscripten global Module was replaced before initialization');calls.push('init '+name);return {name};};
      }}};
      const result=await graphics.loadCompilers(B,graphics.compilerURLs('vendor/',baseURI),async()=>{});
      assert.deepEqual(calls,['load glslang','init glslang','load twgsl','init twgsl']);
      assert.equal((await result.glslang.glslang).name,'glslang');
      assert.ok(result.glslang.glslang instanceof Promise);assert.equal(result.twgsl.twgsl.name,'twgsl');
    }finally{for(const key of ['glslang','twgsl'])if(prior[key]===undefined)delete global[key];else global[key]=prior[key];}
  });
  await test('Missing compiler WASM rejects before entering an upstream wrapper',async()=>{
    const prior=global.fetch;let scriptLoaded=false;
    try{
      global.fetch=async()=>({ok:false,status:404});
      await assert.rejects(()=>graphics.loadCompilers({Tools:{LoadScriptAsync:async()=>{scriptLoaded=true;}}},
        graphics.compilerURLs('vendor/',baseURI)),/HTTP 404/);
      assert.equal(scriptLoaded,false);
    }finally{global.fetch=prior;}
  });
  await test('Corrupt compiler WASM rejects before entering an upstream wrapper',async()=>{
    const prior=global.fetch;let scriptLoaded=false;
    try{
      global.fetch=async()=>({ok:true,arrayBuffer:async()=>new TextEncoder().encode('<html>missing</html>').buffer});
      await assert.rejects(()=>graphics.loadCompilers({Tools:{LoadScriptAsync:async()=>{scriptLoaded=true;}}},
        graphics.compilerURLs('vendor/',baseURI)),/not valid WebAssembly/);
      assert.equal(scriptLoaded,false);
    }finally{global.fetch=prior;}
  });
  await test('Script load events produce an understandable fallback reason',async()=>{
    const B={Tools:{LoadScriptAsync:async()=>{throw {type:'error'};}}};
    await assert.rejects(()=>graphics.loadCompilers(B,graphics.compilerURLs('vendor/',baseURI),async()=>{}),/Could not load the bundled glslang shader compiler script/);
  });
  await test('WebGPU preferred and compilers initialized from local URLs',async()=>{
    const f=fixture(),r=await graphics.create(f.options);
    assert.equal(r.backend,'WebGPU');assert.equal(r.engine.jfemGraphics.backend,'WebGPU');
    assert.equal(f.original.dataset.graphicsBackend,'WebGPU');assert.equal(f.calls.some(c=>c[0]==='gl'),false);
    assert.deepEqual(f.calls.map(c=>c[0]),['compilers','gpu','init','prepare']);
    assert.equal(f.calls[0][1].glslang.wasmPath,baseURI+'vendor/glslang/glslang.wasm');
    assert.equal(f.calls[0][1].twgsl.jsPath,baseURI+'vendor/twgsl/twgsl.js');
    assert.equal(f.statuses.at(-1).backend,'WebGPU');
  });
  await test('No WebGPU adapter uses WebGL without loading compilers',async()=>{
    const f=fixture({supported:false}),r=await graphics.create(f.options);
    assert.equal(r.backend,'WebGL 2');assert.match(r.fallbackReason,/unavailable/);
    assert.deepEqual(f.calls.map(c=>c[0]),['gl']);assert.equal(r.canvas,f.original);
    assert.match(f.statuses.at(-1).message,/fallback/);
  });
  await test('Direct disk viewer uses WebGL without a hanging WASM request',async()=>{
    const f=fixture();f.options.baseURI='file:///repo/APPS/JFEM_results_viewer/postv11.html';
    const r=await graphics.create(f.options);assert.equal(r.backend,'WebGL 2');
    assert.match(r.fallbackReason,/opened directly from disk/);assert.deepEqual(f.calls.map(c=>c[0]),['gl']);
  });
  await test('Rejected support probe is handled',async()=>{
    const f=fixture({supportError:Error('adapter rejected')}),r=await graphics.create(f.options);
    assert.equal(r.backend,'WebGL 2');assert.match(r.fallbackReason,/adapter rejected/);
  });
  await test('Unavailable WebGPU class uses WebGL',async()=>{
    const f=fixture();delete f.options.BABYLON.WebGPUEngine;
    assert.equal((await graphics.create(f.options)).backend,'WebGL 2');
  });
  await test('Compiler errors fall back before GPU context creation',async()=>{
    const f=fixture();f.options.compilerLoader=async()=>{throw Error('local compiler missing');};
    const r=await graphics.create(f.options);assert.match(r.fallbackReason,/compiler missing/);
    assert.deepEqual(f.calls.map(c=>c[0]),['gl']);assert.equal(r.canvas,f.original);
  });
  await test('Failed GPU initialization disposes engine and replaces canvas',async()=>{
    const f=fixture({initError:Error('device rejected')}),r=await graphics.create(f.options);
    assert.equal(r.canvas,f.replacement);assert.equal(f.calls.at(-1)[1],f.replacement);
    assert.deepEqual(f.calls.map(c=>c[0]),['compilers','gpu','init','dispose','replace','gl']);
    assert.match(r.fallbackReason,/device rejected/);
  });
  await test('Failed shader preparation also cleans up and falls back',async()=>{
    const f=fixture({prepareError:Error('compiler initialization failed')}),r=await graphics.create(f.options);
    assert.equal(r.backend,'WebGL 2');assert.equal(r.canvas,f.replacement);assert.match(r.fallbackReason,/compiler initialization/);
  });
  await test('Renderer identification cannot claim WebGPU incorrectly',async()=>{
    const f=fixture({isWebGPU:false}),r=await graphics.create(f.options);
    assert.equal(r.backend,'WebGL 2');assert.match(r.fallbackReason,/did not provide/);
  });
  await test('Failure of both backends reports both reasons',async()=>{
    const f=fixture({initError:Error('GPU failed'),webGLError:Error('GL failed')});
    await assert.rejects(()=>graphics.create(f.options),/WebGPU: GPU failed WebGL: GL failed/);
  });
  await test('Compiler URLs stay on the app origin and respect each app vendor root',async()=>{
    assert.throws(()=>graphics.compilerURLs('https://cdn.example.invalid/',baseURI),/local application/);
    const urls=graphics.compilerURLs('../PANDEATOR_APP/vendor/','file:///repo/APPS/JFEM_results_viewer/postv11.html');
    assert.equal(urls.glslang.jsPath,'file:///repo/APPS/PANDEATOR_APP/vendor/glslang/glslang.js');
  });
  console.log(passed+' graphics engine tests passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});

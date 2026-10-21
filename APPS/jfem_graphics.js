/* Shared offline graphics startup for Boxer, PANDEATOR and the results viewer. */
(function(root,factory){
  const api=factory(root);
  if(typeof module==='object'&&module.exports)module.exports=api;
  else root.JFEMGraphics=api;
})(typeof globalThis!=='undefined'?globalThis:this,function(root){
  'use strict';
  function compilerURLs(vendorBase,baseURI=root.document?.baseURI){
    const base=new URL(vendorBase,baseURI),page=new URL(baseURI||base.href);
    if(base.origin!==page.origin||!['http:','https:','file:'].includes(base.protocol))
      throw Error('Graphics compiler libraries must be served from the local application.');
    return {glslang:{jsPath:new URL('glslang/glslang.js',base).href,wasmPath:new URL('glslang/glslang.wasm',base).href},
      twgsl:{jsPath:new URL('twgsl/twgsl.js',base).href,wasmPath:new URL('twgsl/twgsl.wasm',base).href}};
  }
  async function bounded(promise,message,milliseconds=30000){
    let timer;
    try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(message)),milliseconds);})]);}
    finally{clearTimeout(timer);}
  }
  async function verifyWasm(path){
    const response=await root.fetch(path,{cache:'force-cache'});
    if(!response.ok)throw Error('Bundled shader compiler is unavailable (HTTP '+response.status+'): '+path);
    const bytes=await response.arrayBuffer();
    if(!root.WebAssembly?.validate(bytes))throw Error('Bundled shader compiler is not valid WebAssembly: '+path);
  }
  async function loadCompilers(B,urls,preflight=verifyWasm){
    // Explicitly load both pinned modules before creating a GPU canvas context.
    // Babylon's deferred compiler loader does not propagate every rejection in
    // the supported engine versions; loading here permits a clean fallback.
    const modules={};
    for(const [name,paths] of Object.entries(urls)){
      // The upstream wrappers never reject after some asynchronous WASM errors.
      // Reject missing/corrupt files before entering those wrappers, and bound
      // initialization so a browser/driver fault cannot leave startup hanging.
      await bounded(preflight(paths.wasmPath),'Checking the '+name+' shader compiler timed out.');
      try{await bounded(B.Tools.LoadScriptAsync(paths.jsPath),'Loading the '+name+' shader compiler timed out.');}
      catch(error){throw Error('Could not load the bundled '+name+' shader compiler script'+(error?.message?': '+error.message:'.'));}
      if(typeof root[name]!=='function')throw Error('The bundled '+name+' shader compiler did not load.');
      // Both Emscripten glue scripts define a global Module. Instantiate one
      // completely before loading the other so their factories cannot collide.
      modules[name]=await bounded(root[name](paths.wasmPath),'Initializing the '+name+' shader compiler timed out.');
    }
    // Babylon 9's _initGlslangAsync returns this field directly; Babylon 7
    // wraps it in Promise.resolve. A promise works with both implementations.
    return {glslang:{...urls.glslang,glslang:Promise.resolve(modules.glslang)},twgsl:{...urls.twgsl,twgsl:modules.twgsl}};
  }
  function errorText(error){return String(error?.message||error||'Unknown graphics initialization error');}
  function replaceCanvas(canvas){
    // Once a canvas has a WebGPU context, browsers cannot reuse it for WebGL.
    // Initialization precedes app input handlers, so replacing it is safe here.
    if(!canvas?.parentNode||typeof canvas.cloneNode!=='function')return canvas;
    const replacement=canvas.cloneNode(false);
    canvas.parentNode.replaceChild(replacement,canvas);
    return replacement;
  }
  async function create({BABYLON:B=root.BABYLON,canvas,vendorBase='vendor/',baseURI=root.document?.baseURI,
    webGLOptions={},webGPUOptions={},onStatus=()=>{},compilerLoader=loadCompilers,replaceFailedCanvas=replaceCanvas}={}){
    if(!B||!canvas)throw Error('Graphics startup requires Babylon.js and a canvas.');
    let gpu=null,reason='';
    const report=(backend,message,detail='')=>onStatus({backend,message,detail});
    report('starting','Checking WebGPU support');
    try{
      if(!B.WebGPUEngine)throw Error('This graphics library does not provide WebGPU.');
      if(String(baseURI||'').startsWith('file:'))throw Error('WebGPU shader compilers require the local HTTP app address; this page was opened directly from disk.');
      if(!await B.WebGPUEngine.IsSupportedAsync)throw Error('WebGPU is unavailable in this browser or graphics driver.');
      report('starting','Initializing WebGPU','Loading the bundled shader compilers');
      const compilers=await compilerLoader(B,compilerURLs(vendorBase,baseURI));
      gpu=new B.WebGPUEngine(canvas,{antialias:true,stencil:true,preserveDrawingBuffer:true,enableAllFeatures:true,...webGPUOptions});
      await gpu.initAsync(compilers.glslang,compilers.twgsl);
      // Make the supplied local compiler instances ready before custom shaders.
      await gpu.prepareGlslangAndTintAsync?.();
      if(!gpu.isWebGPU)throw Error('WebGPU initialization did not provide a WebGPU engine.');
      gpu.jfemGraphics={backend:'WebGPU',fallbackReason:''};
      if(canvas.dataset)canvas.dataset.graphicsBackend='WebGPU';
      report('WebGPU','Renderer: WebGPU','Shader compilers are bundled locally.');
      return {engine:gpu,canvas,backend:'WebGPU',fallbackReason:''};
    }catch(error){
      reason=errorText(error);
      if(gpu){try{gpu.dispose();}catch(_){}canvas=replaceFailedCanvas(canvas);}
    }
    report('starting','Starting WebGL fallback',reason);
    let engine;
    try{engine=new B.Engine(canvas,true,{preserveDrawingBuffer:true,stencil:true,...webGLOptions});}
    catch(error){throw Error('Neither graphics backend could start. WebGPU: '+reason+' WebGL: '+errorText(error));}
    const backend=engine.webGLVersion>=2?'WebGL 2':'WebGL';
    engine.jfemGraphics={backend,fallbackReason:reason};
    if(canvas.dataset)canvas.dataset.graphicsBackend=backend;
    report(backend,'Renderer: '+backend+' (fallback)',reason);
    return {engine,canvas,backend,fallbackReason:reason};
  }
  function statusElement(id='graphics-status'){
    const element=root.document?.getElementById(id);
    return status=>{
      if(!element)return;
      element.textContent=status.message+(String(status.backend).startsWith('WebGL')&&status.detail?' · '+status.detail:'');
      element.title=status.detail||'';
      element.dataset.backend=status.backend;
    };
  }
  async function bootInline({sourceId,canvasId='renderCanvas',vendorBase='vendor/',statusId='graphics-status',...options}){
    const status=statusElement(statusId);
    try{
      const result=await create({...options,canvas:root.document.getElementById(canvasId),vendorBase,onStatus:status});
      root.JFEMGraphicsBoot=result;
      // Execute the existing classic script only after the async engine starts.
      // Keeping its global scope preserves inline UI handlers and automation.
      const source=root.document.getElementById(sourceId);
      if(!source)throw Error('Application startup source is missing.');
      const script=root.document.createElement('script');script.textContent=source.textContent;
      source.after(script);
      return result;
    }catch(error){status({backend:'error',message:'Graphics startup failed: '+errorText(error)});throw error;}
  }
  return {create,compilerURLs,loadCompilers,bootInline,statusElement};
});

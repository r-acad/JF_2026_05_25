/* Read-only engineering labels. Model inputs and exports retain full precision. */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingNumbers=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
  "use strict";
  function format(value,digits=6){
    if(!Number.isFinite(value))return "—";
    if(value===0)return "0";
    const magnitude=Math.abs(value), precision=Math.max(1,Math.min(15,digits));
    if(magnitude>=1e5||magnitude<1e-3)
      return value.toExponential(magnitude>=100?2:precision-1).replace(/(\.\d*?[1-9])0+(?=e)|\.0+(?=e)/,"$1");
    const places=magnitude>=100?Math.min(2,Math.max(0,precision-1-Math.floor(Math.log10(magnitude)))):Math.max(0,precision-1-Math.floor(Math.log10(magnitude)));
    const rounded=Number(value.toFixed(Math.min(15,places)));
    return String(Math.abs(rounded)>=100?Number(rounded.toFixed(2)):rounded);
  }
  return {format};
});

/* Editing locks protect geometry inputs without disabling property studies. */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingParameterLocks=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
  "use strict";
  const GROUPS={planform:["Planform","Airfoils"],mesh:["Torsion box","Ribs","Leading edge","Mesh","RBE3 and supports"]};
  const scope=key=>/^(planform|airfoil)\./.test(key)?"planform":/^(box|ribs|mesh|rbe3|supports)\./.test(key)||/^leading_edge\.(enabled|start_rib|end_rib|disabled_bays|chord_elements|rib_orientation|rib_orientations|rib_angle)$/.test(key)?"mesh":null;
  const explanations={planform:"Protects the base planform, aerodynamic edge points and Airfoils. Unlock to change the wing definition.",mesh:"Protects spar points, box and leading-edge layout, mesh subdivisions and RBE3/support parameters. Lock Planform too to hold the base wing geometry. Material, shell and beam properties remain editable."};
  function create({document:doc,getSchema}){
    const locked={planform:false,mesh:false},snapshots=new Map(),disabledBefore=new Map();
    const canonical=()=>getSchema().map(spec=>({spec,input:doc.getElementById("p-"+spec.key)})).filter(item=>item.input);
    function capture(scopeName){for(const {spec,input} of canonical())if(scope(spec.key)===scopeName)snapshots.set(spec.key,{value:input.value,checked:input.checked});}
    function restoreFields(scopeName){for(const {spec,input}of canonical())if(scope(spec.key)===scopeName){const saved=snapshots.get(spec.key);if(saved){input.value=saved.value;input.checked=saved.checked;}}}
    function apply(){
      for(const [control,previous]of disabledBefore){control.disabled=previous;control.removeAttribute("data-parameter-locked");}disabledBefore.clear();
      for(const name of Object.keys(GROUPS)){
        for(const group of GROUPS[name]){
          const section=doc.getElementById("group-"+group.toLowerCase().replace(/[^a-z0-9]+/g,"-"));if(!section)continue;
          section.classList.toggle("parameters-locked",locked[name]);
          for(const control of section.querySelectorAll("input,select,textarea,button")){
            if(control.matches("[data-parameter-lock-exempt],.help-icon,.help-button,[aria-label^='Help']"))continue;
            if(control.id.startsWith("p-")&&scope(control.id.slice(2))!==name)continue;
            if(locked[name]){disabledBefore.set(control,control.disabled);control.disabled=true;control.setAttribute("data-parameter-locked",name);}
          }
          section.dispatchEvent(new doc.defaultView.Event("parameterlockchange"));
        }
        const button=doc.getElementById("lock-"+name),note=doc.getElementById("lock-"+name+"-note");
        if(button){button.textContent=(locked[name]?"Unlock ":"Lock ")+name;button.setAttribute("aria-pressed",String(locked[name]));button.title=explanations[name];}
        if(note)note.textContent=(locked[name]?"Locked. ":"Unlocked. ")+explanations[name];
      }
    }
    function set(name,value){if(!(name in locked))return;locked[name]=!!value;if(locked[name])capture(name);apply();}
    function install(section,name){
      if(!["Planform","Mesh"].includes(name))return;
      const key=name.toLowerCase(),button=doc.createElement("button");button.type="button";button.id="lock-"+key;button.className="mini parameter-lock";button.dataset.parameterLockExempt="true";button.onclick=()=>set(key,!locked[key]);
      section.querySelector(".parameter-heading").appendChild(button);
      const note=doc.createElement("p");note.id="lock-"+key+"-note";note.className="parameter-lock-note";note.setAttribute("role","status");section.querySelector(".parameter-heading").after(note);
    }
    return{install,set,capture:()=>({...locked}),restore(value={}){for(const name of Object.keys(locked)){locked[name]=value[name]===true;if(locked[name])capture(name);}apply();},
      formBuilt(){for(const name of Object.keys(locked))if(locked[name])capture(name);apply();},
      guard(key){const name=scope(key);if(!name||!locked[name])return false;restoreFields(name);return true;},
      enforce(){for(const name of Object.keys(locked))if(locked[name])restoreFields(name);},isLocked:key=>!!locked[scope(key)]};
  }
  return{create,scope,GROUPS};
});

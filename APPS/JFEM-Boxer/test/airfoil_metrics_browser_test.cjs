"use strict";
const fs=require("node:fs"),path=require("node:path"),assert=require("node:assert/strict"),{chromium}=require(process.argv[3]);
const out=path.resolve(process.argv[2]),web=path.resolve(__dirname,"../web");
(async()=>{
 fs.mkdirSync(out,{recursive:true});const executable=process.env.CHROME_BIN||process.env.CHROMIUM_EXECUTABLE_PATH||(fs.existsSync("C:/Program Files/Google/Chrome/Application/chrome.exe")?"C:/Program Files/Google/Chrome/Application/chrome.exe":undefined);
 const browser=await chromium.launch({headless:true,...(executable?{executablePath:executable}:{})}),page=await browser.newPage({viewport:{width:1120,height:1000}}),errors=[];page.on("pageerror",e=>errors.push(e.message));
 try{
  await page.setContent('<!doctype html><html><head><style>body{margin:20px;background:#13202b;color:#dcebf6;font:13px Arial}#group-airfoils{width:380px}.row{display:flex;justify-content:space-between;gap:10px}input,select,button{font:inherit;padding:5px;min-width:0}.mini{background:#254255;color:#edf7ff;border:1px solid #607d91;border-radius:4px;cursor:pointer}[hidden]{display:none!important}</style></head><body><section id="group-airfoils"></section></body></html>');
  for(const file of["airfoils.css","svg_viewport.css"])await page.addStyleTag({path:path.join(web,file)});
  for(const file of["svg_viewport.js","airfoils.js"])await page.addScriptTag({path:path.join(web,file)});
  await page.evaluate(()=>{
   const host=document.getElementById("group-airfoils");host.innerHTML="<h2>Airfoil section dimensions</h2>";
   const field=(key,value,choices)=>{const row=document.createElement("label");row.className="row";row.id="row-"+key;row.textContent=key;const input=document.createElement(choices?"select":"input");input.id="p-"+key;if(choices)for(const v of choices){const o=document.createElement("option");o.value=o.textContent=v;input.append(o);}input.value=value;row.append(input);host.append(row);return input;};
   for(const station of["root","tip"]){field("airfoil."+station+"_source","naca",["naca","uiuc"]);field("airfoil."+station,station==="root"?"2412":"0012");field("airfoil."+station+"_profile","");}
   field("airfoil.n_points",121);const closed=field("airfoil.closed_trailing_edge","");closed.type="checkbox";closed.checked=true;field("airfoil.stations","[]");field("airfoil.interpolation","cosine",["cosine","linear"]);
   window.helpPayload=null;window.editor=WingAirfoils.install(host,{onHelp:value=>helpPayload=value});
  });
  const root=page.locator("#airfoil-root-card"),tip=page.locator("#airfoil-tip-card");
  for(const card of[root,tip]){assert.equal(await card.locator(".airfoil-outline").count(),1);assert.equal(await card.locator(".airfoil-midcamber").count(),1);assert.equal(await card.locator(".airfoil-thickness-dimension").count(),3);}
  assert.match(await tip.locator(".airfoil-camber-station-label").textContent(),/all x\/c/);assert.equal(await tip.locator(".airfoil-camber-dimension").count(),0);
  await root.screenshot({path:path.join(out,"root-cambered.png")});await tip.screenshot({path:path.join(out,"tip-symmetric.png")});
  await page.locator(".group-note button").click();assert.match(await page.evaluate(()=>helpPayload.paragraphs.join(" ")),/z=\(1−w\)z_i\+w z_j/);assert.match(await page.locator('[id="p-airfoil.interpolation"]').getAttribute("title"),/cos\(pi\*t\)/);
  const snapshots=[];
  for(const variant of["tabulated-reflex","blended","tied-maxima"]){
   const values=await page.evaluate(variant=>{
    const A=WingAirfoils,base={name:"Tabulated reflex / flap-like section",id:"reflex.dat",xu:[0,.2,.5,.75,1],zu:[0,.095,.07,.045,0],xl:[0,.2,.5,.75,1],zl:[0,-.025,-.03,-.055,0]};let p=base;
    if(variant==="blended"){
     const other=A.nacaProfile("0012"),xs=[...new Set([...base.xu,...base.xl,...other.xu,...other.xl])].sort((a,b)=>a-b),w=(1-Math.cos(Math.PI*.35))/2;
     p={name:"Cosine section blend (t = 0.35)",id:"blend.dat",xu:xs,xl:xs,zu:xs.map(x=>(1-w)*A.tableOrdinate(base.xu,base.zu,x)+w*A.tableOrdinate(other.xu,other.zu,x)),zl:xs.map(x=>(1-w)*A.tableOrdinate(base.xl,base.zl,x)+w*A.tableOrdinate(other.xl,other.zl,x))};
    }else if(variant==="tied-maxima")p={name:"Tabulated plateau",id:"plateau.dat",xu:[0,.2,.7,1],zu:[0,.08,.08,0],xl:[0,.2,.7,1],zl:[0,-.04,-.04,0]};
    Object.assign(p,{version:1,source_url:"https://m-selig.ae.illinois.edu/ads/coord/"+p.id,raw_sha256:"0".repeat(64),fetched_at:"fixture",normalization:"Normalized unit-chord regression fixture"});
    document.getElementById("p-airfoil.root_profile").value=JSON.stringify(p);const source=document.getElementById("p-airfoil.root_source");source.value="uiuc";source.dispatchEvent(new Event("change",{bubbles:true}));editor.refresh();
    const svg=document.querySelector("#airfoil-root-card svg");return{variant,metrics:svg.airfoilMetrics,svg:svg.__wingSVGViewport.exportSVG()};
   },variant);snapshots.push(values);await root.screenshot({path:path.join(out,variant+".png")});fs.writeFileSync(path.join(out,variant+".svg"),values.svg);
  }
  // White theme, exported annotations, resize and fit remain functional.
  await root.locator('[data-svgv="theme"]').click();await root.screenshot({path:path.join(out,"white-theme.png")});
  await page.evaluate(()=>document.getElementById("group-airfoils").style.width="300px");await root.locator('[data-svgv="fit"]').click();
  const bounds=await root.locator("svg").evaluate(svg=>{const s=svg.getBoundingClientRect();return [...svg.querySelectorAll("text[class^=airfoil-]")].map(t=>{const b=t.getBoundingClientRect();return{text:t.textContent,inside:b.left>=s.left-1&&b.right<=s.right+1&&b.top>=s.top-1&&b.bottom<=s.bottom+1};});});assert(bounds.length===4&&bounds.every(x=>x.inside),JSON.stringify(bounds));
  await root.screenshot({path:path.join(out,"narrow-white.png")});assert.deepEqual(errors,[]);for(const record of snapshots){assert.match(record.svg,/airfoil-midcamber/);assert.match(record.svg,/Max thickness/);}
  fs.writeFileSync(path.join(out,"summary.json"),JSON.stringify({passed:true,errors,bounds,snapshots:snapshots.map(({svg,...rest})=>rest)},null,2));console.log("Airfoil metrics browser: root/tip, tabulated reflex, blended surfaces, ties, help, SVG export, white theme and narrow layout passed.");
 }catch(error){await page.screenshot({path:path.join(out,"failure.png")});throw error;}finally{await browser.close();}
})().catch(error=>{console.error(error.stack);process.exitCode=1;});

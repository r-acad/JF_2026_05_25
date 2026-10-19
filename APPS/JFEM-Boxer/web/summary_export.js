/* Export the selected Summary tab as a portable report, without recomputing FE data. */
(function(root,factory){const api=factory();if(typeof module==="object"&&module.exports)module.exports=api;else root.WingSummaryExport=api;})(typeof globalThis!=="undefined"?globalThis:this,function(){
  "use strict";
  const FORMATS={csv:{label:"CSV",type:"text/csv;charset=utf-8"},md:{label:"Markdown",type:"text/markdown;charset=utf-8"},html:{label:"HTML",type:"text/html;charset=utf-8"}};
  const text=value=>String(value??"").replace(/\r\n?/g,"\n").trim();
  const html=value=>text(value).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;").replace(/'/g,"&#39;");
  const markdown=value=>text(value).replace(/\\/g,"\\\\").replace(/[|*_`\[\]<>]/g,"\\$&").replace(/\n/g,"<br>");
  function csvCell(value){
    let result=text(value);
    // Treat spreadsheet formulas in user-controlled labels as text. Signed numbers stay numeric.
    if(/^[=+@]/.test(result)||/^-(?!\d|\.\d)/.test(result)||/^[\t\r]/.test(String(value??"")))result="'"+result;
    return /[",\r\n]/.test(result)?'"'+result.replace(/"/g,'""')+'"':result;
  }
  function metadata(report){
    return [["Model",report.model],["Study / source file",report.source],["Load case",report.caseLabel],["Exported",report.generatedAt],["Status",report.stale?"Inputs changed; this summary describes the last-created model.":""]].filter(row=>text(row[1]));
  }
  function rowsForTable(block){
    const width=Math.max(0,...block.rows.map(row=>row.cells.reduce((n,cell)=>n+(cell.colSpan||1),0)));
    return block.rows.map(row=>({header:row.header,cells:row.cells.flatMap(cell=>[text(cell.text),...Array(Math.max(0,(cell.colSpan||1)-1)).fill("")]).concat(Array(width).fill("")).slice(0,width)}));
  }
  function csv(report){
    const rows=[[report.title],...metadata(report),[]];
    for(const block of report.blocks){
      if(block.type==="table")rows.push(...rowsForTable(block).map(row=>row.cells),[]);
      else rows.push([block.text],[]);
    }
    return "\uFEFF"+rows.map(row=>row.map(csvCell).join(",")).join("\r\n")+"\r\n";
  }
  function md(report){
    const lines=["# "+markdown(report.title),"",...metadata(report).map(([key,value])=>"**"+key+":** "+markdown(value)),""];
    for(const block of report.blocks){
      if(block.type!=="table"){lines.push((block.type==="heading"?"## ":"")+markdown(block.text),"");continue;}
      const rows=rowsForTable(block);if(!rows.length)continue;
      const width=rows[0].cells.length;
      const header=rows[0].header?rows.shift().cells:Array.from({length:width},(_,i)=>width===2?["Item","Value"][i]:"Column "+(i+1));
      lines.push("| "+header.map(markdown).join(" | ")+" |","| "+header.map(()=>"---").join(" | ")+" |");
      for(const row of rows)lines.push("| "+row.cells.map(markdown).join(" | ")+" |");
      lines.push("");
    }
    return lines.join("\n").trimEnd()+"\n";
  }
  function htmlReport(report){
    const blocks=report.blocks.map(block=>{
      if(block.type!=="table")return block.type==="heading"?"<h2>"+html(block.text)+"</h2>":"<p>"+html(block.text).replace(/\n/g,"<br>")+"</p>";
      return '<table><tbody>'+block.rows.map(row=>"<tr>"+row.cells.map(cell=>{const tag=row.header||cell.header?"th":"td";return "<"+tag+(cell.colSpan>1?' colspan="'+Math.trunc(cell.colSpan)+'"':"")+">"+html(cell.text).replace(/\n/g,"<br>")+"</"+tag+">";}).join("")+"</tr>").join("")+"</tbody></table>";
    }).join("\n");
    return '<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+html(report.title)+" — "+html(report.model||"JFEM-Boxer")+'</title><style>body{font:16px/1.5 system-ui,sans-serif;color:#172b3e;background:white;max-width:1100px;margin:2rem auto;padding:0 1.5rem}h1{font-size:1.7rem}h2{font-size:1.2rem;margin-top:1.8rem}dl{display:grid;grid-template-columns:max-content 1fr;gap:.3rem 1rem}dt{font-weight:600}dd{margin:0;overflow-wrap:anywhere}table{border-collapse:collapse;width:100%;margin:1rem 0}td,th{border:1px solid #b9c7d3;padding:.45rem .65rem;text-align:left;vertical-align:top;overflow-wrap:anywhere}th{background:#eaf0f6}p{white-space:normal}footer{margin-top:2rem;border-top:1px solid #b9c7d3;padding-top:.7rem;color:#536779;font-size:.85rem}@media print{body{max-width:none;margin:0;padding:0}tr{break-inside:avoid}h2{break-after:avoid}}</style></head><body><main><h1>'+html(report.title)+'</h1><dl>'+metadata(report).map(([key,value])=>"<dt>"+html(key)+"</dt><dd>"+html(value)+"</dd>").join("")+"</dl>\n"+blocks+'</main><footer>Exported from JFEM-Boxer. Values and units reproduce the selected Summary tab.</footer></body></html>\n';
  }
  function nodeText(node){
    if(node.nodeType===3)return node.nodeValue||"";
    if(node.nodeType!==1||node.hidden||node.matches?.("button,select,input,textarea,[data-summary-export]"))return "";
    if(node.tagName==="BR")return "\n";
    return Array.from(node.childNodes||[],nodeText).join("");
  }
  const compact=node=>nodeText(node).replace(/[ \t\n]+/g," ").trim();
  function collect(host,context={}){
    const blocks=[];
    function walk(node){
      if(node.nodeType!==1||node.hidden||node.matches?.("button,select,input,textarea,label,[data-summary-export]"))return;
      const tag=node.tagName;
      if(tag==="TABLE"){
        let rows=[];const flush=()=>{if(rows.length)blocks.push({type:"table",rows});rows=[];};
        for(const row of Array.from(node.rows||[])){
          const cells=Array.from(row.cells||[],cell=>({text:compact(cell),header:cell.tagName==="TH",colSpan:cell.colSpan||1}));
          if(cells.length===1&&cells[0].colSpan>1){flush();blocks.push({type:"heading",text:cells[0].text});}
          else if(cells.length)rows.push({header:row.parentElement?.tagName==="THEAD"||cells.every(cell=>cell.header),cells});
        }
        flush();return;
      }
      if(/^(H[1-6]|SUMMARY)$/.test(tag)){const value=compact(node);if(value)blocks.push({type:"heading",text:value});return;}
      if(tag==="P"||tag==="LI"){const value=compact(node);if(value)blocks.push({type:"paragraph",text:value});return;}
      for(const child of node.children||[])walk(child);
    }
    walk(host);
    return {title:context.title||"Model summary",model:text(context.model),source:text(context.source),caseLabel:text(context.caseLabel),stale:!!context.stale,generatedAt:context.generatedAt||new Date().toISOString(),blocks};
  }
  function filename(report,extension){
    const clean=value=>String(value||"").replace(/\.(?:wingfem\.)?json$/i,"").replace(/[^A-Za-z0-9_.-]+/g,"_").replace(/^_+|_+$/g,"").slice(0,100);
    return [clean(report.model)||"JFEM-Boxer",clean(report.title),clean(report.caseLabel)].filter(Boolean).join("_")+"."+extension;
  }
  function serialize(report,format){if(format==="csv")return csv(report);if(format==="md")return md(report);if(format==="html")return htmlReport(report);throw Error("Unknown summary export format: "+format);}
  function create({document:doc=globalThis.document,getContext=()=>({}),download}={}){
    const win=doc.defaultView||globalThis,views=[{id:"summary",title:"General model summary",host:"stats"},{id:"weights",title:"Mass properties",host:"weights-report"}],cleanup=[];
    function defaultDownload(content,name,type){
      if(win.WingWorkspace?.downloadText)return win.WingWorkspace.downloadText(content,name,type,doc);
      const url=win.URL.createObjectURL(new win.Blob([content],{type})),link=doc.createElement("a");link.href=url;link.download=name;doc.body.append(link);link.click();link.remove();win.setTimeout(()=>win.URL.revokeObjectURL(url),30000);
    }
    const save=download||defaultDownload;
    function exportView(id,format){
      const view=views.find(item=>item.id===id),host=view&&doc.getElementById(view.host);
      if(!host?.querySelector("table"))throw Error("Create or read a model with this summary before exporting.");
      const report=collect(host,{...getContext(id),title:view.title}),content=serialize(report,format),name=filename(report,format);
      save(content,name,FORMATS[format].type);return {report,content,filename:name};
    }
    for(const view of views){
      const panel=doc.getElementById("panel-"+view.id),host=doc.getElementById(view.host);if(!panel||!host)continue;
      const toolbar=doc.createElement("div");toolbar.className="summary-export-actions";toolbar.dataset.summaryExport=view.id;toolbar.setAttribute("role","group");toolbar.setAttribute("aria-label","Export "+view.title);
      const label=doc.createElement("span");label.textContent="Export summary";toolbar.append(label);
      const status=doc.createElement("span");status.className="summary-export-status";status.setAttribute("role","status");status.setAttribute("aria-live","polite");
      for(const [format,detail]of Object.entries(FORMATS)){
        const button=doc.createElement("button");button.type="button";button.className="mini";button.dataset.summaryFormat=format;button.textContent=detail.label;button.title="Download the current "+view.title.toLowerCase()+" as "+detail.label+", including units and the selected load case.";
        button.onclick=()=>{try{const result=exportView(view.id,format);status.textContent="Downloaded "+result.filename;}catch(error){status.textContent="Export failed: "+error.message;}};toolbar.append(button);
      }
      toolbar.append(status);panel.prepend(toolbar);
      const refresh=()=>{const ready=!!host.querySelector("table");for(const button of toolbar.querySelectorAll("button"))button.disabled=!ready;status.textContent="";};refresh();
      const observer=new win.MutationObserver(refresh);observer.observe(host,{childList:true,subtree:true,characterData:true});cleanup.push(()=>{observer.disconnect();toolbar.remove();});
    }
    return {exportView,destroy(){cleanup.forEach(fn=>fn());}};
  }
  return {FORMATS,collect,serialize,csv,md,html:htmlReport,filename,create};
});

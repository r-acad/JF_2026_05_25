/* Airfoil tools for assistants: one implementation for the chat (Gemini) and for the MCP bridge.
 *
 * Boxer generates NACA 4- and 5-digit sections; every other section is a table of coordinates, taken from
 * the UIUC database (which the Boxer program reads) or typed in. Seen with the real service on 2026-11-20:
 * an assistant typed "NACA 64A415" into the code box, which left the Airfoils form invalid, and an invalid
 * form blocks every later change of the Study.
 *
 * create({fetch, airfoils, readParameters, updateParameters, inputValue, setInput}) -> {find, set, nacaCode}
 *   fetch(url, init)           the Boxer program (GET /api/airfoils, /api/airfoils/profile?id=)
 *   airfoils                   WingAirfoils (nacaProfile, profileMetrics, readCoordinateFile)
 *   readParameters()           the Study parameters; may throw while a form is invalid
 *   updateParameters(values)   validated, atomic update; throws with Boxer's reason when refused
 *   inputValue(id)             the text of a form input, e.g. "p-airfoil.root"
 *   setInput(id, value)        set a form input through its own handlers
 * A refusal is thrown as one Error whose message ends with what to do next, so that it reads the same
 * through every bridge. */
(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;else root.WingBoxerAirfoilTools=api;})(typeof globalThis!=='undefined'?globalThis:this,function(){
  'use strict';
  const clean=value=>String(value??'').replace(/\s+/g,' ').trim();
  const nacaCode=value=>{const digits=String(value??'').trim().toUpperCase().replace(/NACA/g,'').replace(/[\s_-]/g,'');return /^\d{4,5}$/.test(digits)&&Number(digits.slice(-2))>0?'NACA'+digits:null;};
  const squeeze=value=>String(value??'').toLowerCase().replace(/\.dat$/,'').replace(/[^a-z0-9]/g,'');
  const percent=value=>(100*value).toFixed(1)+' %';
  const refuse=(message,advice)=>Error(advice?message+' '+advice:message);
  // The longest run of characters two names share.
  const common=(a,b)=>{let best=0;const row=new Uint16Array(b.length+1);for(let i=1;i<=a.length;i++)for(let j=b.length;j>=1;j--){row[j]=a[i-1]===b[j-1]?row[j-1]+1:0;if(row[j]>best)best=row[j];}return best;};
  /* The catalogue holds file names only, so a profile is found by how much of its name a file name
   * shares: "64a415" finds naca64a410 first although no file has exactly that name. */
  function nearest(names,query,count){
    const whole=squeeze(query),core=whole.replace(/^naca/,'');
    const terms=[...new Set([whole,core,...String(query).toLowerCase().split(/[\s,;/()]+/).map(squeeze)])].filter(term=>term.length>=2&&term!=='naca'&&term!=='dat');
    const scored=[];
    for(const item of names){
      let score=0;
      for(const term of terms){const hit=common(term,item.key);if(hit>=Math.min(3,term.length))score+=hit*hit/term.length;}
      if(score>=1.5)scored.push({item,score});
    }
    scored.sort((a,b)=>b.score-a.score||a.item.key.length-b.item.key.length||a.item.key.localeCompare(b.item.key));
    return{exact:core.length>=3&&scored.some(entry=>entry.item.key.includes(core)),items:scored.slice(0,count).map(entry=>entry.item.id)};
  }
  function create(options={}){
    const A=options.airfoils;let names=null;
    async function read(url){
      let response;try{response=await options.fetch(url,{cache:'no-store'});}catch{throw Error('This page could not reach the Boxer program.');}
      let data;try{data=await response.json();}catch{throw Error('The Boxer program returned an unreadable answer.');}
      if(!response.ok||data.ok===false)throw Error(String(data.error||data.message||'The request failed.'));
      return data;
    }
    async function catalogue(){
      if(names)return names;
      let data;
      try{data=await read('/api/airfoils');}
      catch(error){throw refuse('The UIUC airfoil database could not be read: '+error.message,'Use set_airfoil with the NACA 4- or 5-digit code of the nearest thickness and camber, or with coordinates, and say in your report that the database could not be reached.');}
      if(!Array.isArray(data.items)||!data.items.length)throw Error('The UIUC airfoil catalogue came back empty.');
      names=data.items.map(item=>({id:String(item.id),key:squeeze(item.id)}));return names;
    }
    async function find(args={}){
      const query=clean(args.query??args.name??args.q);
      if(!query)throw Error('find_airfoils needs “query”: the name of the profile or a part of it, for example "64a410", "sc2" or "b737".');
      const list=await catalogue(),found=nearest(list,query,Math.max(1,Math.min(40,Math.trunc(Number(args.limit)||15))));
      if(!found.items.length)return{status:'completed',message:'No file name in the UIUC database resembles “'+query+'”.',total:0,items:[],catalogue:list.length,
        note:'No file name in the database resembles “'+query+'”. Search again with a shorter part of the name (file names look like naca64a410, naca642415, sc20714, rae2822, b737a, whitcomb), or use set_airfoil with the nearest NACA 4- or 5-digit code or with coordinates.'};
      return{status:'completed',message:'Found '+found.items.length+' file name'+(found.items.length===1?'':'s')+' in the UIUC database for “'+query+'”.',total:found.items.length,items:found.items,catalogue:list.length,
        note:(found.exact?'These file names match.':'No file name matches exactly; these are the nearest. Choose the closest in family, camber and thickness.')+' Apply one with set_airfoil {"section": ..., "uiuc": "<file name>"}; its answer gives the measured thickness and camber. Nothing has been changed yet.'};
    }
    /* Coordinates typed by an assistant, in the order of a coordinate file or as two surfaces that each start
     * at the leading edge. They go through the same reader as a file the user chooses. */
    async function typedProfile(text,name){
      const fail=message=>refuse(message,'Write one "x z" pair on each line, as fractions of the chord: start at the trailing edge (1 0), follow the upper surface to the leading edge (0 0) and come back along the lower surface to the trailing edge, with at least 12 points on each surface. Or look the profile up with find_airfoils.');
      const points=[];
      for(const line of text.replace(/\\[nr]/g,'\n').replace(/[;|]/g,'\n').replace(/\]\s*,\s*\[/g,'\n').split(/\r?\n/)){
        if(/[a-df-z]/i.test(line))continue;                                        // a name or a heading
        const numbers=(line.match(/[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?/gi)||[]).map(Number);
        if(numbers.length%2||!numbers.every(Number.isFinite))throw fail('The coordinates could not be read: “'+clean(line).slice(0,60)+'” does not hold pairs of numbers.');
        for(let i=0;i<numbers.length;i+=2)points.push([numbers[i],numbers[i+1]]);
      }
      if(points.length<21)throw fail('Only '+points.length+' points were given; a section needs at least 21 around the profile.');
      // Two surfaces written one after the other, each from the leading edge: the first is turned round to make one loop.
      const xs=points.map(point=>point[0]),low=Math.min(...xs),span=Math.max(...xs)-low,jumps=[];
      for(let i=1;i<points.length;i++)if(xs[i]<xs[i-1]-.5*span)jumps.push(i);
      let loop=points;
      if(jumps.length===1&&xs[0]-low<.05*span){
        const first=points.slice(0,jumps[0]).reverse(),second=points.slice(jumps[0]),nose=first.at(-1);
        loop=first.concat(Math.hypot(second[0][0]-nose[0],second[0][1]-nose[1])<1e-9*Math.max(span,1)?second.slice(1):second);
      }
      let title=(name||'Typed section').replace(/[#!]/g,' ').replace(/\s+/g,' ').trim().slice(0,80);if(!/[a-z]/i.test(title))title='Section '+title;
      const file='typed_'+(title.replace(/[^A-Za-z0-9]+/g,'_').replace(/^_+|_+$/g,'')||'section').slice(0,60)+'.dat';
      const bytes=new TextEncoder().encode(title+'\n'+loop.map(point=>point[0].toFixed(6)+' '+point[1].toFixed(6)).join('\n')+'\n');
      let profile;
      try{profile=await A.readCoordinateFile({name:file,arrayBuffer:async()=>bytes.buffer});}catch(error){throw fail('The coordinates do not describe one airfoil: '+error.message);}
      profile.source='Coordinates typed by the Boxer assistant';return profile;
    }
    const listed=value=>{try{return Array.isArray(value)?value:typeof value==='string'&&value.trim()?JSON.parse(value):[];}catch{return[];}};
    async function set(args={}){
      if(!A)throw Error('The airfoil tools are not available in this page.');
      const typed=String(args.coordinates??'').trim(),given=[clean(args.naca)&&'naca',clean(args.uiuc)&&'uiuc',typed&&'coordinates'].filter(Boolean);
      if(given.length!==1)throw refuse('set_airfoil needs exactly one of “naca”, “uiuc” or “coordinates”.','Give "naca" for a 4- or 5-digit code, "uiuc" with a file name from find_airfoils for any other profile, or "coordinates" typed by hand.');
      const where=clean(args.section??args.station??args.eta).toLowerCase().replace(/^eta\s*=?\s*/,''),eta=where===''?NaN:Number(where.replace(',','.'));
      const sections=/^(both|all|wing|root and tip|root, ?tip)$/.test(where)?['root','tip']:where==='root'||eta===0?['root']:where==='tip'||eta===1?['tip']:null;
      if(!sections&&!(eta>0&&eta<1))throw Error('set_airfoil needs “section”: "root", "tip", "both", or the eta of an intermediate section as a number between 0 and 1.');
      const wanted=clean(args.thickness??args.tc).replace('%','').replace(',','.').trim();let target=null;
      if(wanted){
        target=Number(wanted);if(target>1)target/=100;
        if(!(target>=.02&&target<=.4))throw Error('“thickness” is the thickness of the section in percent of the chord, between 2 and 40.');
      }
      let source,code,profile=null,shape,label;
      if(given[0]==='naca'){
        try{shape=A.nacaProfile(clean(args.naca));}
        catch(error){throw refuse('“'+clean(args.naca)+'” is not a NACA 4- or 5-digit code. '+error.message,'Boxer generates only 4- and 5-digit NACA sections. Look this profile up with find_airfoils and set it with "uiuc", or give its coordinates.');}
        source='naca';code=shape.id;label=shape.name;
      }else if(given[0]==='uiuc'){
        const list=await catalogue();
        const asked=clean(args.uiuc),hit=list.find(item=>item.id.toLowerCase()===asked.toLowerCase())||list.find(item=>item.key===squeeze(asked));
        if(!hit){
          const near=nearest(list,asked,8).items;
          throw refuse('The UIUC database has no profile called “'+asked+'”.',near.length?'The nearest file names are: '+near.join(', ')+'. Call set_airfoil again with one of them.':'Search with find_airfoils and use a file name from its answer.');
        }
        let data;
        try{data=await read('/api/airfoils/profile?id='+encodeURIComponent(hit.id));}
        catch(error){throw refuse('The coordinates of '+hit.id+' could not be read: '+error.message,'Choose another file name from find_airfoils, or use a NACA code or coordinates.');}
        profile=data.profile;source='uiuc';code=String(profile?.id||hit.id);shape=profile;label=clean(profile?.name||code);
      }else{
        profile=await typedProfile(typed,clean(args.name));
        source='file';code=profile.id;shape=profile;label=clean(profile.name);
      }
      let metrics;
      try{metrics=A.profileMetrics(shape);}catch(error){throw refuse('This profile cannot be used: '+error.message,'Choose another profile.');}
      const thickness=metrics.maxThickness.value,camber=metrics.maxCamber.signedValue,count=source==='naca'?0:profile.xu.length+profile.xl.length-1;
      if(source==='file'&&!(thickness>=.02&&thickness<=.4))throw refuse('These coordinates give a section '+percent(thickness)+' of the chord thick, which is not a usable wing section.','Check the values: x and z are fractions of the chord, and z is positive on the upper surface.');
      const values={};
      for(const section of sections||[]){
        values['airfoil.'+section+'_source']=source;
        values['airfoil.'+section+'_profile']=source==='naca'?'':JSON.stringify(profile);   // only the coordinates of the source in use are kept
        if(source==='naca')values['airfoil.'+section]=code;
      }
      if(!sections){
        let held;
        try{held=(await options.readParameters())?.['airfoil.stations'];}
        catch(error){throw refuse(String(error.message),'The Study could not be read. If Boxer names a section whose code is not a NACA 4- or 5-digit code, set that section with set_airfoil first, then call again.');}
        const rows=listed(held).map(row=>({...row})),row={eta,source,code,...(profile?{profile}:{})},at=rows.findIndex(item=>Math.abs(Number(item.eta)-eta)<1e-6);
        if(at>=0)rows[at]=row;else rows.push(row);
        values['airfoil.stations']=rows.sort((a,b)=>a.eta-b.eta);
      }
      const place=sections?(sections.length===2?'the root and tip profiles':'the '+sections[0]+' profile'):'the profile at eta '+eta;
      const what=source==='naca'?label:source==='uiuc'?'“'+label+'” from the UIUC database ('+code+')':'“'+label+'”, typed coordinates ('+count+' points)';
      let summary='Set '+place+' to '+what+': thickness '+percent(thickness)+' of chord, camber '+percent(camber)+'.';
      const refused=error=>{
        const boxes=['root','tip'].map(section=>section+': source “'+clean(options.inputValue?.('p-airfoil.'+section+'_source')??'?')+'”, code box “'+clean(options.inputValue?.('p-airfoil.'+section)??'?')+'”').join('; ');
        return refuse(String(error.message).replace(/^Boxer chat\.\s*/,''),'Nothing was changed. The Airfoils form holds '+boxes+'. A code box that is not a NACA 4- or 5-digit code blocks all changes: set that section with set_airfoil as well. Correct the call yourself; do not ask the user.');
      };
      try{await options.updateParameters(values);}
      catch(error){
        // A code box with something other than a NACA code blocks every change. Where this call replaces that section, the box is put right first.
        let mended=false;
        for(const section of sections||[]){
          const box=options.inputValue?.('p-airfoil.'+section);
          if(box===undefined||box===null||nacaCode(box))continue;
          try{await options.setInput('p-airfoil.'+section,source==='naca'?code:'NACA00'+String(Math.min(30,Math.max(6,Math.round(100*thickness)))).padStart(2,'0'));mended=true;}catch{}
        }
        if(!mended)throw refused(error);
        try{await options.updateParameters(values);}catch(again){throw refused(again);}
      }
      /* Another thickness with the same camber is the Loft thickness table. One row of that table would
       * thicken the whole wing (the real service did this on 2026-11-20), so the table is written here:
       * the sections that are not being set are listed with the thickness they have. */
      let table=null,scaled=null,unscaled='',built=null;
      const spots=sections?sections.map(section=>section==='root'?0:1):[eta];
      try{
        const held=(await options.readParameters())||{};
        const rows=listed(held['loft.thickness_stations']).map(row=>({eta:Number(row.eta),tc:Number(row.tc)})).filter(row=>Number.isFinite(row.eta)&&row.tc>0);
        if(target!==null&&(rows.length||Math.abs(target-thickness)>5e-4)){
          const measured=(kind,name,stored)=>{try{return A.profileMetrics(kind==='naca'||!kind?A.nacaProfile(name):typeof stored==='string'?JSON.parse(stored):stored).maxThickness.value;}catch{return 0;}};
          const fresh=!rows.length,keepRow=(at,tc)=>{if(tc>0)rows.push({eta:at,tc:+tc.toFixed(5)});};
          if(fresh){
            keepRow(0,measured(held['airfoil.root_source'],held['airfoil.root'],held['airfoil.root_profile']));
            for(const row of listed(held['airfoil.stations']))keepRow(Number(row.eta),measured(row.source,row.code,row.profile));
            keepRow(1,measured(held['airfoil.tip_source'],held['airfoil.tip'],held['airfoil.tip_profile']));
          }
          for(const at of spots){const index=rows.findIndex(row=>Math.abs(row.eta-at)<1e-6);if(index>=0)rows[index].tc=target;else rows.push({eta:at,tc:target});}
          rows.sort((a,b)=>a.eta-b.eta);
          await options.updateParameters({'loft.thickness_stations':rows});
          summary+=' Scaled '+place+' to a thickness of '+percent(target)+' of chord with the Loft thickness table; the camber is kept'+(fresh?', and the other sections keep their thickness.':'.');
          scaled=target;
        }else if(rows.length){
          // A table is in force and no thickness was asked for. A section the table does not list is listed with its own thickness, so that it is built as given.
          const missing=spots.filter(at=>!rows.some(row=>Math.abs(row.eta-at)<1e-6));
          if(missing.length){
            for(const at of missing)rows.push({eta:at,tc:+thickness.toFixed(5)});
            rows.sort((a,b)=>a.eta-b.eta);
            await options.updateParameters({'loft.thickness_stations':rows});
            summary+=' Listed '+place+' in the Loft thickness table with its own thickness of '+percent(thickness)+', so that the table does not rescale it.';
          }
        }
        if(rows.length){
          table=rows;
          // What the table makes of this section: constant beyond its ends, interpolated between its rows.
          const at=spots[0],after=rows.findIndex(row=>row.eta>=at-1e-6);
          if(after<0)built=rows.at(-1).tc;else if(after===0||Math.abs(rows[after].eta-at)<1e-6)built=rows[after].tc;
          else{const a=rows[after-1],b=rows[after],s=(at-a.eta)/(b.eta-a.eta),w=held['loft.thickness_interpolation']==='cosine'?(1-Math.cos(Math.PI*s))/2:s;built=(1-w)*a.tc+w*b.tc;}
        }
      }catch(error){if(target!==null)unscaled=String(error.message).replace(/^Boxer chat\.\s*/,'');}
      return{status:'completed',message:summary,set:sections||['eta '+eta],source:source==='file'?'coordinates':source,profile:label,...(source==='naca'?{}:{file:code,points:count}),
        thickness_percent:+(100*thickness).toFixed(2),thickness_at_xc:+metrics.maxThickness.x.toFixed(3),camber_percent:+(100*camber).toFixed(2),...(shape.warning?{warning:shape.warning}:{}),
        ...(scaled!==null?{scaled_to_thickness_percent:+(100*scaled).toFixed(2)}:{}),...(unscaled?{thickness_not_scaled:unscaled}:{}),...(built!==null?{built_thickness_percent:+(100*built).toFixed(2)}:{}),...(table?{thickness_table:table}:{}),
        note:'Report the profile that was set, with its thickness and camber'+(source==='naca'?'.':', and how it differs from the one asked for if it is not the same.')+
          (scaled!==null?' The section was scaled to the thickness asked for; say so.':built!==null&&Math.abs(built-thickness)>5e-4?' The Loft thickness table (thickness_table, eta and thickness over chord) is in force and builds this section '+percent(built)+' thick instead of its own '+percent(thickness)+'. Say so. To build it with its own thickness call set_airfoil again with "thickness":"'+(100*thickness).toFixed(1)+'".':table?' The Loft thickness table (thickness_table) lists this section with the thickness it is built with (built_thickness_percent).':' To give the section another thickness with the same camber, call set_airfoil again with "thickness"; never write a single row into loft.thickness_stations, which would thicken the whole wing.')};
    }
    return{find,set,nacaCode};
  }
  return{create,nacaCode};
});

<!doctype html>
<html lang="pt-PT">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>:root{color-scheme:light}body{margin:0;padding:0;font:14px -apple-system,BlinkMacSystemFont,sans-serif}img{max-width:100%}[hidden]{display:none!important}</style>
</head>
<body>
<script>
// Armazenamento local (IndexedDB) para usar a aplicação fora do Claude.
// Imita a pequena parte da API usada pela página: db, assets e downloads.
(function(){
  "use strict";
  const DBN='relatorios-campanhas';
  const nativeConfirm=window.confirm.bind(window);
  const idb=new Promise((ok,ko)=>{
    const r=indexedDB.open(DBN,1);
    r.onupgradeneeded=()=>{ const d=r.result; if(!d.objectStoreNames.contains('docs')) d.createObjectStore('docs'); if(!d.objectStoreNames.contains('blobs')) d.createObjectStore('blobs'); };
    r.onsuccess=()=>ok(r.result); r.onerror=()=>ko(r.error);
  });
  try{ if(navigator.storage&&navigator.storage.persist) navigator.storage.persist(); }catch(e){}
  function run(store,mode,fn){
    return idb.then(d=>new Promise((ok,ko)=>{
      const t=d.transaction(store,mode), s=t.objectStore(store); let res;
      const q=fn(s); if(q&&typeof q==='object'&&'onsuccess' in q) q.onsuccess=()=>{ res=q.result; };
      t.oncomplete=()=>ok(res); t.onerror=()=>ko(t.error); t.onabort=()=>ko(t.error);
    }));
  }
  const clone=v=>v==null?v:JSON.parse(JSON.stringify(v));
  const rid=n=>{ const a=new Uint8Array(n); crypto.getRandomValues(a); return [...a].map(b=>b.toString(16).padStart(2,'0')).join(''); };
  async function listColl(c){
    const out=[];
    await run('docs','readonly',s=>{
      const req=s.openCursor(IDBKeyRange.bound(c+'/',c+'/ '));
      req.onsuccess=()=>{ const cur=req.result; if(!cur) return; const k=String(cur.key); const rest=k.slice(c.length+1); if(!rest.includes('/')){ const v=cur.value; out.push({id:rest,exists:true,data:()=>v,metadata:{fromCache:false,hasPendingWrites:false}}); } cur.continue(); };
    });
    return {docs:out,size:out.length,empty:!out.length,docChanges:()=>[],metadata:{fromCache:false,hasPendingWrites:false}};
  }
  const subs=[];
  const collOf=p=>p.split('/').slice(0,-1).join('/');
  async function notify(c){ for(const s of subs) if(s.c===c){ try{ s.fn(await listColl(c)); }catch(e){ console.error(e); } } }
  function doc(p){
    return {id:p.split('/').pop(),path:p,
      get:async()=>{ const v=await run('docs','readonly',s=>s.get(p)); return {id:p.split('/').pop(),exists:v!==undefined,data:()=>v,metadata:{}}; },
      set:async d=>{ await run('docs','readwrite',s=>s.put(clone(d),p)); notify(collOf(p)); },
      update:async d=>{ const v=await run('docs','readonly',s=>s.get(p)); if(v===undefined) throw {code:'invalid_argument',message:'Documento inexistente'}; await run('docs','readwrite',s=>s.put(Object.assign({},v,clone(d)),p)); notify(collOf(p)); },
      delete:async()=>{ await run('docs','readwrite',s=>s.delete(p)); notify(collOf(p)); },
      collection:sub=>coll(p+'/'+sub)};
  }
  function coll(c){
    return {path:c,get:()=>listColl(c),doc:id=>doc(c+'/'+(id||rid(10))),add:async d=>{ const r=doc(c+'/'+rid(10)); await r.set(d); return r; },
      onSnapshot:(fn)=>{ const s={c,fn}; subs.push(s); listColl(c).then(fn); return ()=>{ const i=subs.indexOf(s); if(i>=0) subs.splice(i,1); }; },
      where(){ return this; },orderBy(){ return this; },limit(){ return this; }};
  }
  const db={doc,collection:coll};
  const assets={
    upload:async(blob)=>{ const id=rid(16); await run('blobs','readwrite',s=>s.put(blob,id)); return {id,url:'/_blob/'+id,sizeBytes:blob.size,contentType:blob.type}; },
    delete:async(id)=>{ await run('blobs','readwrite',s=>s.delete(String(id).replace('/_blob/',''))); return {deleted:true}; },
    list:async()=>({assets:[],usage:{}})
  };
  const downloads={save:async({filename,data})=>{
    const blob=data instanceof Blob?data:new Blob([data]);
    const u=URL.createObjectURL(blob); const a=document.createElement('a'); a.href=u; a.download=String(filename).normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/[\u2013\u2014]/g,'-').replace(/[^\x20-\x7e]/g,''); document.body.appendChild(a); a.click(); a.remove();
    setTimeout(()=>URL.revokeObjectURL(u),10000); return {saved:true};
  }};
  const realFetch=window.fetch.bind(window);
  window.fetch=async(u,...rest)=>{
    const s=String(u&&u.url||u);
    if(s.startsWith('/_blob/')){ const b=await run('blobs','readonly',st=>st.get(s.slice(7))); return b?new Response(b,{status:200}):new Response(null,{status:404}); }
    return realFetch(u,...rest);
  };
  window.claude={use:async n=>({db,assets,downloads})[n]||null};

  // ---------- cópia de segurança (dados + relatórios + PDF) ----------
  const b64=blob=>new Promise(ok=>{ const r=new FileReader(); r.onload=()=>ok(String(r.result)); r.readAsDataURL(blob); });
  async function allEntries(store){
    const out=[]; await run(store,'readonly',s=>{ const req=s.openCursor(); req.onsuccess=()=>{ const c=req.result; if(!c) return; out.push([c.key,c.value]); c.continue(); }; }); return out;
  }
  async function exportBackup(){
    const docs=await allEntries('docs'); const blobs=[];
    for(const [k,b] of await allEntries('blobs')) blobs.push([k,await b64(b)]);
    const d=new Date(), p=n=>String(n).padStart(2,'0');
    await downloads.save({filename:'copia-relatorios-campanhas_'+d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())+'.json',
      data:new Blob([JSON.stringify({app:'relatorios-campanhas',versao:1,criadaEm:d.toISOString(),docs,blobs})],{type:'application/json'})});
  }
  async function importBackup(file){
    const j=JSON.parse(await file.text());
    if(!j||j.app!=='relatorios-campanhas'||!Array.isArray(j.docs)) throw new Error('formato');
    if(!nativeConfirm('Restaurar esta cópia de segurança? Os dados e relatórios atuais neste computador serão substituídos.')) return false;
    await run('docs','readwrite',s=>s.clear()); await run('blobs','readwrite',s=>s.clear());
    await run('docs','readwrite',s=>{ for(const [k,v] of j.docs) s.put(v,k); });
    for(const [k,u] of (j.blobs||[])){ const b=await (await realFetch(u)).blob(); await run('blobs','readwrite',s=>s.put(new Blob([b],{type:'application/pdf'}),k)); }
    return true;
  }
  document.addEventListener('DOMContentLoaded',()=>{
    const host=document.querySelector('header'); if(!host) return;
    const box=document.createElement('div'); box.className='bk';
    box.innerHTML='<button type="button" class="ghost sm" id="bkExp">Cópia de segurança</button><button type="button" class="ghost sm" id="bkImp">Restaurar cópia</button><input type="file" id="bkFile" accept=".json,application/json" hidden>';
    host.appendChild(box);
    const st=document.createElement('style'); st.textContent='.bk{display:flex;gap:6px;flex-wrap:wrap}'; document.head.appendChild(st);
    document.getElementById('bkExp').onclick=()=>exportBackup().catch(e=>{ console.error(e); alert('Não foi possível criar a cópia de segurança.'); });
    document.getElementById('bkImp').onclick=()=>document.getElementById('bkFile').click();
    document.getElementById('bkFile').onchange=async e=>{ const f=e.target.files[0]; e.target.value=''; if(!f) return;
      try{ if(await importBackup(f)) location.reload(); }catch(err){ console.error(err); window.alert('Este ficheiro não é uma cópia de segurança desta aplicação.'); } };
  });
})();

</script>
<title>Relatórios de Campanhas</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Lexend:wght@500;600&family=Source+Sans+3:wght@400;600;700&display=swap">
<link rel="stylesheet" href="https://fonts.googleapis.com/icon?family=Material+Icons">
<style>
:root {
    --button-color: #298BA8; 
    --active-color: #007aff;
    --safe-area-top: env(safe-area-inset-top);
    --safe-area-bottom: env(safe-area-inset-bottom);
}

[data-visible="false"] {
    display: none;
}

div[data-before]:before {
    content: attr(data-before);
}

.unselectable {
    -webkit-touch-callout: none;
    -webkit-user-select: none;
    -khtml-user-select: none;
    -moz-user-select: none;
    -ms-user-select: none;
    user-select: none;
}

.jreadonly {
    pointer-events: none;
}

.jdragging {
    opacity:0.2;
    filter: alpha(opacity=20);
}

.jupload.input {
    position: relative;
    box-sizing: border-box;
    background-size: initial;
    height: 33px;
    min-height: initial;
    padding: 6px;
    padding-right: 30px;
}

.jupload.input:before {
    content: "save";
    font-size: 18px;
    font-family: "Material Icons";
    color: #000;
    position: absolute;
    right: 5px;
}

.jupload:empty:before {
    z-index: 0;
}

.jupload img {
    width: 100%;
} 

.jupload.input img {
    width: initial;
    max-width: 100%;
    height: 100%;
}

.jupload[data-multiple] {
    padding: 10px;
}

.jupload[data-multiple] img {
    height: 70px;
    width: 100px;
    object-fit: cover;
    margin-right: 5px;
    margin-bottom: 5px;
}

.jupload {
    position: relative;
    border: 1px dotted #eee;
    cursor: pointer;
    box-sizing: border-box;
    width: 100%;
    max-width: 100%;
    max-height: 100%;
    min-height: 180px;
}

.jupload:not(.input):before {
    content: "\e2c3"; 
    font-family: "Material Icons";
    font-size: 90px;
    color: #eee;
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    position: absolute;
    z-index: -1;
}

.jupload-item {
    padding-right: 22px;
    border-radius: 1px;
    display: inline-block;
    position: relative;
}

.jphoto {
    position: relative;
    border: 1px dotted #eee;
    cursor: pointer;
    box-sizing: border-box;
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
}

.jphoto:empty:before {
    content: "\e2c3";
    font-family: "Material Icons";
    font-size: 90px;
    color: #eee;
    width: 100%;
    height: 100%;
    text-align: center;
}

.jremove {
    opacity: 0.2;
    filter: alpha(opacity=20);
}

.round img {
    border-radius: 1000px;
}

.jtooltip {
    position: fixed;
    top: 10px;
    left: 10px;
    z-index: 5;

    font-family: initial;
    font-size: 12px;
    color: #000;
    background-color: #fff;
    border: 1px solid black;
    padding: 8px;
    margin: 10px;

    display: block;
    animation: fadeIn 0.5s;
    pointer-events: none;
}

.jtooltip:empty {
    display: none;
}

@keyframes fadeIn {
     0% {
          opacity: 0;
     }
     100% {
          opacity: 1;
     }
}
/** Loading */
.jloading {
    position:fixed;
    z-index:10001;
    width:100%;
    left:0;
    right:0;
    top:0;
    bottom:0;
    background-color: rgba(0,0,0,0.7);
}

.jloading::after {
    content:'';
    display:block;
    margin:0 auto;
    margin-top:50vh;
    width:40px;
    height:40px;
    border-style:solid;
    border-color:white;
    border-top-color:transparent;
    border-width:4px;
    border-radius:50%;
    -webkit-animation: spin .8s linear infinite;
    animation: spin .8s linear infinite;
}

.jloading.spin {
    background-color:transparent;
}

.jloading.spin::after {
    margin:0 auto;
    margin-top:80px;
    border-color:#aaa;
    border-top-color:transparent;
}

/** Animations **/
.fade-in {
    animation: fade-in 2s forwards;
}

.fade-out {
    animation: fade-out 1s forwards;
}

.slide-left-in {
    position: relative;
    animation: slide-left-in 0.4s forwards;
}

.slide-left-out {
    position: relative;
    animation: slide-left-out 0.4s forwards;
}

.slide-right-in {
    position: relative;
    animation: slide-right-in 0.4s forwards;
}

.slide-right-out {
    position: relative;
    animation: slide-right-out 0.4s forwards;
}

.slide-top-in {
    position: relative;
    animation: slide-top-in 0.4s forwards;
}

.slide-top-out {
    position: relative;
    animation: slide-top-out 0.2s forwards;
}

.slide-bottom-in {
    position: relative;
    animation: slide-bottom-in 0.4s forwards;
}

.slide-bottom-out {
    position: relative;
    animation: slide-bottom-out 0.1s forwards;
}

.slide-left-in > div {
    -webkit-transform: translateZ(0px);
    -webkit-transform: translate3d(0,0,0);
}

.slide-left-out > div {
    -webkit-transform: translateZ(0px);
    -webkit-transform: translate3d(0,0,0);
}

.slide-right-in > div {
    -webkit-transform: translateZ(0px);
    -webkit-transform: translate3d(0,0,0);
}

.slide-right-out > div {
    -webkit-transform: translateZ(0px);
    -webkit-transform: translate3d(0,0,0);
}

.spin {
    animation: spin 2s infinite linear;
}

/** Fadein and Fadeout **/
@keyframes fade-in {
    0% { opacity: 0; }
    100% { opacity: 100; }
}

@-webkit-keyframes fade-in {
    0% { opacity: 0; }
    100% { opacity: 100; }
}

@keyframes fade-out {
    0% { opacity: 100; }
    100% { opacity: 0; }
}

@-webkit-keyframes fade-out {
    0% { opacity: 100; }
    100% { opacity: 0; }
}

/** Keyframes Left to Right **/
@keyframes slide-left-in {
    0% { left: -100%; }
    100% { left: 0%; }
}

@-webkit-keyframes slide-left-in {
    0% { left: -100%; }
    100% { left: 0%; }
}
    
@keyframes slide-left-out {
    0% { left: 0%; }
    100% { left: -100%; }
}

@-webkit-keyframes slide-left-out {
    0% { left: 0%; }
    100% { left: -100%; }
}

/** Keyframes Right to Left **/
@keyframes slide-right-in {
    0% { left: 100%; }
    100% { left: 0%; }
}

@-webkit-keyframes slide-right-in
{
    0% { left: 100%; }
    100% { left: 0%; }
}
    
@keyframes slide-right-out {
    0% { left: 0%; }
    100% { left: 100%; }
}

@-webkit-keyframes slide-right-out {
    0% { left: 0%; }
    100% { left: 100%; }
}

/** Keyframes Top to Bottom **/
@keyframes slide-top-in {
    0% { transform: translateY(-100%); }
    100% { transform: translateY(0%); }
}

@-webkit-keyframes slide-top-in {
    0% { transform: translateY(-100%); }
    100% { -webkit-transform: translateY(0%); }
}
    
@keyframes slide-top-out {
    0% { transform: translateY(0%); }
    100% { transform: translateY(-100%); }
}

@-webkit-keyframes slide-top-out {
    0% { -webkit-transform: translateY(0%); }
    100% { -webkit-transform: translateY(-100%); }
}

/** Keyframes Bottom to Top **/
@keyframes slide-bottom-in {
    0% { transform: translateY(100%); }
    100% { transform: translateY(0%); }
}

@-webkit-keyframes slide-bottom-in {
    0% { transform: translateY(100%); }
    100% { -webkit-transform: translateY(0%); }
}
    
@keyframes slide-bottom-out {
    0% { transform: translateY(0%); }
    100% { transform: translateY(100%); }
}

@-webkit-keyframes slide-bottom-out {
    0% { -webkit-transform: translateY(0%); }
    100% { -webkit-transform: translateY(100%); }
}

@-webkit-keyframes spin {
    from {
        -webkit-transform:rotate(0deg);
    }
    to {
        -webkit-transform:rotate(359deg);
    }
}

@keyframes spin {
    from {
        transform:rotate(0deg);
    }
    to {
        transform:rotate(359deg);
    }
}
.jcalendar {
    position:absolute;
    z-index:9000;
    display:none;
    box-sizing:border-box;
    -webkit-touch-callout: none;
    -webkit-user-select: none;
    -khtml-user-select: none;
    -moz-user-select: none;
    -ms-user-select: none;
    user-select: none;
    -webkit-tap-highlight-color: rgba(0,0,0,0);
    -webkit-tap-highlight-color: transparent;
    min-width:280px;
}

.jcalendar.jcalendar-focus {
    display:block;
}

.jcalendar .jcalendar-backdrop {
    position:fixed;
    top:0px;
    left:0px;
    z-index:9000;
    min-width:100%;
    min-height:100%;
    background-color:rgba(0,0,0,0.5);
    border:0px;
    padding:0px;
    display:none;
}

.jcalendar .jcalendar-container {
    position:relative;
    box-sizing:border-box;
}

.jcalendar .jcalendar-content {
    position:absolute;
    z-index:9001;
    -webkit-box-shadow: 1px 1px 5px 0px rgba(0,0,0,0.39);
    -moz-box-shadow: 1px 1px 5px 0px rgba(0,0,0,0.39);
    box-shadow: 1px 1px 5px 0px rgba(0,0,0,0.39);
    background-color:#fff;
}

.jcalendar-header {
    text-align:center;
}

.jcalendar-header span {
    margin-right:4px;
    font-size:1.1em;
    font-weight:bold;
}

.jcalendar-prev {
    cursor:pointer;
    background-image:url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2724%27 height=%2724%27 viewBox=%270 0 24 24%27%3E%3Cpath d=%27M15.41 16.59L10.83 12l4.58-4.59L14 6l-6 6 6 6 1.41-1.41z%27 fill=%27%23000%27 /%3E%3Cpath fill=%27none%27 d=%27M0 0h24v24H0V0z%27/%3E%3C/svg%3E");
    background-position:center;
    background-repeat:no-repeat;
}

.jcalendar-next {
    cursor:pointer;
    background-image:url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2724%27 height=%2724%27 viewBox=%270 0 24 24%27%3E%3Cpath d=%27M8.59 16.59L13.17 12 8.59 7.41 10 6l6 6-6 6-1.41-1.41z%27 fill=%27%23000%27 /%3E%3Cpath fill=%27none%27 d=%27M0 0h24v24H0V0z%27/%3E%3C/svg%3E");
    background-position:center;
    background-repeat:no-repeat;
}

.jcalendar-weekday {
    font-weight: 600;
    background-color: #fcfcfc;
    padding: 14px;
}

.jcalendar-table {
    padding: 10px;
}

.jcalendar-table > table {
    width:100%;
    background-color:#fff;
}

.jcalendar-table > table > thead {
    cursor: pointer;
}

.jcalendar-table thead td {
    padding: 10px;
    height: 40px;
}

.jcalendar-table > table > tbody > tr {
    height: 34px;
}

.jcalendar-table > table > tbody td {
    box-sizing:border-box;
    cursor:pointer;
    padding:9px;
    font-size:0.9em;
}

.jcalendar-table tfoot td {
    padding:10px;
}

.jcalendar-months td, .jcalendar-years td {
    height:24px;
} 

.jcalendar-input {
    padding-right:18px;
    background-image:url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2716%27 height=%2716%27 viewBox=%270 0 24 24%27 fill=%27gray%27%3E%3Cpath d=%27M20 3h-1V1h-2v2H7V1H5v2H4c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 18H4V8h16v13z%27/%3E%3Cpath fill=%27none%27 d=%27M0 0h24v24H0z%27/%3E%3C/svg%3E");
    background-position:top 50% right 5px;
    background-repeat:no-repeat;
    box-sizing: border-box;
}

.jcalendar-done {
    -webkit-box-shadow: 1px 1px 5px 0px rgba(0,0,0,0.39);
    -moz-box-shadow: 1px 1px 5px 0px rgba(0,0,0,0.39);
    box-shadow: 1px 1px 5px 0px rgba(0,0,0,0.39);
    background-color:#fff;
}

.jcalendar-update {
    border:1px solid #ccc;
    background-color:#fff;
    border-radius:4px;
    padding:5px;
    width:100%;
}

.jcalendar-container select {
    width:55px;
    display:inline-block;
    border:0px;
    padding:4px;
    text-align:center;
    font-size:1.1em;
    user-select:none;
    margin-right:10px;
}

.jcalendar-container select:first-child {
    margin-right:2px;
}

.jcalendar-selected {
    background-color:#eee;
}

.jcalendar-reset, .jcalendar-confirm {
    text-transform:uppercase;
    cursor:pointer;
    color: var(--active-color);
}

.jcalendar-controls {
    padding:15px;

    -webkit-box-sizing: border-box;
    box-sizing: border-box;
    vertical-align:middle;

    display: -webkit-box;
    display: -moz-box;
    display: -ms-flexbox;
    display: -webkit-flex;
    display: flex;

    -webkit-flex-flow: row wrap;
    justify-content: space-between;
    align-items:center;
}

.jcalendar-controls div {
    font-weight:bold;
}

.jcalendar-fullsize  {
    position:fixed;
    width:100%;
    top:0px;
    left:0px;
}

.jcalendar-fullsize .jcalendar-content
{
    position:fixed;
    width:100%;
    left:0px;
    bottom:0px;
}

.jcalendar-focus.jcalendar-fullsize .jcalendar-backdrop {
    display:block;
}

.jcalendar-sunday {
    color: red;
}
.jcalendar-disabled {
    color: #ccc;
}

.jcalendar-time {
    display:flex;
}

.jcalendar_warning {
    color: red;
}

.jcalendar-hide-controls .jcalendar-controls {
    display: none;
}

.jcolor {
    display: none;
    outline: none;
    position: absolute;
}

.jcolor-input {
    padding-right: 24px !important;
    background: url("data:image/svg+xml,%0A%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 24 24%27 fill=%27black%27 width=%2718px%27 height=%2718px%27%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3Cpath d=%27M12 3c-4.97 0-9 4.03-9 9s4.03 9 9 9c.83 0 1.5-.67 1.5-1.5 0-.39-.15-.74-.39-1.01-.23-.26-.38-.61-.38-.99 0-.83.67-1.5 1.5-1.5H16c2.76 0 5-2.24 5-5 0-4.42-4.03-8-9-8zm-5.5 9c-.83 0-1.5-.67-1.5-1.5S5.67 9 6.5 9 8 9.67 8 10.5 7.33 12 6.5 12zm3-4C8.67 8 8 7.33 8 6.5S8.67 5 9.5 5s1.5.67 1.5 1.5S10.33 8 9.5 8zm5 0c-.83 0-1.5-.67-1.5-1.5S13.67 5 14.5 5s1.5.67 1.5 1.5S15.33 8 14.5 8zm3 4c-.83 0-1.5-.67-1.5-1.5S16.67 9 17.5 9s1.5.67 1.5 1.5-.67 1.5-1.5 1.5z%27/%3E%3C/svg%3E") top 50% right 4px no-repeat, content-box;
    box-sizing: border-box;
}

.jcolor-content {
    position: absolute;
    z-index: 9000;
    user-select: none;
    -webkit-font-smoothing: antialiased;
    font-size: .875rem;
    letter-spacing: .2px;
    -webkit-border-radius: 4px;
    border-radius: 4px;
    -webkit-box-shadow: 0 8px 10px 1px rgba(0,0,0,0.14), 0 3px 14px 2px rgba(0,0,0,0.12), 0 5px 5px -3px rgba(0,0,0,0.2);
    box-shadow: 0 8px 10px 1px rgba(0,0,0,0.14), 0 3px 14px 2px rgba(0,0,0,0.12), 0 5px 5px -3px rgba(0,0,0,0.2);
    background-color:#fff;
    box-sizing: border-box;
    min-width: 260px;
}

.jmodal .jcolor-content {
    position: fixed;
}

.jcolor-controls {
    display: flex;
    padding: 10px;
    border-bottom: 1px solid #eee;
    margin-bottom: 5px;
}

.jcolor-controls div {
    flex: 1;
    font-size: 1em;
    color: var(--active-color);
    text-transform: uppercase;
    font-weight: bold;
    box-sizing: border-box;
}

.jcolor-content table {
    border-collapse: collapse;
    box-sizing: border-box;
}

.jcolor-focus {
    display:block;
}

.jcolor table {
    width:100%;
    height:100%;
    min-height: 160px;
}

.jcolor td {
    padding: 7px;
}

.jcolor-selected {
    background-repeat:no-repeat;
    background-size: 16px;
    background-position: center;
    background-image: url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2724%27 height=%2724%27 viewBox=%270 0 24 24%27%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3Cpath d=%27M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z%27 fill=%27white%27/%3E%3C/svg%3E");
}

.jcolor-fullscreen {
    position: fixed;
    left: 0px;
    bottom: 0px;
    width:100%;
    max-height: 290px;
    border-radius: 0px;
    box-sizing: border-box;
}

.jcolor-fullscreen .jcolor-controls {
    padding: 15px;
    -webkit-box-shadow: 1px 0px 1px 0px rgba(0,0,0,0.39);
    -moz-box-shadow: 1px 0px 1px 0px rgba(0,0,0,0.39);
    box-shadow: 1px 0px 1px 0px rgba(0,0,0,0.39);
}

.jcolor-reset {
    text-align: left;
}

.jcolor-close {
    text-align: right;
}

.jcolor-backdrop {
    position: fixed;
    top: 0px;
    left: 0px;
    min-width: 100%;
    min-height: 100%;
    background-color: rgba(0,0,0,0.5);
    border: 0px;
    padding: 0px;
    z-index: 8000;
    display: none;
    
  -webkit-touch-callout: none; /* iOS Safari */
    -webkit-user-select: none; /* Safari */
     -khtml-user-select: none; /* Konqueror HTML */
       -moz-user-select: none; /* Firefox */
        -ms-user-select: none; /* Internet Explorer/Edge */
            user-select: none; /* Non-prefixed version, currently
                                  supported by Chrome and Opera */
}

.jcolor-content .jtabs-content {
    padding: 7px;
}

.jcolor-grid tr:first-child > td:first-child {
    border-top-left-radius: 3px;
}

.jcolor-grid tr:first-child > td:last-child {
    border-top-right-radius: 3px;
}

.jcolor-grid tr:last-child > td:first-child {
    border-bottom-left-radius: 3px;
}

.jcolor-grid tr:last-child > td:last-child {
    border-bottom-right-radius: 3px;
}

.jcolor-hsl {
    box-sizing: border-box;
}

.jcolor-hsl > div {
    height: 100%;
    position: relative;
}

.jcolor-hsl canvas {
    display: block;
    border-radius: 4px;
    -webkit-user-drag: none;
}

.jcolor-point {
    height: 5px;
    width: 5px;
    background-color: #000;
    position: absolute;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    border-radius: 50%;
}

.jcolor-sliders {
    padding: 10px 20px 10px 10px;
}

.jcolor-sliders input {
    -webkit-appearance: none;

    height: 12px;
    width: 80%;

    background: #d3d3d3;
    opacity: 1;

    border-radius: 30px;
    outline: none;
}

.jcolor-sliders-input-subcontainer {
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.jcolor-sliders-input-container {
    margin-top: 4px;
    line-height: 0.8em;
    text-align: left;
}

.jcolor-sliders-input-container > label {
    font-size: 10px;
    text-transform: uppercase;
    color: #bbbbbd;
}

.jcolor-sliders-input-subcontainer > input {
    border: 0px;
    padding: 1px;
}

.jcolor-sliders-input-container input::-webkit-slider-thumb {
    -webkit-appearance: none;
    height: 12px;
    width: 12px;
    border-radius: 50%;
    background: #000;
    border: 2px solid #fff;
    cursor: pointer;
}

.jcolor-sliders-input-container input::-moz-range-thumb {
    -webkit-appearance: none;
    height: 12px;
    width: 12px;
    border-radius: 50%;
    background: #000;
    border: 2px solid #fff;
    cursor: pointer;
}

.jcolor-sliders-final-color {
    padding: 6px;
    user-select: all;
    margin-top: 10px;
    text-align: center;
}

.jcolor-sliders-final-color > div:nth-child(2) {
    width: 71px;
    text-transform: uppercase;
}

.jcolor .jtabs .jtabs-headers-container .jtabs-controls {
    display: none !important;
}

.jcolor .jtabs .jtabs-headers-container {
    display: flex !important;
    justify-content: center;
    padding: 4px;
}

.jcolor .jtabs-headers > div:not(.jtabs-border) {
    padding: 2px !important;
    padding-left: 15px !important;
    padding-right: 15px !important;
    font-size: 0.8em;
}
.jcontextmenu {
    position:fixed;
    z-index:10000;
    background:#fff;
    color: #555;
    font-size: 11px;
    -webkit-user-select: none;
    -moz-user-select: none;
    user-select: none;
    -webkit-box-shadow: 2px 2px 2px 0px rgba(143, 144, 145, 1);
    -moz-box-shadow: 2px 2px 2px 0px rgba(143, 144, 145, 1);
    box-shadow: 2px 2px 2px 0px rgba(143, 144, 145, 1);
    border: 1px solid #C6C6C6;
    padding: 0px;
    padding-top:4px;
    padding-bottom:4px;
    margin:0px;
    outline:none;
    display:none;
}

.jcontextmenu.jcontextmenu-focus {
    display:inline-block;
}

.jcontextmenu > div {
    box-sizing: border-box;
    display: flex;
    padding: 8px 8px 8px 32px;
    width: 250px;
    position: relative;
    cursor: default;
    font-size: 11px;
    font-family:sans-serif;
    text-align: left;
    -webkit-box-align: center;
    align-items: center;
}

.jcontextmenu > div::before {
    content: attr(data-icon);
    font-family: 'Material Icons' !important;
    font-size: 15px;
    position: absolute;
    left: 9px;
    line-height: 24px;
}

.jcontextmenu.symbols > div::before {
    font-family: 'Material Symbols Outlined' !important;
}

.jcontextmenu > div.header {
    display: none;
}

.jcontextmenu > div a {
    color: #555;
    text-decoration: none;
    flex: 1;
    cursor: pointer;
}

.jcontextmenu > div span {
    margin-right:10px;
}

.jcontextmenu .jcontextmenu-disabled a {
    color: #ccc;
}

.jcontextmenu .jcontextmenu-disabled::before {
    color: #ccc;
}

.jcontextmenu > div:hover {
    background: #ebebeb;
}

.jcontextmenu hr {
    border: 1px solid #e9e9e9;
    border-bottom: 0;
    margin-top:5px;
    margin-bottom:5px;
}

.jcontextmenu > hr:hover {
    background: transparent;
}

.jcontextmenu .jcontextmenu {
    top: 4px;
    left: 99%;
    opacity: 0;
    position: absolute;
}

.jcontextmenu > div:hover > .jcontextmenu {
    display: block;
    opacity: 1;
    -webkit-transform: translate(0, 0) scale(1);
    transform: translate(0, 0) scale(1);
    pointer-events: auto;
}

@media only screen and (max-width: 420px) {
    .jcontextmenu {
        top: initial !important;
        left: 0px !important;
        bottom: 0px !important;
        width: 100vw;
        height: 260px;
        overflow: scroll;
        animation: slide-bottom-in 0.4s forwards;
        padding-top: 0px;
    }
    .jcontextmenu div {
        width: 100%;
        text-align: center;
        border-bottom: 1px solid #ccc;
        padding: 15px;
    }
    .jcontextmenu > div.header {
        background-color: lightgray;
        padding: 5px;
        top: 0px;
        position: sticky;
        z-index: 2;
    }
    .jcontextmenu > div.header > a.title {
        text-align: left;
    }

    .jcontextmenu > div.header > a.close {
        text-align: right;
    }
    .jcontextmenu a {
        font-size: 1.4em;
        text-transform: uppercase;
    }
    .jcontextmenu span {
        display: none;
    }
    .jcontextmenu span {
        display: none;
    }
    .jcontextmenu hr {
        display: none;
    }
}

.jdropdown {
    cursor:pointer;
    -webkit-touch-callout: none;
    -webkit-user-select: none;
    -khtml-user-select: none;
    -moz-user-select: none;
    -ms-user-select: none;
    user-select: none;
    box-sizing: border-box;
    background:#fff;
    -webkit-tap-highlight-color: transparent;
    display: inline-block;
}

.jdropdown-backdrop {
    position:fixed;
    top:0px;
    left:0px;
    min-width:100%;
    min-height:100%;
    background-color:rgba(0,0,0,0.5);
    border:0px;
    padding:0px;
    z-index:8000;
    display:none;
}

.jdropdown[disabled] {
    opacity: 0.5;
    pointer-events: none;
}

.jdropdown-focus {
    position:relative;
}

.jdropdown-focus .jdropdown-container {
    transform: translate3d(0,0,0);
}

.jdropdown-default.jdropdown-focus .jdropdown-header {
    outline:auto 5px -webkit-focus-ring-color;
}

.jdropdown-default.jdropdown-focus .jdropdown-header.jdropdown-add {
    background-image: url("data:image/svg+xml,%0A%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 24 24%27 fill=%27gray%27 width=%2724px%27 height=%2724px%27%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3Cpath d=%27M19 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-2 10h-4v4h-2v-4H7v-2h4V7h2v4h4v2z%27/%3E%3C/svg%3E");
}

.jdropdown-container-header {
    padding:0px;
    margin:0px;
    position:relative;
    box-sizing: border-box;
}

.jdropdown-header {
    width:100%;
    appearance: none;
    background-repeat: no-repeat;
    background-position:top 50% right 5px;
    background-image: url("data:image/svg+xml,%0A%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2724%27 height=%2724%27 viewBox=%270 0 24 24%27%3E%3Cpath fill=%27none%27 d=%27M0 0h24v24H0V0z%27/%3E%3Cpath d=%27M7 10l5 5 5-5H7z%27 fill=%27gray%27/%3E%3C/svg%3E");
    text-overflow: ellipsis;
    cursor:pointer;
    box-sizing: border-box;
    -webkit-appearance: none;
    -moz-appearance: none;
    padding-right:30px !important;
}

.jdropdown-insert-button {
    font-size: 1.4em;
    text-transform: uppercase;
    position:absolute;
    right: 30px;
    top: 4px;
    display:none;
}

.jdropdown-container {
    min-width: inherit;
    transform: translate3d(-10000px,0,0);
    position:absolute;
    z-index:9001;
}

.jdropdown-close {
    display:none;
    font-size:1em;
    color: var(--active-color);
    text-transform:uppercase;
    text-align:right;
    padding:12px;
    font-weight:bold;
}

.jdropdown-content {
    min-width:inherit;
    margin:0px;
    box-sizing:border-box;
}

.jdropdown-content:empty {
}

.jdropdown-item {
    white-space: nowrap;
    text-align: left;
    text-overflow: ellipsis;
    overflow-x: hidden;
    color: #000;
    display: flex;
    align-items: center;
}

.jdropdown-description {
    text-overflow: ellipsis;
    overflow: hidden;
    line-height: 1.5em;
}

.jdropdown-image {
    margin-right:10px;
    width: 32px;
    height: 32px;
    border-radius:20px;
}

.jdropdown-image-small {
    width:24px;
    height:24px;
}

.jdropdown-icon {
    margin-right:10px;
    font-size: 30px;
    margin-left: -5px;
}

.jdropdown-icon-small {
    font-size: 24px;
    margin-left: 0px;
}

.jdropdown-title {
    font-size: 0.7em;
    text-overflow: ellipsis;
    overflow-x: hidden;
    display: block;
}

/** Default visual **/

.jdropdown-default .jdropdown-header {
    border:1px solid #ccc;
    padding:5px;
    padding-left:10px;
    padding-right:16px;
}

.jdropdown-default .jdropdown-container {
    background-color:#fff;
}

.jdropdown-default.jdropdown-focus.jdropdown-insert .jdropdown-header {
    padding-right:50px;
}

.jdropdown-default.jdropdown-focus.jdropdown-insert .jdropdown-insert-button {
    display:block;
}

.jdropdown-default .jdropdown-content
{
    min-width:inherit;
    border:1px solid #8fb1e3;
    margin:0px;
    background-color:#fff;
    box-sizing:border-box;
    min-height:10px;
    max-height:215px;
    overflow-y:auto;
}

.jdropdown-default .jdropdown-item
{
    padding:4px;
    padding-left:8px;
    padding-right:40px;
}

.jdropdown-default .jdropdown-item:hover
{
    background-color:#1f93ff;
    color:#fff;
}

.jdropdown-default .jdropdown-cursor
{
    background-color:#eee;
}

.jdropdown-default .jdropdown-selected
{
    background-image: url(data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0Ij48cGF0aCBkPSJNMCAwaDI0djI0SDB6IiBmaWxsPSJub25lIiAvPjxwYXRoIGQ9Ik05IDE2LjE3TDQuODMgMTJsLTEuNDIgMS40MUw5IDE5IDIxIDdsLTEuNDEtMS40MXoiIGZpbGw9IndoaXRlIiAvPjwvc3ZnPgo=);
    background-repeat:no-repeat;
    background-position:top 50% right 5px;
    background-color:#1f93ff;
    color:#fff;
}

.jdropdown-default .jdropdown-group {
    margin-top:5px;
}

.jdropdown-default .jdropdown-group .jdropdown-item {
    padding-left:16px;
}

.jdropdown-default .jdropdown-group-name {
    padding-left: 8px;
    font-weight: bold;
    text-align: left;
}

.jdropdown-default .jdropdown-reset_ {
    content:'x';
    position:absolute;
    top:0;
    right:0;
    margin:5px;
    margin-right:10px;
    font-size:12px;
    width:12px;
    cursor:pointer;
    text-shadow: 0px 0px 5px #fff;
    display:none;
    line-height: 1.8em;
}

.jdropdown-default.jdropdown-focus .jdropdown-reset_ {
    display:block;
}

/** Default render for mobile **/

.jdropdown-picker.jdropdown-focus .jdropdown-backdrop {
    display:block;
}

.jdropdown-picker .jdropdown-header {
    outline: none;
}

.jdropdown-picker .jdropdown-container
{
    position:fixed;
    bottom:0px;
    left:0px;
    border-bottom:1px solid #e6e6e8;
    width:100%;
    background-color:#fff;
    box-sizing: border-box;
}

.jdropdown-picker .jdropdown-close
{
    -webkit-box-shadow: 0px -1px 5px 0px rgba(0,0,0,0.39);
    -moz-box-shadow: 0px -1px 5px 0px rgba(0,0,0,0.39);
    box-shadow: 0px -1px 5px 0px rgba(0,0,0,0.39);
    background-color:#fff;
    display:block;
}

.jdropdown-picker .jdropdown-content
{
    overflow-y:scroll;
    height:280px;
    background-color:#fafafa;
    border-top:1px solid #e6e6e8;
}

.jdropdown-picker .jdropdown-group-name
{
    font-size: 1em;
    text-transform: uppercase;
    padding-top:10px;
    padding-bottom:10px;
    display: block;
    border-bottom: 1px solid #e6e6e8;
    padding-left:20px;
    padding-right:20px;
    text-align:center;
    font-weight:bold;
}

.jdropdown-picker .jdropdown-item
{
    font-size: 1em;
    text-transform: uppercase;
    padding-top:10px;
    padding-bottom:10px;
    border-bottom: 1px solid #e6e6e8;
    padding-left:20px;
    padding-right:20px;
}

.jdropdown-picker .jdropdown-selected
{
    background-image: url(data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0Ij48cGF0aCBkPSJNMCAwaDI0djI0SDB6IiBmaWxsPSJub25lIiAvPjxwYXRoIGQ9Ik05IDE2LjE3TDQuODMgMTJsLTEuNDIgMS40MUw5IDE5IDIxIDdsLTEuNDEtMS40MXoiIGZpbGw9IndoaXRlIiAvPjwvc3ZnPgo=);
    background-repeat:no-repeat;
    background-position:top 50% right 15px;
    background-color:#1f93ff;
    color:#fff;
}

.jdropdown-picker .jdropdown-cursor
{
    background-color:#1f93ff;
    color:#fff;
}

/** Default render for mobile searchbar **/

.jdropdown-searchbar.jdropdown-focus
{
    position:fixed;
    top:0px !important;
    left:0px !important;
    width:100% !important;
    height:100% !important;
    background-color:#fafafa;
    padding:0px;
    z-index:9001;
    overflow-y:scroll;
    will-change: scroll-position;
    -webkit-overflow-scrolling: touch;
}

.jdropdown-searchbar.jdropdown-focus .jdropdown-container-header
{
    position: fixed;
    top: 0px;
    left: 0px;
    z-index: 9002;
    padding: 6px;
    background-color:#fff;
    box-shadow: 0 1px 2px rgba(0,0,0,.1);
    width: 100%;
    height: 40px;
}

.jdropdown-searchbar.jdropdown-focus .jdropdown-header
{
    border: 0px !important;
    background-position-x: 0% !important;
    background-position-y: 40% !important;
    background-repeat: no-repeat;
    background-image: url(data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0Ij48cGF0aCBkPSJNMTUuNSAxNGgtLjc5bC0uMjgtLjI3QzE1LjQxIDEyLjU5IDE2IDExLjExIDE2IDkuNSAxNiA1LjkxIDEzLjA5IDMgOS41IDNTMyA1LjkxIDMgOS41IDUuOTEgMTYgOS41IDE2YzEuNjEgMCAzLjA5LS41OSA0LjIzLTEuNTdsLjI3LjI4di43OWw1IDQuOTlMMjAuNDkgMTlsLTQuOTktNXptLTYgMEM3LjAxIDE0IDUgMTEuOTkgNSA5LjVTNy4wMSA1IDkuNSA1IDE0IDcuMDEgMTQgOS41IDExLjk5IDE0IDkuNSAxNHoiIGZpbGw9IiNlNmU2ZTgiLz48cGF0aCBkPSJNMCAwaDI0djI0SDB6IiBmaWxsPSJub25lIi8+PC9zdmc+);
    padding-left: 30px !important;
    padding-right: 60px !important;
}

.jdropdown-searchbar.jdropdown-focus .jdropdown-close
{
    display:block;
}

.jdropdown-searchbar .jdropdown-header {
    outline: none;
}

.jdropdown-searchbar .jdropdown-container
{
    margin-top: 40px;
    width:100%;
}

.jdropdown-searchbar .jdropdown-close
{
    position:fixed;
    top:0px;
    right:0px;
}

.jdropdown-searchbar .jdropdown-content
{
    margin-top:10px;
}

.jdropdown-searchbar .jdropdown-group
{
    margin-top:10px;
    margin-bottom:15px;
    background-color:#fff;
}

.jdropdown-searchbar .jdropdown-group-name
{
    border-top: 1px solid #e6e6e8;
    border-bottom: 1px solid #e6e6e8;
    padding:10px;
    padding-left:12px;
    font-weight:bold;
}

.jdropdown-searchbar .jdropdown-group-arrow
{
    float:right;
    width:24px;
    height:24px;
    background-repeat:no-repeat;
}

.jdropdown-searchbar .jdropdown-group-arrow-down
{
    background-image: url(data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0Ij48cGF0aCBkPSJNNy40MSA4LjU5TDEyIDEzLjE3bDQuNTktNC41OEwxOCAxMGwtNiA2LTYtNiAxLjQxLTEuNDF6Ii8+PHBhdGggZmlsbD0ibm9uZSIgZD0iTTAgMGgyNHYyNEgwVjB6Ii8+PC9zdmc+);
}

.jdropdown-searchbar .jdropdown-group-arrow-up
{
    background-image: url(data:image/svg+xml;base64,CjxzdmcgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB3aWR0aD0iMjQiIGhlaWdodD0iMjQiIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTcuNDEgMTUuNDFMMTIgMTAuODNsNC41OSA0LjU4TDE4IDE0bC02LTYtNiA2eiIvPjxwYXRoIGQ9Ik0wIDBoMjR2MjRIMHoiIGZpbGw9Im5vbmUiLz48L3N2Zz4=);
}

.jdropdown-searchbar .jdropdown-item
{
    padding-top:10px;
    padding-bottom:10px;
    border-bottom: 1px solid #e6e6e8;
    padding-left:15px;
    padding-right:40px;
    background-color:#fff;
    font-size:0.9em;
}

.jdropdown-searchbar .jdropdown-description {
    text-overflow: ellipsis;
    overflow: hidden;
    max-width: calc(100% - 20px);
}

.jdropdown-searchbar .jdropdown-content > .jdropdown-item:first-child
{
    border-top: 1px solid #e6e6e8;
}

.jdropdown-searchbar .jdropdown-selected
{
    background-image: url(data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0Ij48cGF0aCBkPSJNMCAwaDI0djI0SDB6IiBmaWxsPSJub25lIi8+PHBhdGggZD0iTTkgMTYuMTdMNC44MyAxMmwtMS40MiAxLjQxTDkgMTkgMjEgN2wtMS40MS0xLjQxeiIgZmlsbD0iIzAwN2FmZiIvPjwvc3ZnPg==);
    background-repeat:no-repeat;
    background-position:top 50% right 15px;
}

/** List render **/

.jdropdown-list
{
}

.jdropdown-list .jdropdown-container
{
    display:block;
}

.jdropdown-list .jdropdown-header
{
    display:none;
}

.jdropdown-list .jdropdown-group
{
    background-color:#fff;
}

.jdropdown-list .jdropdown-group-name
{
    border-bottom: 1px solid #e6e6e8;
    padding-top:10px;
    padding-bottom:10px;
    font-weight:bold;
}

.jdropdown-list .jdropdown-item
{
    padding-top:10px;
    padding-bottom:10px;
    border-bottom: 1px solid #e6e6e8;
    padding-left:10px;
    padding-right:40px;
    background-color:#fff;
}

.jdropdown-list .jdropdown-selected
{
    background-image: url(data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0Ij48cGF0aCBkPSJNMCAwaDI0djI0SDB6IiBmaWxsPSJub25lIi8+PHBhdGggZD0iTTkgMTYuMTdMNC44MyAxMmwtMS40MiAxLjQxTDkgMTkgMjEgN2wtMS40MS0xLjQxeiIgZmlsbD0iIzAwN2FmZiIvPjwvc3ZnPg==);
    background-repeat:no-repeat;
    background-position:top 50% right 10px;
}

@media only screen and (max-width : 800px)
{
    .jdropdown-list {
        width:100% !important;
        border:0px;
        padding:0px;
    }

    .jdropdown-list .jdropdown-container {
        min-width:100%;
    }

    .jdropdown-searchbar.jdropdown-focus .jdropdown-description {
        text-transform: uppercase;
    }
}

.app .jdropdown-item {
    text-transform:uppercase;
}

.jdropdown-create-container {
    margin: 10px;
    border: 1px solid #ccc;
    border-radius: 2px;
    padding: 6px;
}

.jdropdown-color {
    background-color: #fff;
    border: 1px solid transparent;
    border-radius: 12px;
    width: 12px;
    height: 12px;
    margin-right: 6px;
}

.jdropdown-item[data-disabled] {
    opacity: 0.5;
    pointer-events: none;
}
.jeditor-container {
    border:1px solid #ccc;
    box-sizing: border-box;
}

.jeditor-container.with-margin {
    background-color: #f2f2f2;
    max-width: 1200px;
}

.jeditor-dragging {
     border:1px dashed #000;
}

.jeditor {
    outline:none;
    word-break: break-word;
}

.jeditor-container.with-margin .jeditor {
    background-color: #fff;
    margin: 80px;
    min-height: 800px;
    padding: 80px;
    max-width: 800px;
}

.jeditor[data-placeholder]:empty:before {
    content: attr(data-placeholder);
    color: lightgray;
}

/** Snippet **/

.jsnippet {
    margin-top:15px;
    cursor:pointer;
    border: 1px solid #ccc;
    position:relative;
}

.jsnippet:focus {
    outline: none;
}

.jsnippet img {
    width:100%;
}

.jsnippet .jsnippet-title {
    padding:15px;
    font-size:1.4em;
}

.jsnippet .jsnippet-description {
    padding-left:15px;
    padding-right:15px;
    font-size:1em;
}

.jsnippet .jsnippet-host {
    padding:15px;
    text-transform:uppercase;
    font-size:0.8em;
    color:#777;
    text-align:right;
}

.jsnippet .jsnippet-url {
    display:none;
}

.jeditor .jsnippet:after {
    content: 'close';
    font-family: 'Material icons';
    font-size: 24px;
    width: 24px;
    height: 24px;
    line-height: 24px;
    cursor: pointer;
    text-shadow: 0px 0px 2px #fff;
    position: absolute;
    top: 12px;
    right: 12px;
}

.jsnippet * {
    -webkit-user-select: none;
    -khtml-user-select: none;
    -moz-user-select: none;
    -o-user-select: none;
    user-select: none;

    -webkit-user-drag: none;
    -khtml-user-drag: none;
    -moz-user-drag: none;
    -o-user-drag: none;
}

.jeditor img {
    border:2px solid transparent;
    box-sizing: border-box;
}

.jeditor img.resizing {
    -webkit-user-select: none;
    -khtml-user-select: none;
    -moz-user-select: none;
    -o-user-select: none;
    user-select: none;

    -webkit-user-drag: none;
    -khtml-user-drag: none;
    -moz-user-drag: none;
    -o-user-drag: none;
}

.jeditor img:focus {
    border: 2px solid #0096FD;
    outline: #0096FD;
}

.jeditor .pdf {
    background-image: url("data:image/svg+xml,%3Csvg version=%271.1%27 id=%27Layer_1%27 xmlns=%27http://www.w3.org/2000/svg%27 xmlns:xlink=%27http://www.w3.org/1999/xlink%27 x=%270px%27 y=%270px%27 viewBox=%270 0 512 512%27 style=%27enable-background:new 0 0 512 512;%27 xml:space=%27preserve%27%3E%3Cpath style=%27fill:%23C30B15;%27 d=%27M511.344,274.266C511.77,268.231,512,262.143,512,256C512,114.615,397.385,0,256,0S0,114.615,0,256 c0,117.769,79.53,216.949,187.809,246.801L511.344,274.266z%27/%3E%3Cpath style=%27fill:%2385080E;%27 d=%27M511.344,274.266L314.991,77.913L119.096,434.087l68.714,68.714C209.522,508.787,232.385,512,256,512 C391.243,512,501.976,407.125,511.344,274.266z%27/%3E%3Cpolygon style=%27fill:%23FFFFFF;%27 points=%27278.328,333.913 255.711,77.913 119.096,77.913 119.096,311.652 %27/%3E%3Cpolygon style=%27fill:%23E8E6E6;%27 points=%27392.904,311.652 392.904,155.826 337.252,133.565 314.991,77.913 255.711,77.913 256.067,333.913 %27/%3E%3Cpolygon style=%27fill:%23FFFFFF;%27 points=%27314.991,155.826 314.991,77.913 392.904,155.826 %27/%3E%3Crect x=%27119.096%27 y=%27311.652%27 style=%27fill:%23FC0F1A;%27 width=%27273.809%27 height=%27122.435%27/%3E%3Cg%3E%3Cpath style=%27fill:%23FFFFFF;%27 d=%27M204.871,346.387c13.547,0,21.341,6.659,21.341,18.465c0,12.412-7.795,19.601-21.341,19.601h-9.611 v14.909h-13.471v-52.975L204.871,346.387L204.871,346.387z M195.26,373.858h8.93c5.904,0,9.308-2.952,9.308-8.552 c0-5.525-3.406-8.324-9.308-8.324h-8.93V373.858z%27/%3E%3Cpath style=%27fill:%23FFFFFF;%27 d=%27M257.928,346.387c16.649,0,28.152,10.746,28.152,26.487c0,15.666-11.655,26.488-28.683,26.488 h-22.25v-52.975H257.928z M248.619,388.615h9.611c8.249,0,14.151-6.357,14.151-15.665c0-9.384-6.205-15.817-14.757-15.817h-9.006 V388.615z%27/%3E%3Cpath style=%27fill:%23FFFFFF;%27 d=%27M308.563,356.982v12.26h23.763v10.596h-23.763v19.525h-13.471v-52.975h39.277v10.595h-25.806 V356.982z%27/%3E%3C/g%3E%3C/svg%3E%0A");
    background-repeat: no-repeat;
    background-size: cover;
    width:60px;
    height:60px;
}

.jeditor-toolbar {
    width: fit-content;
    max-width: 100%;
    box-sizing: border-box;
    margin: 10px;
}

.toolbar-on-top .jeditor-toolbar {
    width: initial;
    margin: 0px;
    box-shadow: 1px 1px 2px rgb(0 0 0 / 10%);
    display: block;
}

.toolbar-on-top .jeditor {
    padding: 15px;
}

.toolbar-on-top .jtoolbar .material-icons {
    font-size: 24px;
    transform: initial;
    margin: 4px;
}

.toolbar-on-top .jtoolbar .jpicker-header {
    font-size: 1em;
    margin-top: 4px;
    margin-bottom: 4px;
}

.jeditor table {
    border-collapse: collapse;
}

.jeditor table td {
    border: 1px solid #bbb;
    height: 2em;
}

.jeditor table td:focus {
    border: 1px solid blue;
}

.jeditor .line-break {
    border-top: 1px dashed #ccc;
    display: flex;
    justify-content: center;
    pointer-events: none;
}

.jeditor .line-break:before {
    content: 'New page';
    background-color: #fff;
    color: #ccc;
    margin: -1em;
    padding: 6px;
    position: absolute;
}
.jfloating {
    position:fixed;
    bottom:0px;
    right:0px;
    margin-right:5px;

    -webkit-box-shadow: 0 2px 10px rgba(0,0,0,.2);
    -moz-box-shadow: 0 2px 10px rgba(0,0,0,.2);
    border:1px solid #ccc;
    background-color:#fff;
    box-sizing: border-box;
    padding-top:50px !important;
    z-index:9002;
    border-radius: 8px;
}

.jfloating.jfloating-big {
    width: 510px !important;
    height: 472px !important;
}

.jfloating.jfloating-small {
    width: 300px !important;
    height: 320px !important;
}

.jfloating.jfloating-large {
    width: 600px !important;
    height: 600px !important;
}

.jfloating:before {
    position:absolute;
    top:0;
    left:0;
    width:100%;
    content:attr(title);
    padding:15px;
    box-sizing: border-box;
    font-size:1.2em;
    box-shadow: 1px 1px 3px rgba(0,0,0,.2);
    background-color: #fff;
    border-radius: 8px 8px 0px 0px;
    background-color: #404040;
    font-size: .93rem;
    font-weight: 600;
    color: white;
    letter-spacing: .5px;
}

.jfloating:after {
    content:'';
    background-image: url("data:image/svg+xml,%0A%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2724%27 height=%2724%27 viewBox=%270 0 24 24%27%3E%3Cpath fill=%27%23FFF%27 d=%27M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z%27/%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3C/svg%3E");
    position:absolute;
    top:0;
    right:0;
    margin:14px;
    font-size:24px;
    width:24px;
    height:24px;
    cursor:pointer;
    text-shadow: 0px 0px 5px #fff;
}

.jfloating_content {
    padding:20px;
    overflow-y:auto;
    max-height:100%;
    box-sizing: border-box;
    height: -webkit-fill-available;
}

.jfloating.jfloating-minimized {
    height: 50px !important;
}

.jfloating.jfloating-minimized .jfloating_content {
    display: none;
}

.jmodal {
    position:fixed;
    top:50%;
    left:50%;
    width:60%;
    height:60%;
    -webkit-box-shadow: 0 2px 12px rgba(0,0,0,.2);
    -moz-box-shadow: 0 2px 12px rgba(0,0,0,.2);
    border:1px solid #ccc;
    background-color:#fff;
    transform: translate(-50%, -50%);
    box-sizing: border-box;
    z-index:9002;
    border-radius: 4px;
    display: flex;
    flex-direction: column;
}

.jmodal_title {
    padding: 20px;
    height: 70px;
    box-sizing: border-box;
    font-size: 1.4em;
    background-color: #fff;
    border-radius: 8px 8px 0px 0px;
    pointer-events: none;
    display: flex;
    -webkit-align-items: center;
    -webkit-box-align: center;
    align-items: center;
    border-bottom: 1px solid #eee;
}

.jmodal_title > div {
    font-size: 1.4em;
}

.jmodal_title[data-icon]:before {
    content: attr(data-icon);
    font-family: 'Material Icons' !important;
    width: 24px;
    height: 24px;
    font-size: 24px;
    margin-right: 10px;
    line-height: 24px;
}

.jmodal_content {
    padding: 20px;
    overflow-y: auto;
    height: 100%;
    box-sizing: border-box;
    scrollbar-width: thin;
    scrollbar-color: #333 transparent;
}

.jmodal_title:empty {
    display: none;
}

.jmodal_title:empty + .jmodal_content {
    height: 100%;
}

.jmodal_content::-webkit-scrollbar {
    height: 12px;
}

.jmodal_content::-webkit-scrollbar {
    width: 12px;
}

.jmodal_content::-webkit-scrollbar-track {
    border: 1px solid #fff;
    background: #eee;
}

.jmodal_content::-webkit-scrollbar-thumb {
    border: 1px solid #fff;
    background: #888;
}

.jmodal:after {
    content: '';
    background-image: url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2724%27 height=%2724%27 viewBox=%270 0 24 24%27%3E%3Cpath d=%27M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z%27/%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3C/svg%3E");
    position: absolute;
    top: 0;
    right: 0;
    margin: 25px;
    font-size: 24px;
    width: 24px;
    height: 24px;
    cursor: pointer;
    text-shadow: 0px 0px 5px #fff;
}

.jmodal_fullscreen {
    width: 100% !important;
    height: 100% !important;
    top: 0px;
    left: 0px;
    transform: none;
    border: 0px;
    border-radius: 0px;
}

.jmodal_backdrop {
    position: fixed;
    top: 0px;
    left: 0px;
    min-width: 100%;
    min-height: 100%;
    background-color: rgba(0,0,0,0.2);
    border: 0px;
    padding: 0px;
    z-index: 8000;
    display: none;

  -webkit-touch-callout: none; /* iOS Safari */
    -webkit-user-select: none; /* Safari */
     -khtml-user-select: none; /* Konqueror HTML */
       -moz-user-select: none; /* Firefox */
        -ms-user-select: none; /* Internet Explorer/Edge */
            user-select: none; /* Non-prefixed version, currently
                                  supported by Chrome and Opera */
}

.jmodal_content .jcalendar .jcalendar-content,
.jmodal_content .jdropdown-container {
    position: fixed;
}

.jnotification {
    position: fixed;
    z-index: 10000;
    -webkit-box-sizing: border-box;
    box-sizing: border-box;
    padding: 10px;
    bottom: 0px;
}

.jnotification-container {
    -webkit-box-shadow: 0px 2px 15px -5px rgba(0, 0, 0, 0.7);
    box-shadow: 0px 2px 15px -5px rgba(0, 0, 0, 0.7);
    padding: 12px;
    border-radius: 8px;

    background-color: #000;
    background: rgba(92,92,92,1);
    background: linear-gradient(0deg, rgba(92,92,92,1) 0%, rgba(77,77,77,1) 100%);
    color: #fff;
    width: 320px;
    margin: 30px;
    padding: 20px;
}

.jnotification-close {
    content: '';
    background-image: url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2720%27 height=%2720%27 viewBox=%270 0 24 24%27 fill=%27white%27%3E%3Cpath d=%27M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z%27/%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3C/svg%3E");
    font-size: 20px;
    width: 20px;
    height: 20px;
    cursor: pointer;
}

.jnotification-title {
    font-weight: bold;
}

.jnotification-header {
    display: flex;
    padding-bottom: 5px;
}

.jnotification-header:empty {
    display: none;
}

.jnotification-image {
    margin-right: 5px;
}

.jnotification-image:empty {
    display: none;
}

.jnotification-image img {
    width: 24px;
}

.jnotification-name {
    text-transform: uppercase;
    font-size: 0.9em;
    flex: 1;
    letter-spacing: 0.1em;
}

.jnotification-error .jnotification-container {
    background: rgb(182,38,6);
    background: linear-gradient(0deg, rgba(170,41,13,1) 0%, rgba(149,11,11,1) 100%);
}

@media (max-width: 800px) {
    .jnotification {
        top: calc(0px + var(--safe-area-top));
        width: 100%;
    }
    .jnotification-container {
        background: rgba(255,255,255,0.95);
        border: 1px solid #eee;
        color: #444;
        margin: 0px;
        width: initial;
    }
    .jnotification-error .jnotification-container {
        background: rgba(255,255,255,0.95);
        color: #790909;
    }
    .jnotification-close {
        background-image: url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2720%27 height=%2720%27 viewBox=%270 0 24 24%27 fill=%27black%27%3E%3Cpath d=%27M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z%27/%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3C/svg%3E");
    }
}

.jnotification-header {
    display: -webkit-box;
    display: -webkit-flex;
    display: -ms-flexbox;
    display: flex;
    -webkit-box-pack: start;
    -webkit-justify-content: flex-start;
    -ms-flex-pack: start;
    justify-content: flex-start;
    -webkit-box-align: center;
    -webkit-align-items: center;
    -ms-flex-align: center;
    align-items: center;
}
.jpicker {
    cursor: pointer;
    white-space: nowrap;
    display: inline-flex;
    -webkit-user-select: none;
    -moz-user-select: none;
    -ms-user-select: none;
    user-select: none;
    outline: none;
    position: relative;
}

.jpicker-header {
    background-repeat: no-repeat;
    background-position: top 50% right 5px;
    background-image: url("data:image/svg+xml,%0A%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2724%27 height=%2724%27 viewBox=%270 0 24 24%27%3E%3Cpath fill=%27none%27 d=%27M0 0h24v24H0V0z%27/%3E%3Cpath d=%27M7 10l5 5 5-5H7z%27 fill=%27gray%27/%3E%3C/svg%3E");
    text-overflow: ellipsis;
    cursor: pointer;
    box-sizing: border-box;
    text-align: left;
    outline: none;

    line-height: 24px;
    padding: 2px;
    padding-left: 12px;
    padding-right: 35px;
    outline: none;
    border-radius: 4px;
}

.jpicker-header:hover {
    background-color: #f2f2f2;
}

.jpicker-content {
    position: absolute;
    top: 0;
    display: none;
    box-shadow: 0 4px 5px 0 rgba(0,0,0,0.14), 0 1px 10px 0 rgba(0,0,0,0.12), 0 2px 4px -1px rgba(0,0,0,0.2);
    border-radius: 4px;
    background-color: #fff;
    padding: 4px;
    z-index: 50;
    text-align: left;
    max-height: 250px;
    scrollbar-width: thin;
    scrollbar-color: #333 transparent;
}

.jpicker-content::-webkit-scrollbar {
    width: 8px;
}

.jpicker-content::-webkit-scrollbar-track {
    background: #eee;
}
 
.jpicker-content::-webkit-scrollbar-thumb {
    background: #888;
}
 
.jpicker-content > div {
    padding: 6px;
    padding-left: 15px;
    padding-right: 15px;
}

.jpicker-focus > .jpicker-content {
    display: block;
}

.jpicker-content > div:hover {
    background-color:#efefef;
}

.jpicker-content > div:empty {
    opacity: 0;
}

.jpicker-header > i, .jpicker-header > div {
    display: block;
}

.jpicker-focus > .jpicker-content.jpicker-columns {
    display: flex !important ;
    justify-content: center;
    flex-wrap: wrap;
}

.jpicker-focus .jpicker-content.jpicker-grid {
    display: inline-grid;
}



.jprogressbar
{
    cursor:pointer;
    -webkit-touch-callout: none;
    -webkit-user-select: none;
    -khtml-user-select: none;
    -moz-user-select: none;
    -ms-user-select: none;
    user-select: none;
    box-sizing: border-box;
    background:#fff;
    -webkit-tap-highlight-color: transparent;
    display: inline-block;
    box-sizing: border-box;
    cursor:pointer;
    border:1px solid #ccc;
    position:relative;
}

.jprogressbar::before {
    content:attr(data-value);
    position:absolute;
    margin:5px;
    margin-left:10px;
}

.jprogressbar-header::placeholder
{
    color:#000;
}

.jprogressbar::focus {
    outline: auto 5px -webkit-focus-ring-color;
}

.jprogressbar > div {
    background-color: #eee;
    background-color: red;
    box-sizing: border-box;
    height:31px;
}
.jrating {
    display:flex;
}
.jrating > div {
    width:24px;
    height:24px;
    line-height:24px;
    background-image: url("data:image/svg+xml,%0A%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2724%27 height=%2724%27 viewBox=%270 0 24 24%27%3E%3Cpath d=%27M22 9.24l-7.19-.62L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21 12 17.27 18.18 21l-1.63-7.03L22 9.24zM12 15.4l-3.76 2.27 1-4.28-3.32-2.88 4.38-.38L12 6.1l1.71 4.04 4.38.38-3.32 2.88 1 4.28L12 15.4z%27 fill=%27gray%27/%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3C/svg%3E");
}

.jrating .jrating-over {
    background-image: url("data:image/svg+xml,%0A%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2724%27 height=%2724%27 viewBox=%270 0 24 24%27 fill=%27black%27%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3Cpath d=%27M12 17.27L18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z%27/%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3C/svg%3E");
    opacity: 0.7;
}

.jrating .jrating-selected {
    background-image: url("data:image/svg+xml,%0A%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2724%27 height=%2724%27 viewBox=%270 0 24 24%27 fill=%27red%27%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3Cpath d=%27M12 17.27L18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z%27/%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3C/svg%3E");
}

.jsearch {
    position: relative;
    display: none;
    -webkit-user-select: none;
    -moz-user-select: none;
    -ms-user-select: none;
    user-select: none;
}

.jsearch_container {
    position: absolute;
    box-shadow: 0 1px 2px 0 rgba(60,64,67,0.302), 0 2px 6px 2px rgba(60,64,67,0.149);
    border: none;
    -webkit-border-radius: 4px;
    border-radius: 4px;
    width: 280px;
    padding: 8px 0;
    z-index: 1;

    -webkit-box-shadow: 0 2px 4px rgba(0,0,0,0.2);
    box-shadow: 0 2px 4px rgba(0,0,0,0.2);
    -webkit-transition: opacity .218s;
    transition: opacity .218s;
    background: #fff;
    border: 1px solid rgba(0,0,0,.2);
    cursor: pointer;
    margin: 0;
    min-width: 300px;
    outline: none;
    width: auto;
    -webkit-user-select: none;
    -moz-user-select: none;
    -ms-user-select: none;
    user-select: none;
}

.jsearch_container:empty:after {
    content: attr(data-placeholder);
}

.jsearch_container > div {
    color: #333;
    cursor: pointer;
    display: -webkit-box;
    display: -webkit-flex;
    display: flex;
    padding: 5px 10px;
    user-select: none;
    -webkit-align-items: center;
    align-items: center;
    
    -webkit-user-select: none;
    -moz-user-select: none;
    -ms-user-select: none;
    user-select: none;
}

.jsearch_container > div:hover {
    background-color: #e8eaed;
}

.jsearch_container > div > img {
    width: 32px;
    height: 32px;
    user-select: none;
    border-radius: 16px;
    margin-right: 2px;
}

.jsearch_container > div > div {
    overflow: hidden;
    text-overflow: ellipsis;
    margin-left: 2px;
    max-width: 300px;
    white-space: nowrap;
    user-select: none;
}

.jsearch_container .selected {
    background-color: #e8eaed;
}
.jslider {
    outline: none;
}

.jslider-focus {
    width: 100% !important;
    height: 100% !important;
}

.jslider-focus img {
    display: none;
}

.jslider img {
    width: 100px;
}

.jslider-left::before {
    position: fixed;
    left: 15px;
    top: 50%;
    content:'arrow_back_ios';
    color: #fff;
    width: 30px;
    height: 30px;
    font-family: 'Material Icons';
    font-size: 30px;
    /* before it was 0px 0px 0px #000 */
    text-shadow: 0px 0px 6px rgb(56,56,56);
    text-align: center;
    cursor: pointer;
}

.jslider-right::after {
    position: fixed;
    right: 15px;
    top: 50%;
    content: 'arrow_forward_ios';
    color: #fff;
    width: 30px;
    height: 30px;
    font-family: 'Material Icons';
    font-size: 30px;
    /* before it was 0px 0px 0px #000 */
    text-shadow: 0px 0px 6px rgb(56,56,56);
    text-align: center;
    cursor: pointer;
}

.jslider-close {
    width:24px;
    height:24px;
    background-image: url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2724%27 height=%2724%27 viewBox=%270 0 24 24%27 fill=%27white%27%3E%3Cpath d=%27M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z%27/%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3C/svg%3E");
    position:fixed;
    top:15px;
    right:15px;
    cursor:pointer;
    z-index:3000;

    display: block !important;
}

.jslider-counter {
    height:24px;
    background-color: transparent;
    position:fixed;
    left: 50%;
    transform: translateX(-50%);
    bottom: 15px;
    cursor:pointer;
    z-index:3000;

    display: flex;
    display: -webkit-flex;
    -webkit-justify-content: center;
    -webkit-align-items: center;   
    -webkit-flex-direction: row;
    justify-content: center;
    align-items: center;
    flex-direction: row;
}

.jslider-caption {
    position: fixed;
    max-width: 90vw;
    text-overflow: ellipsis;
    white-space: nowrap;
    overflow: hidden;
    top:15px;
    left: 15px;
    z-index:3000;
    color: #FFF;
    font-size: 1rem;

    display: block !important;
}

.jslider-counter div {
    width: 10px;
    height: 10px;
    background: #fff;
    border-radius: 50%;
    margin: 0px 5px;

    display: block !important;
}

.jslider-counter .jslider-counter-focus {
    background-color: cornflowerblue;
    pointer-events: none;
}

.jslider-focus {
    position:fixed;
    left:0;
    top:0;
    width: 100%;
    min-height:100%;
    max-height:100%;
    z-index:2000;
    margin:0px;
    box-sizing:border-box;

    background-color:rgba(0,0,0,0.8);
    -webkit-transition-duration: .05s;
    transition-duration: .05s;
    display: flex;
    -ms-flex-align: center;
    -webkit-align-items: center;
    -webkit-box-align: center;

    align-items: center;
}

.jslider-focus img {
    width: 50vw;
    height: auto;
    box-sizing: border-box;
    margin:0 auto;
    vertical-align:middle;
    display:none;
}

.jslider-focus img.jslider-vertical {
    width: auto;
    /* before it was 50vh */
    height: 80vh;
}

@media only screen and (max-width: 576px) {
    .jslider-focus img.jslider-vertical {
        width: 99vw !important;
        height: auto !important;
    }

    .jslider-focus img {
        width: 100vw !important;
        height: auto !important;
    }
}

.jslider-grid {
    display: -ms-grid;
    display: grid;
    grid-gap: 1px;
    position: relative;
}

.jslider-grid[data-number='2'] {
    -ms-grid-columns: 1fr 50%;
    grid-template-columns: 1fr 50%;
}

.jslider-grid[data-number='3'] {
    -ms-grid-columns: 1fr 33%;
    grid-template-columns: 1fr 33%;
}

.jslider-grid[data-number='4'] {
    -ms-grid-columns: 1fr 25%;
    grid-template-columns: 1fr 25%;
}

.jslider-grid img {
    display: none;
    width: 100%;
    height: 100%;
    object-fit: cover;
}

.jslider-grid[data-total]:after {
    content: attr(data-total) "+";
    font-size: 1.5em;
    position:absolute;
    color: #fff;
    right: 15px;
    bottom: 6px;
}

.jslider-grid img:first-child {
    -ms-grid-column: 1;
    -ms-grid-row: 1;
    grid-column: 1;
    grid-row: 1;
    display: block;
}

.jslider-grid[data-number='2'] img:nth-child(2) {
    -ms-grid-column: 2;
    -ms-grid-row: 1;
    grid-column: 2;
    grid-row: 1;
    display: block;
}

.jslider-grid[data-number='3'] img:first-child {
    -ms-grid-column: 1 / 2;
    -ms-grid-row: 1 / 4;
    grid-column: 1 / 2;
    grid-row: 1 / 4;
}

.jslider-grid[data-number='3'] img:nth-child(2) {
    -ms-grid-column: 2;
    -ms-grid-row: 1;
    grid-column: 2;
    grid-row: 1;
    display: block;
}

.jslider-grid[data-number='3'] img:nth-child(3) {
    -ms-grid-column: 2;
    -ms-grid-row: 2;
    grid-column: 2;
    grid-row: 2;
    display: block;
}

.jslider-grid[data-number='4'] img:first-child {
    -ms-grid-column: 1 / 2;
    -ms-grid-row: 1 / 4;
    grid-column: 1 / 2;
    grid-row: 1 / 4;
}

.jslider-grid[data-number='4'] img:nth-child(2) {
    -ms-grid-column: 2;
    -ms-grid-row: 1;
    grid-column: 2;
    grid-row: 1;
    display: block;
}

.jslider-grid[data-number='4'] img:nth-child(3) {
    -ms-grid-column: 2;
    -ms-grid-row: 2;
    grid-column: 2;
    grid-row: 2;
    display: block;
}

.jslider-grid[data-number='4'] img:nth-child(4) {
    -ms-grid-column: 2;
    -ms-grid-row: 3;
    grid-column: 2;
    grid-row: 3;
    display: block;
}

.jtabs {
    max-width: 100vw;
    position: relative;
}

.jtabs .jtabs-headers-container {
    display: flex;
    align-items: center;
}

.jtabs .jtabs-headers {
    display: flex;
    align-items: center;
    overflow: hidden;
    position: relative;
}

.jtabs .jtabs-headers > div:not(.jtabs-border) {
    padding: 8px;
    padding-left: 20px;
    padding-right: 20px;
    margin-left: 1px;
    margin-right: 1px;
    background-color: #f1f1f1;
    cursor: pointer;
    white-space: nowrap;
    text-align: center;
}

.jtabs .jtabs-headers > div.jtabs-selected {
    background-color: #e8e8e8;
    color: #000;
}

.jtabs .jtabs-headers > div > div {
    color: #555;
    width: 100%;
    overflow: hidden;
}

.jtabs .jtabs-headers i {
    display: block;
    margin: auto;
}

.jtabs .jtabs-content {
    box-sizing: border-box;
}

.jtabs .jtabs-content > div {
    display: none;
    box-sizing: border-box;
}

.jtabs .jtabs-content > div.jtabs-selected {
    display: block;
}

.jtabs .jtabs-border {
    position: absolute;
    height: 2px;
    background-color: #888;
    transform-origin: left;
    transition: all .2s cubic-bezier(0.4,0,0.2,1);
    transition-property: color,left,transform;
    display: none;
}

.jtabs-animation .jtabs-border {
    display: initial;
}

.jtabs .jtabs-controls {
    margin: 3px;
    margin-left: 10px;
    display: flex;
    min-width: 82px;
}

.jtabs .jtabs-controls > div {
    cursor: pointer;
    background-position: center;
    background-repeat: no-repeat;
    width: 24px;
    height: 24px;
    line-height: 24px;
}

.jtabs .jtabs-prev {
    margin-left: 10px;
    background-image: url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 24 24%27 fill=%27gray%27 width=%2718px%27 height=%2718px%27%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3Cpath d=%27M15.41 7.41L14 6l-6 6 6 6 1.41-1.41L10.83 12z%27/%3E%3C/svg%3E");
}

.jtabs .jtabs-prev.disabled {
    margin-left: 10px;
    background-image: url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 24 24%27 fill=%27lightgray%27 width=%2718px%27 height=%2718px%27%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3Cpath d=%27M15.41 7.41L14 6l-6 6 6 6 1.41-1.41L10.83 12z%27/%3E%3C/svg%3E");
}

.jtabs .jtabs-next {
    background-image: url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 24 24%27 fill=%27gray%27 width=%2718px%27 height=%2718px%27%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3Cpath d=%27M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z%27/%3E%3C/svg%3E");
}

.jtabs .jtabs-next.disabled {
    background-image: url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 24 24%27 fill=%27lightgray%27 width=%2718px%27 height=%2718px%27%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3Cpath d=%27M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z%27/%3E%3C/svg%3E");
}

.jtabs .jtabs-add {
    background-image: url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 height=%2724%27 viewBox=%270 0 24 24%27 width=%2724%27%3E%3Cpath d=%27M19 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-2 10h-4v4h-2v-4H7v-2h4V7h2v4h4v2z%27 fill=%27%23bbbbbb%27/%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3C/svg%3E");
}

/** Modern skin **/

.jtabs.jtabs-modern .jtabs-headers > div:not(.jtabs-border) {
    padding: 4px;
    padding-left: 10px;
    padding-right: 10px;
    background-color: #fff;
}

.jtabs.jtabs-modern .jtabs-headers > .jtabs-selected  {
    color: #000;
}

.jtabs.jtabs-modern .jtabs-headers > .jtabs-selected .material-icons {
    color: #000;
}

.jtabs.jtabs-modern .jtabs-headers {
    background: #EEEEEF !important;
    padding: 2px;
    border-radius: 4px;
}

.jtabs.jtabs-modern .jtabs-headers .jtabs-border {
    border-color: #EEEEEF !important;
}

.jtabs.jtabs-modern .jtabs-border {
    background-color: rgba(194, 197, 188, 0.884);
}
.jtags {
    display: flex;
    flex-wrap: wrap;
    -ms-flex-direction: row;
    -webkit-flex-direction: row;
    flex-direction: row;
    -ms-flex-pack: flex-start;
    -webkit-justify-content: space-between;
    justify-content: flex-start;
    padding: 1px;
    border: 1px solid #ccc;
    position: relative;
} 

.jtags.jtags-empty:not(.jtags-focus)::before {
    position: absolute;
    margin: 3px;
    color: #ccc;
    content: attr(data-placeholder);
    top: 0;
    margin-left: 6px;
}

.jtags > div {
    padding: 0 22px 0 10px;
    font-size: 0.9em;
    position: relative;
    border-radius: 1px;
    margin: 2px;
    display: block;
    outline: none;
}

.jtags > div:empty:before {
    content: " ";
    white-space: pre;
}

.jtags > div::after {
    content: 'x';
    position: absolute;
    top: 7px;
    right: 4px;
    width: 12px;
    height: 12px;
    cursor: pointer;
    font-size: 0.9em;
    line-height: 1em;
    display: none;
}

.jtags_label {
    background-color: #e4e4e4 !important;
}

.jtags_label::after {
    display: inline-block !important;
}

.jtags_error::after {
    color: #fff  !important;
}

.jtags_error {
    background-color: #d93025 !important;
    color: #fff;
}

.jtoolbar-container {
    border-radius: 2px;
    box-shadow: 0 4px 5px 0 rgba(0,0,0,0.14), 0 1px 10px 0 rgba(0,0,0,0.12), 0 2px 4px -1px rgba(0,0,0,0.2);
    display: inline-flex !important;
}

.jtoolbar {
    cursor: pointer;
    white-space: nowrap;
    display: flex;
    padding:4px;
    -webkit-user-select: none;
    -moz-user-select: none;
    -ms-user-select: none;
    user-select: none;
    font-size: 13px;
}

.jtoolbar-disabled {
    pointer-events: none;
    opacity: 0.4;
}

.jtoolbar-mobile {
    display: flex;
    position:fixed;
    bottom: 0;
    margin: 0;
    left: 0;
    width: 100%;
    background: #f7f7f8;
    z-index: 1;
    box-sizing: border-box;
    box-shadow: 0 -1px 2px rgba(0,0,0,.1);
    border-radius: 0px;
}

.jtoolbar > div {
    display: inline-flex;
    align-items: center;
    box-sizing: border-box;
    vertical-align:middle;
    justify-content: space-evenly;
}

.jtoolbar-mobile > div {
    display: flex;
    width: 100%;
}

.jtoolbar .jtoolbar-item {
    text-align: center;
    margin: auto;
    padding: 2px;
    padding-left:4px;
    padding-right:4px;
}

.jtoolbar-mobile .jtoolbar-item {
    position: relative;
    flex:1;
} 

.jtoolbar .jtoolbar-divisor {
    width: 2px;
    height: 18px;
    padding: 0px;
    margin-left: 4px;
    margin-right: 4px;
    background-color: #ddd;
}

.jtoolbar .jtoolbar-label {
    padding-left: 8px;
    padding-right: 8px;
}



.jtoolbar-mobile a
{
    text-decoration:none;
    display:inline-block;
}

.jtoolbar-mobile i {
    display: inline-flex !important;
    color:#929292;
}

.jtoolbar-mobile span {
    font-size:0.7em;
    display:block;
    color:#929292;
}

.jtoolbar-mobile .jtoolbar-selected a, .jtoolbar-mobile .jtoolbar-selected i, .jtoolbar-mobile .jtoolbar-selected span {
    color:var(--active-color) !important;
    background-color:transparent;
}

.jtoolbar-item {
    -webkit-user-select: none;
    -moz-user-select: none;
    -ms-user-select: none;
    user-select: none;
}

.jtoolbar-item i {
    display: block;
    color:#333;
}

.jtoolbar-item:hover {
    background-color:#f2f2f2;
}


.jtoolbar .jpicker {
    padding-left:0px;
    padding-right:0px;
}

.jtoolbar .jpicker-header {
    height: 24px;
    line-height: 24px;
    padding: 0px;
    padding-right: 20px;
    padding-left: 8px;
    background-position: top 50% right 0px;
    display: flex;
    align-items: center;
    font-size: 0.9em;
}

.jtoolbar .jpicker-content > div {
    padding: 6px;
}

.jtoolbar-active {
    background-color:#eee;
}

.jtoolbar .fa {
    width: 18px;
    height: 18px;
    display: block;
    line-height: 18px;
    font-size: 14px;
}

.jtoolbar .material-icons {
    font-size: 18px;
    width: 24px;
    height: 24px;
    display: block;
    line-height: 24px;
    transform: rotate(0.03deg);
    text-align: center;
}

.jtoolbar .jtoolbar-arrow {
    background-repeat: no-repeat;
    background-position: center;
    background-image: url("data:image/svg+xml,%0A%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 24 24%27 fill=%27black%27 width=%2718px%27 height=%2718px%27%3E%3Cpath d=%27M0 0h24v24H0z%27 fill=%27none%27/%3E%3Cpath d=%27M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z%27/%3E%3C/svg%3E");
    width: 24px;
    height: 16px;
    margin-left: 4px;
    border-left: 1px solid #f2f2f2;
}

.jtoolbar-floating {
    position: absolute;
    display: none;
    box-shadow: 0 4px 5px 0 rgba(0,0,0,0.14), 0 1px 10px 0 rgba(0,0,0,0.12), 0 2px 4px -1px rgba(0,0,0,0.2);
    border-radius: 4px;
    background-color: #fff;
    padding: 4px;
    z-index: 50;
    text-align: left;
    margin-right: 20px;
}

.jtoolbar-floating .jtoolbar-divisor {
    display: none;
}

.jtoolbar-arrow-selected .jtoolbar-floating {
    display: flex;
    flex-wrap: wrap;
}


:root {
    --jexcel-border-color:#000;
}

.jexcel_container {
    display:inline-block;
    padding-right:2px;
    box-sizing: border-box;
    overscroll-behavior: contain;
    outline: none;
}

.jexcel_container.fullscreen {
    position:fixed;
    top:0px;
    left:0px;
    width:100%;
    height:100%;
    z-index:21;
}

.jexcel_container.fullscreen .jexcel_content {
    overflow:auto;
    width:100%;
    height:100%;
    background-color:#ffffff;
}

.jexcel_container.with-toolbar .jexcel > thead > tr > td {
    top: 0;
}

.jexcel_container.fullscreen.with-toolbar {
    height: calc(100% - 46px);
}

.jexcel_content {
    display:inline-block;
    box-sizing: border-box;
    padding-right:3px;
    padding-bottom:3px;
    position:relative;
    scrollbar-width: thin;
    scrollbar-color: #666 transparent;
}

@supports (-moz-appearance:none) {
    .jexcel_content { padding-right:10px; } 
}

.jexcel_content::-webkit-scrollbar {
    width: 8px;
    height: 8px;
}

.jexcel_content::-webkit-scrollbar-track {
    background: #eee;
}
 
.jexcel_content::-webkit-scrollbar-thumb {
  background: #666; 
}

.jexcel {
    border-collapse: separate;
    table-layout: fixed;
    white-space:  nowrap;
    empty-cells: show;
    border: 0px;
    background-color: #fff;
    width: 0;

    border-top: 1px solid transparent;
    border-left: 1px solid transparent;
    border-right: 1px solid #ccc;
    border-bottom: 1px solid #ccc;
}

.jexcel > thead > tr > td
{
    border-top: 1px solid #ccc;
    border-left: 1px solid #ccc;
    border-right: 1px solid transparent;
    border-bottom: 1px solid transparent;
    background-color: #f3f3f3;
    padding: 2px;
    cursor: pointer;
    box-sizing: border-box;
    overflow: hidden;
    position: -webkit-sticky;
    position: sticky;
    top: 0;
    z-index:2;
}

.jexcel_container.with-toolbar .jexcel > thead > tr > td
{
    top:42px;
}

.jexcel > thead > tr > td.dragging
{
    background-color:#fff;
    opacity:0.5;
}

.jexcel > thead > tr > td.selected
{
    background-color:#dcdcdc;
}

.jexcel > thead > tr > td.arrow-up
{
    background-repeat:no-repeat;
    background-position:center right 5px;
    background-image: url("data:image/svg+xml,%0A%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24'%3E%3Cpath fill='none' d='M0 0h24v24H0V0z'/%3E%3Cpath d='M7 14l5-5 5 5H7z' fill='gray'/%3E%3C/svg%3E");
    text-decoration:underline;
}

.jexcel > thead > tr > td.arrow-down
{
    background-repeat:no-repeat;
    background-position:center right 5px;
    background-image: url("data:image/svg+xml,%0A%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24'%3E%3Cpath fill='none' d='M0 0h24v24H0V0z'/%3E%3Cpath d='M7 10l5 5 5-5H7z' fill='gray'/%3E%3C/svg%3E");
    text-decoration:underline;
}

.jexcel > tbody > tr > td:first-child
{
    position:relative;
    background-color:#f3f3f3;
    text-align:center;
}

.jexcel > tbody.resizable > tr > td:first-child::before
{
    content:'\00a0';
    width:100%;
    height:3px;
    position:absolute;
    bottom:0px;
    left:0px;
    cursor:row-resize;
}

.jexcel > tbody.draggable > tr > td:first-child::after
{
    content:'\00a0';
    width:3px;
    height:100%;
    position:absolute;
    top:0px;
    right:0px;
    cursor:move;
}

.jexcel > tbody > tr.dragging > td
{
    background-color:#eee;
    opacity:0.5;
}

.jexcel > tbody > tr > td
{
    border-top:1px solid #ccc;
    border-left:1px solid #ccc;
    border-right:1px solid transparent;
    border-bottom:1px solid transparent;
    padding:4px;
    white-space: nowrap;
    box-sizing: border-box;
    line-height:1em;
}

.jexcel_overflow > tbody > tr > td {
    overflow: hidden;
}

.jexcel > tbody > tr > td:last-child
{
    overflow: hidden;
}

.jexcel > tbody > tr > td > img
{
    display:inline-block;
    max-width:100px;
}

.jexcel > tbody > tr > td.readonly
{
    color:rgba(0,0,0,0.3)
}
.jexcel > tbody > tr.selected > td:first-child
{
    background-color:#dcdcdc;
}
.jexcel > tbody > tr > td > select,
.jexcel > tbody > tr > td > input,
.jexcel > tbody > tr > td > textarea
{
    border:0px;
    border-radius:0px;
    outline:0px;
    width:100%;
    margin:0px;
    padding:0px;
    padding-right:2px;
    background-color:transparent;
    box-sizing: border-box;
}

.jexcel > tbody > tr > td > textarea
{
    resize: none;
    padding-top:6px !important;
}

.jexcel > tbody > tr > td > input[type=checkbox]
{
    width:12px;
    margin-top:2px;
}
.jexcel > tbody > tr > td > input[type=radio]
{
    width:12px;
    margin-top:2px;
}

.jexcel > tbody > tr > td > select
{
    -webkit-appearance: none;
    -moz-appearance: none;
    appearance: none;
    background-repeat: no-repeat;
    background-position-x: 100%;
    background-position-y: 40%;
    background-image: url(data:image/svg+xml;base64,PHN2ZyBmaWxsPSdibGFjaycgaGVpZ2h0PScyNCcgdmlld0JveD0nMCAwIDI0IDI0JyB3aWR0aD0nMjQnIHhtbG5zPSdodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2Zyc+PHBhdGggZD0nTTcgMTBsNSA1IDUtNXonLz48cGF0aCBkPSdNMCAwaDI0djI0SDB6JyBmaWxsPSdub25lJy8+PC9zdmc+);
}

.jexcel > tbody > tr > td.jexcel_dropdown
{
    background-repeat: no-repeat;
    background-position:top 50% right 5px;
    background-image: url("data:image/svg+xml,%0A%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24'%3E%3Cpath fill='none' d='M0 0h24v24H0V0z'/%3E%3Cpath d='M7 10l5 5 5-5H7z' fill='lightgray'/%3E%3C/svg%3E");
    text-overflow: ellipsis;
    overflow-x:hidden;
}

.jexcel > tbody > tr > td.jexcel_dropdown.jexcel_comments
{
    background:url("data:image/svg+xml,%0A%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24'%3E%3Cpath fill='none' d='M0 0h24v24H0V0z'/%3E%3Cpath d='M7 10l5 5 5-5H7z' fill='lightgray'/%3E%3C/svg%3E") top 50% right 5px no-repeat, url('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAACXBIWXMAAAsTAAALEwEAmpwYAAAFuGlUWHRYTUw6Y29tLmFkb2JlLnhtcAAAAAAAPD94cGFja2V0IGJlZ2luPSLvu78iIGlkPSJXNU0wTXBDZWhpSHpyZVN6TlRjemtjOWQiPz4gPHg6eG1wbWV0YSB4bWxuczp4PSJhZG9iZTpuczptZXRhLyIgeDp4bXB0az0iQWRvYmUgWE1QIENvcmUgNS42LWMxNDUgNzkuMTYzNDk5LCAyMDE4LzA4LzEzLTE2OjQwOjIyICAgICAgICAiPiA8cmRmOlJERiB4bWxuczpyZGY9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkvMDIvMjItcmRmLXN5bnRheC1ucyMiPiA8cmRmOkRlc2NyaXB0aW9uIHJkZjphYm91dD0iIiB4bWxuczp4bXA9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC8iIHhtbG5zOnhtcE1NPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvbW0vIiB4bWxuczpzdEV2dD0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL3NUeXBlL1Jlc291cmNlRXZlbnQjIiB4bWxuczpkYz0iaHR0cDovL3B1cmwub3JnL2RjL2VsZW1lbnRzLzEuMS8iIHhtbG5zOnBob3Rvc2hvcD0iaHR0cDovL25zLmFkb2JlLmNvbS9waG90b3Nob3AvMS4wLyIgeG1wOkNyZWF0b3JUb29sPSJBZG9iZSBQaG90b3Nob3AgQ0MgMjAxOSAoV2luZG93cykiIHhtcDpDcmVhdGVEYXRlPSIyMDE5LTAxLTMxVDE4OjU1OjA4WiIgeG1wOk1ldGFkYXRhRGF0ZT0iMjAxOS0wMS0zMVQxODo1NTowOFoiIHhtcDpNb2RpZnlEYXRlPSIyMDE5LTAxLTMxVDE4OjU1OjA4WiIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDphMTlhZDJmOC1kMDI2LTI1NDItODhjOS1iZTRkYjkyMmQ0MmQiIHhtcE1NOkRvY3VtZW50SUQ9ImFkb2JlOmRvY2lkOnBob3Rvc2hvcDpkOGI5NDUyMS00ZjEwLWQ5NDktYjUwNC0wZmU1N2I3Nzk1MDEiIHhtcE1NOk9yaWdpbmFsRG9jdW1lbnRJRD0ieG1wLmRpZDplMzdjYmE1ZS1hYTMwLWNkNDUtYTAyNS1lOWYxZjk2MzUzOGUiIGRjOmZvcm1hdD0iaW1hZ2UvcG5nIiBwaG90b3Nob3A6Q29sb3JNb2RlPSIzIj4gPHhtcE1NOkhpc3Rvcnk+IDxyZGY6U2VxPiA8cmRmOmxpIHN0RXZ0OmFjdGlvbj0iY3JlYXRlZCIgc3RFdnQ6aW5zdGFuY2VJRD0ieG1wLmlpZDplMzdjYmE1ZS1hYTMwLWNkNDUtYTAyNS1lOWYxZjk2MzUzOGUiIHN0RXZ0OndoZW49IjIwMTktMDEtMzFUMTg6NTU6MDhaIiBzdEV2dDpzb2Z0d2FyZUFnZW50PSJBZG9iZSBQaG90b3Nob3AgQ0MgMjAxOSAoV2luZG93cykiLz4gPHJkZjpsaSBzdEV2dDphY3Rpb249InNhdmVkIiBzdEV2dDppbnN0YW5jZUlEPSJ4bXAuaWlkOmExOWFkMmY4LWQwMjYtMjU0Mi04OGM5LWJlNGRiOTIyZDQyZCIgc3RFdnQ6d2hlbj0iMjAxOS0wMS0zMVQxODo1NTowOFoiIHN0RXZ0OnNvZnR3YXJlQWdlbnQ9IkFkb2JlIFBob3Rvc2hvcCBDQyAyMDE5IChXaW5kb3dzKSIgc3RFdnQ6Y2hhbmdlZD0iLyIvPiA8L3JkZjpTZXE+IDwveG1wTU06SGlzdG9yeT4gPC9yZGY6RGVzY3JpcHRpb24+IDwvcmRmOlJERj4gPC94OnhtcG1ldGE+IDw/eHBhY2tldCBlbmQ9InIiPz4En6MDAAAAX0lEQVQYlX3KOw6AIBBAwS32RpJADXfx0pTET+ERZJ8F8RODFtONsG0QAoh0CSDM82dqodaBdQXnfoLZQM7gPai+wjNNE8R4pTuAYNZSKZASqL7CMy0LxNgJp30fKYUDi3+vIqb/+rUAAAAASUVORK5CYII=') top right no-repeat;
}

.jexcel > tbody > tr > td > .color
{
    width:90%;
    height:10px;
    margin:auto;
}

.jexcel > tbody > tr > td > a {
    text-decoration: underline;
}

.jexcel > tbody > tr > td.highlight > a {
    color: blue;
    cursor: pointer;
}

.jexcel > tfoot > tr > td
{
    border-top: 1px solid #ccc;
    border-left: 1px solid #ccc;
    border-right: 1px solid transparent;
    border-bottom: 1px solid transparent;
    background-color: #f3f3f3;
    padding: 2px;
    cursor: pointer;
    box-sizing: border-box;
    overflow: hidden;
}

.jexcel .highlight {
    background-color:rgba(0,0,0,0.05);
}

.jexcel .highlight-top {
    border-top:1px solid #000; /* var(--jexcel-border-color);*/
    box-shadow: 0px -1px #ccc;
}

.jexcel .highlight-left {
    border-left:1px solid #000; /* var(--jexcel-border-color);*/
    box-shadow: -1px 0px #ccc;
}

.jexcel .highlight-right {
    border-right:1px solid #000; /* var(--jexcel-border-color);*/
}

.jexcel .highlight-bottom {
    border-bottom:1px solid #000; /* var(--jexcel-border-color);*/
}

.jexcel .highlight-top.highlight-left {
    box-shadow: -1px -1px #ccc;
    -webkit-box-shadow: -1px -1px #ccc;
    -moz-box-shadow: -1px -1px #ccc;
}

.jexcel .highlight-selected
{
    background-color:rgba(0,0,0,0.0);
}
.jexcel .selection
{
    background-color:rgba(0,0,0,0.05);
}
.jexcel .selection-left
{
    border-left:1px dotted #000;
}
.jexcel .selection-right
{
    border-right:1px dotted #000;
}
.jexcel .selection-top
{
    border-top:1px dotted #000;
}
.jexcel .selection-bottom
{
    border-bottom:1px dotted #000;
}
.jexcel_corner
{
    position:absolute;
    background-color: rgb(0, 0, 0);
    height: 1px;
    width: 1px;
    border: 1px solid rgb(255, 255, 255);
    top:-2000px;
    left:-2000px;
    cursor:crosshair;
    box-sizing: initial;
    z-index:20;
    padding: 2px;
}

.jexcel .editor
{
    outline:0px solid transparent;
    overflow:visible;
    white-space: nowrap;
    text-align:left;
    padding:0px;
    box-sizing: border-box;
    overflow:visible !important;
}

.jexcel .editor > input
{
    padding-left:4px;
}

.jexcel .editor .jupload
{
    position:fixed;
    top:100%;
    z-index:40;
    user-select:none;
    -webkit-font-smoothing: antialiased;
    font-size: .875rem;
    letter-spacing: .2px;
    -webkit-border-radius: 4px;
    border-radius: 4px;
    -webkit-box-shadow: 0 8px 10px 1px rgba(0,0,0,0.14), 0 3px 14px 2px rgba(0,0,0,0.12), 0 5px 5px -3px rgba(0,0,0,0.2);
    box-shadow: 0 8px 10px 1px rgba(0,0,0,0.14), 0 3px 14px 2px rgba(0,0,0,0.12), 0 5px 5px -3px rgba(0,0,0,0.2);
    padding:10px;
    background-color:#fff;
    width:300px;
    min-height:225px;
    margin-top:2px;
}

.jexcel .editor .jupload img
{
    width:100%;
    height:auto;
}

.jexcel .editor .jexcel_richtext
{
    position:fixed;
    top:100%;
    z-index:40;
    user-select:none;
    -webkit-font-smoothing: antialiased;
    font-size: .875rem;
    letter-spacing: .2px;
    -webkit-box-shadow: 0 8px 10px 1px rgba(0,0,0,0.14), 0 3px 14px 2px rgba(0,0,0,0.12), 0 5px 5px -3px rgba(0,0,0,0.2);
    box-shadow: 0 8px 10px 1px rgba(0,0,0,0.14), 0 3px 14px 2px rgba(0,0,0,0.12), 0 5px 5px -3px rgba(0,0,0,0.2);
    padding:10px;
    background-color:#fff;
    min-width:280px;
    max-width:310px;
    margin-top:2px;
    text-align:left;
}

.jexcel .editor .jclose:after
{
    position:absolute;
    top:0;
    right:0;
    margin:10px;
    content:'close';
    font-family:'Material icons';
    font-size:24px;
    width:24px;
    height:24px;
    line-height:24px;
    cursor:pointer;
    text-shadow: 0px 0px 5px #fff;
}

.jexcel, .jexcel td, .jexcel_corner
{
  -webkit-touch-callout: none;
  -webkit-user-select: none;
  -khtml-user-select: none;
  -moz-user-select: none;
  -ms-user-select: none;
  user-select: none;
  -webkit-user-drag: none;
  -khtml-user-drag: none;
  -moz-user-drag: none;
  -o-user-drag: none;
  user-drag: none;
}

.jexcel_textarea
{
    position:absolute;
    top:-999px;
    left:-999px;
    width:1px;
    height:1px;
}
.jexcel .dragline
{
    position:absolute;
}
.jexcel .dragline div
{
    position:relative;
    top:-6px;
    height:5px;
    width:22px;
}
.jexcel .dragline div:hover
{
    cursor:move;
}

.jexcel .onDrag
{
    background-color:rgba(0,0,0,0.6);
}

.jexcel .error
{
    border:1px solid red;
}

.jexcel thead td.resizing
{
    border-right-style:dotted !important;
    border-right-color:red !important;
}

.jexcel tbody tr.resizing > td
{
    border-bottom-style:dotted !important;
    border-bottom-color:red !important;
}

.jexcel tbody td.resizing
{
    border-right-style:dotted !important;
    border-right-color:red !important;
}

.jexcel .jdropdown-header
{
    border:0px !important;
    outline:none !important;
    width:100% !important;
    height:100% !important;
    padding:0px !important;
    padding-left:8px !important;
}

.jexcel .jdropdown-container
{
    margin-top:1px;
}

.jexcel .jdropdown-container-header {
    padding: 0px;
    margin: 0px;
    height: inherit;
}

.jexcel .jdropdown-picker
{
    border:0px !important;
    padding:0px !important;
    width:inherit;
    height:inherit;
}

.jexcel .jexcel_comments
{
    background:url('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAACXBIWXMAAAsTAAALEwEAmpwYAAAFuGlUWHRYTUw6Y29tLmFkb2JlLnhtcAAAAAAAPD94cGFja2V0IGJlZ2luPSLvu78iIGlkPSJXNU0wTXBDZWhpSHpyZVN6TlRjemtjOWQiPz4gPHg6eG1wbWV0YSB4bWxuczp4PSJhZG9iZTpuczptZXRhLyIgeDp4bXB0az0iQWRvYmUgWE1QIENvcmUgNS42LWMxNDUgNzkuMTYzNDk5LCAyMDE4LzA4LzEzLTE2OjQwOjIyICAgICAgICAiPiA8cmRmOlJERiB4bWxuczpyZGY9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkvMDIvMjItcmRmLXN5bnRheC1ucyMiPiA8cmRmOkRlc2NyaXB0aW9uIHJkZjphYm91dD0iIiB4bWxuczp4bXA9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC8iIHhtbG5zOnhtcE1NPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvbW0vIiB4bWxuczpzdEV2dD0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL3NUeXBlL1Jlc291cmNlRXZlbnQjIiB4bWxuczpkYz0iaHR0cDovL3B1cmwub3JnL2RjL2VsZW1lbnRzLzEuMS8iIHhtbG5zOnBob3Rvc2hvcD0iaHR0cDovL25zLmFkb2JlLmNvbS9waG90b3Nob3AvMS4wLyIgeG1wOkNyZWF0b3JUb29sPSJBZG9iZSBQaG90b3Nob3AgQ0MgMjAxOSAoV2luZG93cykiIHhtcDpDcmVhdGVEYXRlPSIyMDE5LTAxLTMxVDE4OjU1OjA4WiIgeG1wOk1ldGFkYXRhRGF0ZT0iMjAxOS0wMS0zMVQxODo1NTowOFoiIHhtcDpNb2RpZnlEYXRlPSIyMDE5LTAxLTMxVDE4OjU1OjA4WiIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDphMTlhZDJmOC1kMDI2LTI1NDItODhjOS1iZTRkYjkyMmQ0MmQiIHhtcE1NOkRvY3VtZW50SUQ9ImFkb2JlOmRvY2lkOnBob3Rvc2hvcDpkOGI5NDUyMS00ZjEwLWQ5NDktYjUwNC0wZmU1N2I3Nzk1MDEiIHhtcE1NOk9yaWdpbmFsRG9jdW1lbnRJRD0ieG1wLmRpZDplMzdjYmE1ZS1hYTMwLWNkNDUtYTAyNS1lOWYxZjk2MzUzOGUiIGRjOmZvcm1hdD0iaW1hZ2UvcG5nIiBwaG90b3Nob3A6Q29sb3JNb2RlPSIzIj4gPHhtcE1NOkhpc3Rvcnk+IDxyZGY6U2VxPiA8cmRmOmxpIHN0RXZ0OmFjdGlvbj0iY3JlYXRlZCIgc3RFdnQ6aW5zdGFuY2VJRD0ieG1wLmlpZDplMzdjYmE1ZS1hYTMwLWNkNDUtYTAyNS1lOWYxZjk2MzUzOGUiIHN0RXZ0OndoZW49IjIwMTktMDEtMzFUMTg6NTU6MDhaIiBzdEV2dDpzb2Z0d2FyZUFnZW50PSJBZG9iZSBQaG90b3Nob3AgQ0MgMjAxOSAoV2luZG93cykiLz4gPHJkZjpsaSBzdEV2dDphY3Rpb249InNhdmVkIiBzdEV2dDppbnN0YW5jZUlEPSJ4bXAuaWlkOmExOWFkMmY4LWQwMjYtMjU0Mi04OGM5LWJlNGRiOTIyZDQyZCIgc3RFdnQ6d2hlbj0iMjAxOS0wMS0zMVQxODo1NTowOFoiIHN0RXZ0OnNvZnR3YXJlQWdlbnQ9IkFkb2JlIFBob3Rvc2hvcCBDQyAyMDE5IChXaW5kb3dzKSIgc3RFdnQ6Y2hhbmdlZD0iLyIvPiA8L3JkZjpTZXE+IDwveG1wTU06SGlzdG9yeT4gPC9yZGY6RGVzY3JpcHRpb24+IDwvcmRmOlJERj4gPC94OnhtcG1ldGE+IDw/eHBhY2tldCBlbmQ9InIiPz4En6MDAAAAX0lEQVQYlX3KOw6AIBBAwS32RpJADXfx0pTET+ERZJ8F8RODFtONsG0QAoh0CSDM82dqodaBdQXnfoLZQM7gPai+wjNNE8R4pTuAYNZSKZASqL7CMy0LxNgJp30fKYUDi3+vIqb/+rUAAAAASUVORK5CYII=');
    background-repeat: no-repeat;
    background-position: top right;
}

.jexcel .sp-replacer
{
    margin: 2px;
    border:0px;
}

.jexcel > thead > tr.jexcel_filter > td > input
{
    border:0px;
    width:100%;
    outline:none;
}

.jexcel_about {
    float: right;
    font-size: 0.7em;
    padding: 2px;
    text-transform: uppercase;
    letter-spacing: 1px;
    display: none;
}
.jexcel_about a {
    color: #ccc;
    text-decoration: none;
}

.jexcel_about img {
    display: none;
}

.jexcel_filter
{
    display:flex;
    justify-content:space-between;
    margin-bottom:4px;
}

.jexcel_filter > div
{
    padding:8px;
    align-items:center;
}

.jexcel_pagination
{
    display:flex;
    justify-content:space-between;
    align-items:center;
}

.jexcel_pagination > div
{
    display:flex;
    padding:10px;
}

.jexcel_pagination > div:last-child
{
    padding-right:10px;
    padding-top:10px;
}

.jexcel_pagination > div > div
{
    text-align:center;
    width:36px;
    height:36px;
    line-height:34px;
    border:1px solid #ccc;
    box-sizing: border-box;
    margin-left:2px;
    cursor:pointer;
}

.jexcel_page
{
    font-size:0.8em;
}

.jexcel_page_selected
{
    font-weight:bold;
    background-color:#f3f3f3;
}

.jexcel_toolbar
{
    display:flex;
    background-color:#f3f3f3;
    border:1px solid #ccc;
    padding:4px;
    margin:0px 2px 4px 1px;
    position:sticky;
    top:0px;
    z-index:21;
}

.jexcel_toolbar:empty
{
    display:none;
}

.jexcel_toolbar i.jexcel_toolbar_item 
{
    width:24px;
    height:24px;
    padding:4px;
    cursor:pointer;
    display:inline-block;
}

.jexcel_toolbar i.jexcel_toolbar_item:hover 
{
    background-color:#ddd;
}

.jexcel_toolbar select.jexcel_toolbar_item 
{
    margin-left:2px;
    margin-right:2px;
    display:inline-block;
    border:0px;
    background-color:transparent;
    padding-right:10px;
}

.jexcel .dragging-left
{
    background-repeat: no-repeat;
    background-position:top 50% left 0px;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24'%3E%3Cpath d='M14 7l-5 5 5 5V7z'/%3E%3Cpath fill='none' d='M24 0v24H0V0h24z'/%3E%3C/svg%3E");
}

.jexcel .dragging-right
{
    background-repeat: no-repeat;
    background-position:top 50% right 0px;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24'%3E%3Cpath d='M10 17l5-5-5-5v10z'/%3E%3Cpath fill='none' d='M0 24V0h24v24H0z'/%3E%3C/svg%3E");
}

.jexcel_tabs .jexcel_tab
{
    display:none;
}

.jexcel_tabs .jexcel_tab_link
{
    display:inline-block;
    padding:10px;
    padding-left:20px;
    padding-right:20px;
    margin-right:5px;
    margin-bottom:5px;
    background-color:#f3f3f3;
    cursor:pointer;
}

.jexcel_tabs .jexcel_tab_link.selected
{
    background-color:#ddd;
}

.jexcel_hidden_index > tbody > tr > td:first-child,
.jexcel_hidden_index > thead > tr > td:first-child,
.jexcel_hidden_index > tfoot > tr > td:first-child,
.jexcel_hidden_index > colgroup > col:first-child
{
    display:none;
}



.jexcel .jrating {
    display: inline-flex;
}
.jexcel .jrating > div {
    zoom: 0.55;
}

.jexcel .copying-top {
    border-top:1px dashed #000;
}

.jexcel .copying-left {
    border-left:1px dashed #000;
}

.jexcel .copying-right {
    border-right:1px dashed #000;
}

.jexcel .copying-bottom {
    border-bottom:1px dashed #000;
}

.jexcel .jexcel_column_filter {
    background-repeat: no-repeat;
    background-position: top 50% right 5px;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='gray' width='18px' height='18px'%3E%3Cpath d='M10 18h4v-2h-4v2zM3 6v2h18V6H3zm3 7h12v-2H6v2z'/%3E%3Cpath d='M0 0h24v24H0z' fill='none'/%3E%3C/svg%3E");
    text-overflow: ellipsis;
    overflow: hidden;
    padding: 0px;
    padding-left: 6px;
    padding-right: 20px;
}

.jexcel thead .jexcel_freezed, .jexcel tfoot .jexcel_freezed {
    left: 0px;
    z-index: 3 !important;
    box-shadow: 2px 0px 2px 0.2px #ccc !important;
    -webkit-box-shadow: 2px 0px 2px 0.2px #ccc !important;
    -moz-box-shadow: 2px 0px 2px 0.2px #ccc !important;
}

.jexcel tbody .jexcel_freezed {
    position: relative;
    background-color: #fff;
    box-shadow: 1px 1px 1px 1px #ccc !important;
    -webkit-box-shadow: 2px 4px 4px 0.1px #ccc !important;
    -moz-box-shadow: 2px 4px 4px 0.1px #ccc !important;
}

.red {
    color: red;
}

.jexcel > tbody > tr > td.readonly > input[type=checkbox],
.jexcel > tbody > tr > td.readonly > input[type=radio] {
    pointer-events: none;
    opacity: 0.5;
}
</style>
<style>
/* Layout: cabeçalho com o logótipo e três separadores (Dados em grelha tipo Excel · Emitir relatório por marca · Relatórios emitidos) */
:root{
  --bg:#f6f9f1; --surface:#ffffff; --fg:#1f2a14; --muted:#5f6f52; --line:#d8e5c6; --grid:#e3ead9;
  --accent:#5e8c1b; --accent-strong:#3f6a0f; --accent-soft:#e9f5d3; --lime:#8dbe2d; --on-accent:#ffffff;
  --danger:#b3261e; --danger-soft:#fbe9e7; --warn:#8a5a00; --warn-soft:#fdf0d5;
  --display:"Lexend",system-ui,sans-serif; --body:"Source Sans 3",system-ui,-apple-system,"Segoe UI",sans-serif;
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --bg:#141a0f; --surface:#1c2416; --fg:#e8f0dd; --muted:#a3b293; --line:#33422a; --grid:#2a3622;
  --accent:#9ccf45; --accent-strong:#b9e070; --accent-soft:#26331b; --lime:#9ccf45; --on-accent:#141a0f;
  --danger:#f2b8b5; --danger-soft:#3a1d1b; --warn:#f3c96b; --warn-soft:#3a2f14; color-scheme:dark}}
:root[data-theme="dark"]{
  --bg:#141a0f; --surface:#1c2416; --fg:#e8f0dd; --muted:#a3b293; --line:#33422a; --grid:#2a3622;
  --accent:#9ccf45; --accent-strong:#b9e070; --accent-soft:#26331b; --lime:#9ccf45; --on-accent:#141a0f;
  --danger:#f2b8b5; --danger-soft:#3a1d1b; --warn:#f3c96b; --warn-soft:#3a2f14; color-scheme:dark}
*{box-sizing:border-box}
[hidden]{display:none!important}
body{background:var(--bg);color:var(--fg);font-family:var(--body);font-size:15px;line-height:1.5}
.wrap{max-width:1400px;margin:0 auto;padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px));padding-block:18px 48px}
header{display:flex;align-items:center;gap:18px;flex-wrap:wrap;padding-bottom:14px;border-bottom:2px solid var(--line);margin-bottom:16px}
.logo{height:60px;width:auto;background:#fff;border-radius:8px;padding:4px 8px}
header h1{font-family:var(--display);font-weight:600;font-size:1.55rem;margin:0;color:var(--accent-strong);text-wrap:balance}
header p{margin:0;color:var(--muted)}
.hgrow{flex:1 1 260px;min-width:0}
.save{font-size:.88rem;color:var(--muted);display:flex;align-items:center;gap:6px}
.save i{width:8px;height:8px;border-radius:50%;background:var(--lime);display:inline-block}
.save.busy i{background:var(--warn)} .save.err{color:var(--danger)} .save.err i{background:var(--danger)}
nav.tabs{display:flex;gap:4px;flex-wrap:wrap;margin-bottom:16px}
nav.tabs button{background:transparent;border:1px solid transparent;border-bottom:3px solid transparent;border-radius:6px 6px 0 0;color:var(--muted);font-family:var(--display);font-weight:500;font-size:1rem;padding:8px 14px}
nav.tabs button[aria-selected="true"]{color:var(--accent-strong);border-bottom-color:var(--accent);background:var(--surface)}
nav.tabs .n{display:inline-block;margin-left:6px;background:var(--accent-soft);color:var(--accent-strong);border-radius:999px;padding:0 8px;font-size:.78rem;font-family:var(--body);font-weight:700;font-variant-numeric:tabular-nums}
.panel{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:16px}
h2{font-family:var(--display);font-weight:500;font-size:1.1rem;margin:0 0 10px}
h3{font-family:var(--display);font-weight:500;font-size:1rem;margin:0 0 6px}
label.f{display:block;font-weight:600;font-size:.78rem;letter-spacing:.04em;text-transform:uppercase;color:var(--muted);margin-bottom:4px}
input,textarea,select{font:inherit;color:var(--fg);background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:7px 10px;width:100%}
input[type=checkbox]{width:auto;accent-color:var(--accent)}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
button{font:inherit;font-weight:600;border-radius:6px;border:1px solid transparent;padding:8px 14px;cursor:pointer;display:inline-flex;align-items:center;gap:6px}
button:disabled{opacity:.5;cursor:not-allowed}
.primary{background:var(--accent);color:var(--on-accent)}
.ghost{background:var(--surface);border-color:var(--line);color:var(--fg)}
.ghost:hover:not(:disabled){border-color:var(--accent)}
.danger{background:var(--danger-soft);color:var(--danger)}
.sm{padding:5px 10px;font-size:.88rem}
.mi{font-family:"Material Icons";font-weight:normal;font-style:normal;font-size:18px;line-height:1;letter-spacing:normal;text-transform:none;white-space:nowrap;-webkit-font-smoothing:antialiased}
.bar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:10px}
.bar .grow{flex:1}
.hint{color:var(--muted);font-size:.88rem}
.msg{font-size:.9rem;min-height:1.3em;margin-top:6px}
.msg.err{color:var(--danger)} .msg.ok{color:var(--accent-strong)}
.sep{width:1px;align-self:stretch;background:var(--line);margin:0 2px}
.empty{border:1px dashed var(--line);border-radius:10px;padding:28px;text-align:center;color:var(--muted)}

/* importação */
.imp{border:2px solid var(--lime);border-radius:10px;padding:14px;background:var(--accent-soft);margin-bottom:12px}
.imp p{margin:0 0 8px}
.imp .acts .grow{flex:1}
.imp .acts{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
label.opt{display:inline-flex;align-items:center;gap:8px;cursor:pointer;margin-right:12px}

/* grelha (Jspreadsheet) com as cores da farmácia */
#gridBox{min-width:0;overflow:hidden}
.jexcel_container{max-width:100%;font-family:var(--body)}
.jexcel_content{max-width:100%;border:1px solid var(--line);border-radius:6px;background:var(--surface)}
.jexcel{font-size:13px;color:var(--fg);background:var(--surface);border-color:var(--grid)!important}
.jexcel > thead > tr > td{background:var(--accent-soft)!important;color:var(--accent-strong)!important;font-weight:700;border-color:var(--line)!important;position:sticky;top:0;z-index:2}
.jexcel > thead > tr > td.selected{background:var(--lime)!important;color:#fff!important}
.jexcel > tbody > tr > td{text-overflow:ellipsis;padding:3px 5px;border-color:var(--grid)!important;background:var(--surface);color:var(--fg)}
.jexcel > tbody > tr > td:first-child{background:var(--accent-soft)!important;color:var(--muted)!important;font-variant-numeric:tabular-nums}
.jexcel > tbody > tr.selected > td:first-child{background:var(--lime)!important;color:#fff!important}
.jexcel > tbody > tr > td.highlight{background:color-mix(in srgb,var(--lime) 18%,var(--surface))}
.jexcel > tbody > tr > td.highlight-selected{outline:2px solid var(--accent)}
.jexcel > tbody > tr > td > input,.jexcel > tbody > tr > td.editor{color:#141413}
.jexcel > tbody > tr > td.fref{outline:2px dashed #2f6fd6;outline-offset:-2px;background:color-mix(in srgb,#2f6fd6 10%,var(--surface))}
.fbar{display:flex;align-items:center;gap:10px;border:1px solid var(--line);border-bottom:0;border-radius:6px 6px 0 0;background:var(--surface);padding:5px 10px;font-size:.9rem;min-height:32px}
.fbar b{min-width:44px;color:var(--accent-strong);font-variant-numeric:tabular-nums}
.fbar .fx{font-style:italic;color:var(--muted);border-left:1px solid var(--line);padding-left:10px}
.fbar #fbVal{min-width:0;overflow-wrap:anywhere;font-family:ui-monospace,Consolas,monospace}
.jexcel_corner{background-color:var(--accent)!important;border-color:var(--surface)!important}
.jexcel > tbody > tr > td.readonly{color:var(--muted)}
.jexcel_filter{display:none!important;flex-wrap:wrap;gap:8px;align-items:center;justify-content:space-between;margin-bottom:6px}
.jexcel_filter > div{display:flex;align-items:center;gap:6px;color:var(--muted);font-size:.9rem}
.jexcel_search{width:240px!important;padding:6px 10px!important;border:1px solid var(--line)!important;border-radius:6px;background:var(--bg)!important;color:var(--fg)}
.jexcel_pagination{color:var(--muted);font-size:.9rem}
.jexcel_contextmenu.jcontextmenu{z-index:60}
.jdropdown-container,.jcalendar-container{z-index:70}
.jexcel > tbody > tr > td.jexcel_dropdown{background-image:none}

/* seleção de várias marcas */
.ms{position:relative;min-width:0}
.msbtn{width:100%;justify-content:space-between;background:var(--bg);border:1px solid var(--line);color:var(--fg);font-weight:400;padding:7px 10px}
.msbtn span:first-child{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.mspop{position:absolute;z-index:50;top:100%;left:0;right:0;min-width:min(380px,calc(100vw - 32px));margin-top:4px;background:var(--surface);border:1px solid var(--line);border-radius:10px;box-shadow:0 8px 24px rgba(0,0,0,.18);padding:10px;display:grid;gap:8px}
.msacts{display:flex;gap:14px;flex-wrap:wrap}
.link{background:none;border:0;padding:0;color:var(--accent-strong);text-decoration:underline;font-weight:600;font-size:.88rem}
.mslist{max-height:300px;overflow:auto;border:1px solid var(--line);border-radius:6px}
.msitem{display:flex;align-items:center;gap:8px;padding:5px 10px;cursor:pointer;border-bottom:1px solid var(--line)}
.msitem:hover{background:var(--accent-soft)}
.msitem span{flex:1;min-width:0;overflow-wrap:anywhere}
.msitem small{color:var(--muted);font-variant-numeric:tabular-nums}
.msfoot{display:flex;justify-content:space-between;align-items:center;gap:8px;color:var(--muted);font-size:.88rem}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:8px}
.chips:empty{display:none}
.chips button{background:var(--accent-soft);color:var(--accent-strong);border-radius:999px;padding:2px 10px;font-size:.82rem}
.chips button .mi{font-size:15px}

/* emitir */
.emit{display:grid;grid-template-columns:minmax(0,300px) minmax(0,1fr);gap:16px;align-items:start}
@media (max-width:860px){.emit{grid-template-columns:minmax(0,1fr)}}
.brands{display:grid;gap:8px}
.blist{max-height:560px;overflow:auto;border:1px solid var(--line);border-radius:8px}
.blist button{width:100%;justify-content:space-between;background:transparent;border:0;border-bottom:1px solid var(--line);border-radius:0;padding:7px 10px;font-weight:400;color:var(--fg);text-align:left}
.blist button:hover{background:var(--accent-soft)}
.blist button[aria-pressed="true"]{background:var(--accent);color:var(--on-accent)}
.blist button span::before{content:"";display:inline-block;width:12px;height:12px;border:1.5px solid currentColor;border-radius:3px;margin-right:8px;vertical-align:-1px;opacity:.6}
.blist button[aria-pressed="true"] span::before{content:"✓";opacity:1;font-size:10px;line-height:10px;text-align:center;font-weight:700}
.blist button[aria-pressed="true"] small{color:var(--on-accent)}
.blist span{min-width:0;overflow-wrap:anywhere}
.blist small{color:var(--muted);font-variant-numeric:tabular-nums;white-space:nowrap}
.blist small b{color:var(--accent-strong)}
.blist button[aria-pressed="true"] small b{color:var(--on-accent)}
.filters{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;align-items:end;margin-bottom:10px}
.tot{display:flex;gap:10px;flex-wrap:wrap;margin:10px 0}
.tot div{background:var(--accent-soft);border-radius:8px;padding:6px 12px;font-variant-numeric:tabular-nums}
.tot b{display:block;font-family:var(--display);font-weight:500;font-size:1.1rem;color:var(--accent-strong)}
.tot span{font-size:.76rem;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}
.tw{overflow:auto;max-height:420px;border:1px solid var(--line);border-radius:8px}
table.t{border-collapse:collapse;width:100%;font-size:.88rem;font-variant-numeric:tabular-nums}
table.t th{background:var(--accent);color:var(--on-accent);text-align:left;padding:6px 8px;font-weight:600;white-space:nowrap;position:sticky;top:0;z-index:1}
table.t td{border-bottom:1px solid var(--line);padding:5px 8px;vertical-align:top}
table.t td.n{text-align:right;white-space:nowrap}
table.t td.nw{white-space:nowrap}
table.t tr.off td{color:var(--muted)}
table.t .ck{width:34px;text-align:center}
.chip{display:inline-block;border-radius:999px;padding:1px 9px;font-size:.78rem;font-weight:600;white-space:nowrap}
.chip.ok{background:var(--accent-soft);color:var(--accent-strong)}
.chip.due{background:var(--warn-soft);color:var(--warn)}
.chip.pend{background:var(--danger-soft);color:var(--danger)}
.chip.info{background:var(--line);color:var(--fg)}
.form{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-top:14px;padding-top:14px;border-top:1px solid var(--line)}
.form .wide{grid-column:1/-1}
.form .end{display:flex;gap:8px;align-items:center;flex-wrap:wrap;justify-content:flex-end}

/* arquivo */
.seg{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px}
.seg button{background:var(--surface);border:1px solid var(--line);border-radius:8px;padding:6px 12px;text-align:left;font-weight:400;color:var(--fg);flex-direction:column;align-items:flex-start;gap:0;font-variant-numeric:tabular-nums}
.seg button b{font-family:var(--display);font-weight:500;font-size:1.05rem}
.seg button span{font-size:.78rem;color:var(--muted)}
.seg button[aria-pressed="true"]{border-color:var(--accent);box-shadow:inset 0 0 0 1px var(--accent)}
.seg .pend b{color:var(--danger)} .seg .due b{color:var(--warn)} .seg .ok b{color:var(--accent-strong)}
table.rep td{vertical-align:middle}
table.rep td.tit{min-width:240px}
table.rep td.tit b{display:block;overflow-wrap:anywhere}
table.rep td.tit small{color:var(--muted)}
table.rep td input,table.rep td select{min-width:130px;padding:5px 8px;font-size:.88rem;background:var(--surface)}
table.rep td.acts{white-space:nowrap;text-align:right}
table.rep td.acts button{margin-left:4px}
table.rep tr.ask td{background:var(--danger-soft);color:var(--danger)}
.pdfi{width:34px;height:42px;border-radius:4px;background:var(--accent-soft);color:var(--accent-strong);display:grid;place-items:center;font-family:var(--display);font-size:.66rem;font-weight:600;border:1px solid var(--line)}

/* visualizador */
.viewer{position:fixed;inset:0;z-index:80;background:var(--bg);display:flex;flex-direction:column}
.vbar{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;padding:calc(10px + env(safe-area-inset-top,0px)) max(16px,env(safe-area-inset-right,0px)) 10px max(16px,env(safe-area-inset-left,0px));border-bottom:1px solid var(--line);background:var(--surface)}
.vbar strong{font-family:var(--display);font-weight:500;overflow-wrap:anywhere;min-width:0}
.vacts{display:flex;gap:8px;flex-wrap:wrap}
.vbody{flex:1;overflow:auto;padding:16px;display:flex;flex-direction:column;align-items:center;gap:14px;background:var(--accent-soft)}
.vbody canvas{max-width:100%;height:auto;background:#fff;box-shadow:0 1px 4px rgba(0,0,0,.18)}
@media (max-width:560px){header h1{font-size:1.3rem}.logo{height:48px}}
@media (prefers-reduced-motion:reduce){*{transition:none!important}}
</style>

<div class="wrap">
  <header>
    <img class="logo" alt="Farmácia da Liga" src="data:image/png;base64,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">
    <div class="hgrow">
      <h1>Relatórios de Campanhas</h1>
      <p>Dados das campanhas, emissão de relatórios por marca e controlo da regularização</p>
    </div>
    <div class="save" id="saveState" role="status"><i></i><span id="saveTxt">A ligar…</span></div>
  </header>

  <nav class="tabs" role="tablist" aria-label="Secções">
    <button role="tab" id="tab-dados" aria-controls="sec-dados" aria-selected="true">Dados <span class="n" id="nDados">0</span></button>
    <button role="tab" id="tab-emitir" aria-controls="sec-emitir" aria-selected="false">Emitir relatório</button>
    <button role="tab" id="tab-arquivo" aria-controls="sec-arquivo" aria-selected="false">Relatórios emitidos <span class="n" id="nRep">0</span></button>
  </nav>

  <!-- DADOS -->
  <section id="sec-dados" role="tabpanel" aria-labelledby="tab-dados" class="panel">
    <div class="bar">
      <button class="primary" id="impBtn" type="button"><span class="mi">upload_file</span>Importar Excel</button>
      <input type="file" id="impFile" accept=".xls,.xlsx,.xlsm,.csv" hidden>
      <span class="sep"></span>
      <button class="ghost sm" id="undoBtn" type="button" title="Desfazer (Ctrl+Z)"><span class="mi">undo</span>Desfazer</button>
      <button class="ghost sm" id="redoBtn" type="button" title="Refazer (Ctrl+Y)"><span class="mi">redo</span>Refazer</button>
      <button class="ghost sm" id="addRowBtn" type="button"><span class="mi">add</span>Linha</button>
      <button class="danger sm" id="delRowBtn" type="button"><span class="mi">delete</span>Apagar linhas selecionadas</button>
      <button class="ghost sm" id="bulkBtn" type="button" aria-expanded="false" aria-controls="bulkBox"><span class="mi">edit_note</span>Alterar em massa</button>
      <button class="ghost sm" id="clrFltBtn" type="button"><span class="mi">filter_alt_off</span>Limpar pesquisa</button>
      <span class="grow"></span>
      <button class="ghost sm" id="expBtn" type="button"><span class="mi">download</span>Exportar para Excel</button>
    </div>
    <div class="imp" id="impBox" hidden role="region" aria-labelledby="impTitle">
      <h3 id="impTitle"></h3>
      <p id="impInfo"></p>
      <div class="acts">
        <label class="opt"><input type="checkbox" id="impDup" checked> Ignorar linhas que já existem</label>
        <span class="grow"></span>
        <button class="ghost" type="button" id="impCancel">Cancelar</button>
        <button class="primary" type="button" id="impOk">Adicionar aos dados</button>
      </div>
    </div>
    <div class="imp" id="bulkBox" hidden role="region" aria-labelledby="bulkTitle">
      <h3 id="bulkTitle">Alterar em massa</h3>
      <div class="filters" style="margin-bottom:6px">
        <div><label class="f" for="bkScope">Aplicar a</label><select id="bkScope"><option value="vis">Todas as linhas visíveis (pesquisa e marcas atuais)</option><option value="sel">Só as linhas selecionadas na grelha</option></select></div>
        <div><label class="f" for="bkOp">O que fazer</label><select id="bkOp">
          <option value="set">Escrever o mesmo valor ou fórmula</option><option value="rep">Procurar e substituir texto</option>
          <option value="add">Somar um número</option><option value="mul">Multiplicar por um número</option>
          <option value="clr">Apagar o conteúdo</option><option value="val">Converter fórmulas em valores</option></select></div>
        <div id="bkColW"><label class="f" for="bkCol">Coluna</label><select id="bkCol"></select></div>
        <div id="bkValW"><label class="f" for="bkVal" id="bkValL">Valor</label><input id="bkVal" autocomplete="off"></div>
        <div id="bkRepW" hidden><label class="f" for="bkRep">Substituir por</label><input id="bkRep" autocomplete="off"></div>
      </div>
      <p class="hint" id="bkHint"></p>
      <div class="acts"><span id="bkInfo" style="font-weight:600"></span><span class="grow"></span><button class="ghost" type="button" id="bkCancel">Fechar</button><button class="primary" type="button" id="bkOk">Aplicar</button></div>
    </div>
    <div class="bar" id="delAsk" hidden>
      <span id="delAskTxt" style="color:var(--danger);font-weight:600"></span>
      <button class="danger sm" type="button" id="delYes">Apagar</button>
      <button class="ghost sm" type="button" id="delNo">Cancelar</button>
    </div>
    <div class="filters" style="grid-template-columns:minmax(0,2fr) minmax(0,1.3fr) auto;margin-bottom:8px">
      <div><label class="f" for="gQ">Pesquisar</label><input type="search" id="gQ" placeholder="Designação, CNP, N.º de atendimento, campanha…" autocomplete="off"></div>
      <div class="ms">
        <label class="f" for="msBtn">Marcas</label>
        <button type="button" class="msbtn" id="msBtn" aria-expanded="false" aria-controls="msPop"><span id="msTxt">Todas as marcas</span><span class="mi" aria-hidden="true">expand_more</span></button>
        <div class="mspop" id="msPop" hidden>
          <input type="search" id="msQ" placeholder="Procurar marca" aria-label="Procurar marca" autocomplete="off">
          <div class="msacts"><button type="button" class="link" id="msAll">Marcar as visíveis</button><button type="button" class="link" id="msNone">Limpar (todas as marcas)</button></div>
          <div class="mslist" id="msList" role="group" aria-label="Marcas"></div>
          <div class="msfoot"><span id="msCount"></span><button type="button" class="primary sm" id="msClose">Fechar</button></div>
        </div>
      </div>
      <div class="hint" id="gCount" role="status" style="padding-bottom:8px"></div>
    </div>
    <div class="chips" id="msChips"></div>
    <p class="hint">Funciona como no Excel: clique duas vezes ou escreva para editar, comece por = para usar fórmulas como no Excel português (ex.: =J5*0,3*E5 ou =SOMA(L1:L20); J = PVP, E = Qt, L = Valor) — depois de escrever = ou um sinal (+ - * / ;) pode clicar ou arrastar sobre as células em vez de escrever a referência, Ctrl+C / Ctrl+V para copiar e colar, arraste o canto da célula para copiar para baixo, botão direito para inserir ou apagar linhas, clique duas vezes no título da coluna para ordenar. As alterações ficam guardadas automaticamente.</p>
    <div class="fbar" aria-live="polite"><b id="fbName">—</b><span class="fx">fx</span><span id="fbVal"></span></div>
    <div id="gridBox"><div class="empty" id="gridEmpty">A carregar os dados…</div><div id="grid"></div></div>
    <div class="msg" id="dMsg" role="status"></div>
  </section>

  <!-- EMITIR -->
  <section id="sec-emitir" role="tabpanel" aria-labelledby="tab-emitir" hidden>
    <div class="emit">
      <div class="panel brands">
        <h2>1. Escolha as marcas</h2>
        <input type="search" id="bQ" placeholder="Procurar marca" aria-label="Procurar marca">
        <div class="hint">Clique numa marca para a juntar ou tirar; pode escolher várias para o mesmo PDF. Entre parênteses: linhas ainda não incluídas em relatórios.</div>
        <div class="msfoot"><span id="bSel">Nenhuma marca escolhida</span><button type="button" class="link" id="bClear" hidden>Limpar seleção</button></div>
        <div class="blist" id="bList" role="group" aria-label="Marcas"></div>
      </div>
      <div class="panel" id="emitPanel">
        <div class="empty" id="emitEmpty">Escolha uma marca à esquerda para ver as suas linhas.</div>
        <div id="emitBody" hidden>
          <h2 id="eTitle">2. Selecione as linhas</h2>
          <div class="filters">
            <div><label class="f" for="eDe">Data de</label><input type="date" id="eDe"></div>
            <div><label class="f" for="eAte">até</label><input type="date" id="eAte"></div>
            <div><label class="opt"><input type="checkbox" id="eSoNovas" checked> Só linhas ainda não emitidas</label></div>
          </div>
          <div class="tw"><table class="t" id="eTable"></table></div>
          <div class="tot" id="eTot" role="status"></div>
          <h2>3. Dados do relatório</h2>
          <div class="form" style="margin-top:0;padding-top:0;border-top:0">
            <div class="wide"><label class="f" for="fTit">Nome do relatório</label><input id="fTit"></div>
            <div><label class="f" for="fTrat">Tratamento / envio</label><input id="fTrat" list="dlTrat" placeholder="ex.: Enviado por email"></div>
            <div><label class="f" for="fEnt">Data de entrega</label><input type="date" id="fEnt"></div>
            <div><label class="f" for="fModo">Modo de regularização</label><input id="fModo" list="dlModo" placeholder="ex.: Nota de crédito"></div>
            <div><label class="f" for="fReg">Data de regularização</label><input type="date" id="fReg"></div>
            <div class="wide"><label class="f" for="fNotas">Notas</label><input id="fNotas" placeholder="opcional"></div>
            <div class="wide end"><span class="hint">Pode preencher ou alterar estes campos mais tarde, na lista de relatórios emitidos.</span><button class="primary" type="button" id="genBtn"><span class="mi">picture_as_pdf</span>Gerar PDF e guardar</button></div>
          </div>
          <div class="msg" id="eMsg" role="status"></div>
        </div>
      </div>
    </div>
  </section>

  <!-- ARQUIVO -->
  <section id="sec-arquivo" role="tabpanel" aria-labelledby="tab-arquivo" class="panel" hidden>
    <div class="seg" id="seg" role="group" aria-label="Filtrar por estado"></div>
    <div class="bar">
      <input type="search" id="rQ" placeholder="Pesquisar por marca, nome, tratamento ou notas" aria-label="Pesquisar relatórios" style="max-width:420px">
      <span class="grow"></span>
      <span class="hint" id="rCount"></span>
    </div>
    <div style="overflow-x:auto"><table class="t rep" id="rTable"></table></div>
    <div class="msg" id="rMsg" role="status"></div>
  </section>
</div>

<datalist id="dlTrat"><option value="Enviado por email"><option value="Entregue ao delegado"><option value="Enviado por correio"><option value="Carregado na plataforma do laboratório"><option value="Enviado ao armazenista"></datalist>
<datalist id="dlModo"><option value="Nota de crédito"><option value="Transferência bancária"><option value="Produto"><option value="Desconto em fatura"><option value="Cheque"></datalist>

<div class="viewer" id="viewer" hidden role="dialog" aria-modal="true" aria-labelledby="vTitle">
  <div class="vbar">
    <strong id="vTitle"></strong>
    <div class="vacts"><button class="ghost" type="button" id="vDl"><span class="mi">download</span>Descarregar PDF</button><button class="primary" type="button" id="vClose">Fechar</button></div>
  </div>
  <div class="vbody" id="vBody"></div>
</div>

<script src="https://cdn.jsdelivr.net/npm/jsuites@5.0.25/dist/jsuites.js"></script>
<script src="https://cdn.jsdelivr.net/npm/jspreadsheet-ce@4.13.4/dist/index.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/jspdf-autotable/3.8.2/jspdf.plugin.autotable.min.js"></script>
<script>
"use strict";
const $=id=>document.getElementById(id);
const PDFJS='https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js', PDFJS_WORKER='https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';
const FARM={nome:'Farmácia da Liga das A.S.M. de V.N. Gaia',morada:'Rua Marquês Sá da Bandeira, 344 · 4400-217 Vila Nova de Gaia',nif:'NIF 501064974',email:'liga.mutuos.vng@farmalink.pt'};
const SEM='(Sem marca)';
// colunas: índice 0 é o identificador interno (escondido)
const COLS=[
  {k:'id',t:'id',type:'hidden'},
  {k:'data',t:'Data',type:'calendar',w:96},
  {k:'at',t:'N.º At.',type:'text',w:72},
  {k:'cnp',t:'CNP',type:'text',w:74},
  {k:'des',t:'Designação',type:'text',w:250,align:'left',min:105,flex:5},
  {k:'qt',t:'Qt',type:'numeric',w:46,num:'int'},
  {k:'marca',t:'Marca',type:'text',w:110,align:'left',min:70,flex:2},
  {k:'camp',t:'Campanha',type:'text',w:170,align:'left',min:70,flex:3},
  {k:'orig',t:'Origem',type:'text',w:110,align:'left',min:70,flex:2},
  {k:'tipo',t:'Tipo',type:'text',w:100,align:'left',min:55,flex:1.5},
  {k:'pvp',t:'PVP',type:'numeric',w:62,num:'eur',align:'right'},
  {k:'cond',t:'Cond.',type:'text',w:68,align:'right'},
  {k:'valor',t:'Valor',type:'numeric',w:64,num:'eur',align:'right'},
  {k:'op',t:'Operador',type:'text',w:86}
];
const I=Object.fromEntries(COLS.map((c,i)=>[c.k,i]));
const NUMC=new Set(COLS.map((c,i)=>c.num?i:-1).filter(i=>i>=0));
// Na grelha o identificador fica na última coluna (escondida), para que as letras comecem em A = Data
const NG=COLS.length, IDG=NG-1;
const gx=i=>i===0?IDG:i-1, sx=g=>g===IDG?0:g+1;
const toGrid=r=>r.slice(1).concat([r[0]]);
const LET=g=>String.fromCharCode(65+g);
const isF=v=>typeof v==='string'&&v.charAt(0)==='=';
// Fórmulas: letras maiúsculas (fora de texto entre aspas), vírgula decimal em números → ponto, ; → ,
const PTFN={SOMA:'SUM','MÉDIA':'AVERAGE',MEDIA:'AVERAGE',ARRED:'ROUND','MÁXIMO':'MAX',MAXIMO:'MAX','MÍNIMO':'MIN',MINIMO:'MIN',SE:'IF',CONTAR:'COUNT','CONTAR.SE':'COUNTIF','SOMA.SE':'SUMIF',ABS:'ABS',PRODUTO:'PRODUCT'};
const ptFn=t=>t.replace(/([A-ZÁÉÍÓÚÂÊÔÃÕÇ.]+)\s*\(/g,(m,n)=>(PTFN[n]||n)+'(');
function normF(f){
  return f.split('"').map((part,k)=>k%2?part:ptFn(part.toUpperCase()).replace(/(\d),(\d)/g,'$1.$2').replace(/;/g,',')).join('"');
}
const gBlank=r=>r.every((v,g)=>g===IDG||v===''||v==null);

// ---------- utilitários ----------
const pad=n=>String(n).padStart(2,'0');
const ymd=d=>d.getFullYear()+'-'+pad(d.getMonth()+1)+'-'+pad(d.getDate());
const dmy=s=>{ if(!s) return ''; const m=String(s).match(/^(\d{4})-(\d{2})-(\d{2})/); return m?m[3]+'-'+m[2]+'-'+m[1]:String(s); };
const eur=n=>(Math.round((+n||0)*100)/100).toLocaleString('pt-PT',{minimumFractionDigits:2,maximumFractionDigits:2}).replace(/ | /g,' ')+' €';
const intf=n=>(+n||0).toLocaleString('pt-PT').replace(/ | /g,' ');
function num(v){ if(typeof v==='number') return isFinite(v)?v:null; if(v==null) return null; const s=String(v).replace(/[€\s ]/g,''); if(s==='') return null;
  const t=s.includes(',')?s.replace(/\./g,'').replace(',','.'):s; const n=parseFloat(t); return isNaN(n)?null:n; }
function toYmd(d){
  if(d==null||d==='') return '';
  if(d instanceof Date) return isNaN(d)?'':ymd(d);
  if(typeof d==='number'){ if(!window.XLSX) return ''; const o=XLSX.SSF.parse_date_code(d); return o?o.y+'-'+pad(o.m)+'-'+pad(o.d):''; }
  const s=String(d).trim(); let m=s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/); if(m) return m[1]+'-'+pad(+m[2])+'-'+pad(+m[3]);
  m=s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d{2})(?!\d)/); if(!m) return '';
  let y=+m[3]; if(y<100) y+=2000; return y+'-'+pad(+m[2])+'-'+pad(+m[1]);
}
const txt=v=>v==null?'':String(v).replace(/\s+/g,' ').trim();
const uid=()=>Math.random().toString(36).slice(2,8)+Date.now().toString(36).slice(-4);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const brandOf=r=>txt(r[I.marca])||SEM;
const nowStamp=()=>{ const d=new Date(); return dmy(ymd(d))+' '+pad(d.getHours())+':'+pad(d.getMinutes()); };
function cleanCell(i,v,keepF){
  if(keepF&&isF(v)) return v;
  if(i===0) return v?String(v):'';
  if(i===I.data) return toYmd(v);
  if(NUMC.has(i)){ const n=num(v); return n==null?'':n; }
  return txt(v);
}
const isBlank=r=>r.every((v,i)=>i===0||v===''||v==null);
const keyOf=r=>[r[I.data],r[I.at],r[I.cnp],r[I.des],r[I.qt],r[I.valor],r[I.camp]].join('|').toLowerCase();

// ---------- estado ----------
let db=null, assets=null, downloads=null, canWrite=true;
let grid=null, REPORTS=[], reportedBy=new Map();
const CHUNK=400; let savedChunks={};
let saveTimer=null, saving=false, saveAgain=false, gridReady=false;

function setSave(t,cls){ const s=$('saveState'); s.className='save'+(cls?' '+cls:''); $('saveTxt').textContent=t; }

// Dados limpos e atuais, a partir da grelha
// (as fórmulas são resolvidas para o seu resultado; keepF mantém o texto da fórmula, para guardar)
function currentRows(keepF){
  if(!grid) return [];
  const data=grid.options.data; const out=[];
  for(let y=0;y<data.length;y++){
    const raw=data[y];
    const r=COLS.map((c,i)=>{ let v=raw[gx(i)]; if(!keepF&&isF(v)){ try{ v=grid.records[y][gx(i)].textContent; }catch(e){ v=''; } } return cleanCell(i,v,keepF); });
    if(isBlank(r)) continue;
    if(!r[0]){ r[0]=uid(); raw[IDG]=r[0]; }
    out.push(r);
  }
  return out;
}

// ---------- persistência (documentos de 400 linhas) ----------
async function loadRows(){
  if(!db) return [];
  const snap=await db.collection('linhas').get();
  const docs=snap.docs.filter(d=>/^c\d+$/.test(d.id)).sort((a,b)=>a.id.localeCompare(b.id));
  let rows=[]; savedChunks={};
  for(const d of docs){ const x=d.data(); const rs=Array.isArray(x.rows)?x.rows:[]; savedChunks[d.id]=JSON.stringify(rs); rows=rows.concat(rs); }
  return rows.map(r=>COLS.map((c,i)=>r[i]??''));
}
function scheduleSave(){
  if(!gridReady) return;
  setSave('Alterações por guardar…','busy');
  clearTimeout(saveTimer); saveTimer=setTimeout(saveRows,1200);
  refreshDerived();
}
async function saveRows(){
  if(!db){ setSave('Sem ligação ao armazenamento: as alterações não ficam guardadas','err'); return; }
  if(saving){ saveAgain=true; return; }
  saving=true; setSave('A guardar…','busy');
  try{
    const rows=currentRows(true); const next={};
    for(let i=0,k=0;i<rows.length||k===0;i+=CHUNK,k++){ next['c'+String(k).padStart(4,'0')]=rows.slice(i,i+CHUNK); if(i+CHUNK>=rows.length) break; }
    for(const [id,rs] of Object.entries(next)){
      const js=JSON.stringify(rs);
      if(savedChunks[id]!==js){ await db.doc('linhas/'+id).set({rows:rs,n:rs.length}); savedChunks[id]=js; }
    }
    for(const id of Object.keys(savedChunks)) if(!(id in next)){ await db.doc('linhas/'+id).delete(); delete savedChunks[id]; }
    setSave('Guardado · '+intf(rows.length)+' linhas');
  }catch(e){
    console.error(e);
    setSave(e&&e.code==='quota_exceeded'?'Espaço cheio: não foi possível guardar':'Erro ao guardar — a tentar de novo','err');
    if(!(e&&(e.code==='quota_exceeded'||e.code==='invalid_argument'))) setTimeout(scheduleSave,4000);
  }finally{
    saving=false; if(saveAgain){ saveAgain=false; saveRows(); }
  }
}

// ---------- grelha ----------
const PT={noRecordsFound:'Sem registos',showingPage:'Página {0} de {1}',show:'Mostrar ',search:'Pesquisar',entries:' linhas',
  columnName:'Nome da coluna',insertANewColumnBefore:'Inserir coluna antes',insertANewColumnAfter:'Inserir coluna depois',deleteSelectedColumns:'Apagar colunas selecionadas',
  renameThisColumn:'Mudar nome da coluna',orderAscending:'Ordenar A → Z',orderDescending:'Ordenar Z → A',insertANewRowBefore:'Inserir linha acima',insertANewRowAfter:'Inserir linha abaixo',
  deleteSelectedRows:'Apagar linhas selecionadas',editComments:'Editar comentário',addComments:'Adicionar comentário',comments:'Comentários',clearComments:'Limpar comentários',
  copy:'Copiar',paste:'Colar',saveAs:'Guardar como',about:'Sobre',areYouSureToDeleteTheSelectedRows:'Apagar as linhas selecionadas?',areYouSureToDeleteTheSelectedColumns:'Apagar as colunas selecionadas?',
  thisActionWillDestroyAnyExistingMergedCellsAreYouSure:'Continuar?',thisActionWillClearYourSearchResultsAreYouSure:'Isto limpa a pesquisa. Continuar?',
  thereIsAConflictWithAnotherMergedCell:'Conflito com outra célula unida',invalidMergeProperties:'Inválido',cellAlreadyMerged:'Célula já unida',noCellsSelected:'Nenhuma célula selecionada'};
// O visualizador não mostra caixas de confirmação do navegador: as ações da grelha avançam (e podem ser desfeitas com Ctrl+Z)
try{ window.confirm=()=>true; window.alert=m=>{ dMsg(String(m),'err'); }; }catch(e){}

function dMsg(t,cls){ const m=$('dMsg'); m.textContent=t||''; m.className='msg'+(cls?' '+cls:''); }

function buildGrid(rows){
  $('gridEmpty').hidden=true;
  const h=Math.max(320,Math.min(window.innerHeight-260,760));
  grid=jspreadsheet($('grid'),{
    data:rows.length?rows.map(toGrid):[COLS.map(()=> '')],
    columns:COLS.slice(1).concat([COLS[0]]).map((c,g)=>{
      const o={title:c.k==='id'?'id':LET(g)+' · '+c.t,type:c.type,width:c.w||80,align:c.align||'center',name:c.k};
      if(c.type==='calendar') o.options={format:'DD-MM-YYYY',months:['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'],weekdays:['Domingo','Segunda','Terça','Quarta','Quinta','Sexta','Sábado'],weekdays_short:['D','S','T','Q','Q','S','S'],textDone:'OK',textReset:'Limpar',textUpdate:'OK'};
      if(c.num==='eur'){ o.mask='#.##0,00'; o.decimal=','; }
      return o;
    }),
    text:PT,
    tableOverflow:true, tableHeight:h+'px', tableWidth:'100%',
    lazyLoading:true, loadingSpin:true,
    filters:false, search:true, columnSorting:true,
    allowInsertColumn:false, allowDeleteColumn:false, allowRenameColumn:false, allowManualInsertColumn:false, columnDrag:false,
    allowExport:false, about:false, wordWrap:false, minSpareRows:0, defaultColAlign:'center',
    contextMenu:gridMenu,
    onbeforechange:(el,cell,x,y,v)=>{ x=sx(+x); if(isF(v)) return normF(v); if(x===I.data){ const t=toYmd(v); return t||(txt(v)?v:''); } if(NUMC.has(x)&&typeof v==='string'){ const n=num(v); return n==null?(v.trim()===''?'':v):n; } return v; },
    onafterchanges:()=>scheduleSave(),
    oninsertrow:()=>{ scheduleSave(); reapply(); },
    ondeleterow:()=>{ scheduleSave(); reapply(); },
    onundo:()=>{ scheduleSave(); reapply(); },
    onredo:()=>{ scheduleSave(); reapply(); },
    onsort:()=>{ scheduleSave(); reapply(); },
    onmoverow:()=>{ scheduleSave(); reapply(); },
    onselection:(el,x1,y1,x2,y2)=>{ LASTSEL=[+y1,+y2]; try{ fbShow(+x1,+y1,grid.options.data[+y1][+x1]); }catch(e){} if(!$('bulkBox').hidden) bkUi(); }
  });
  gridReady=true;
  fitColumns();
}
// Ajusta as colunas de texto à largura disponível para que todas as colunas fiquem visíveis
function fitColumns(){
  if(!grid||!grid.colgroup) return;
  const avail=$('gridBox').clientWidth-50-40;
  const fixed=COLS.reduce((s,c,i)=>i===0||c.flex?s:s+c.w,0);
  const flexCols=COLS.map((c,i)=>c.flex?i:-1).filter(i=>i>0);
  const weight=flexCols.reduce((s,i)=>s+COLS[i].flex,0);
  let room=avail-fixed;
  const minSum=flexCols.reduce((s,i)=>s+COLS[i].min,0);
  if(room<minSum) room=minSum;
  flexCols.forEach(i=>{ const w=Math.max(COLS[i].min,Math.floor(room*COLS[i].flex/weight)); try{ grid.colgroup[gx(i)].setAttribute('width',w); grid.options.columns[gx(i)].width=w; }catch(e){} });
}
let fitTimer=null;

// ---------- fórmulas: clicar ou arrastar sobre células para inserir a referência (como no Excel) ----------
let PTS=null, PDRAG=null;
function fEditor(){ try{ if(!grid||!grid.edition) return null; return grid.edition[0].querySelector('input,textarea'); }catch(e){ return null; } }
function canPoint(el){
  const v=el.value; if(v.charAt(0)!=='=') return false;
  const pos=el.selectionStart;
  if(PTS&&PTS.el===el&&PTS.e===pos&&v.slice(PTS.s,PTS.e)===PTS.ref) return true;
  const ch=v.slice(0,pos).replace(/\s+$/,'').slice(-1);
  return '=+-*/(,;:^&<>'.includes(ch);
}
function clearFref(){ document.querySelectorAll('#grid td.fref').forEach(td=>td.classList.remove('fref')); }
function markFref(x0,y0,x1,y1){
  clearFref(); const xa=Math.min(x0,x1),xb=Math.max(x0,x1),ya=Math.min(y0,y1),yb=Math.max(y0,y1);
  for(let y=ya;y<=yb;y++) for(let x=xa;x<=xb;x++){ try{ grid.records[y][x].classList.add('fref'); }catch(e){} }
}
function fbShow(x,y,val){ $('fbName').textContent=(x!=null&&y!=null&&x<IDG)?LET(x)+(y+1):'—'; $('fbVal').textContent=val==null?'':String(x===gx(I.data)&&!isF(val)?dmy(val):val); }
function putRef(el,d){
  const xa=Math.min(d.x0,d.x1),xb=Math.max(d.x0,d.x1),ya=Math.min(d.y0,d.y1),yb=Math.max(d.y0,d.y1);
  const ref=LET(xa)+(ya+1)+((xa!==xb||ya!==yb)?':'+LET(xb)+(yb+1):'');
  const v=el.value; let a,b;
  if(PTS&&PTS.el===el&&PTS.e===el.selectionStart&&v.slice(PTS.s,PTS.e)===PTS.ref){ a=PTS.s; b=PTS.e; } else { a=b=el.selectionStart; }
  el.value=v.slice(0,a)+ref+v.slice(b); PTS={el,s:a,e:a+ref.length,ref};
  el.setSelectionRange(PTS.e,PTS.e); el.focus(); markFref(d.x0,d.y0,d.x1,d.y1); $('fbVal').textContent=el.value;
}
$('grid').addEventListener('mousedown',e=>{
  const el=fEditor(); if(!el) return;
  const td=e.target.closest('td[data-x][data-y]'); if(!td||td===grid.edition[0]||td.closest('thead')) return;
  if(!canPoint(el)) return;
  e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation();
  const x=+td.dataset.x, y=+td.dataset.y; if(x>=IDG) return;
  PDRAG={el,x0:x,y0:y,x1:x,y1:y}; putRef(el,PDRAG);
},true);
$('grid').addEventListener('mouseover',e=>{
  if(!PDRAG) return; const td=e.target.closest('td[data-x][data-y]'); if(!td||td.closest('thead')) return;
  const x=+td.dataset.x, y=+td.dataset.y; if(x>=IDG||(x===PDRAG.x1&&y===PDRAG.y1)) return;
  e.stopPropagation(); PDRAG.x1=x; PDRAG.y1=y; putRef(PDRAG.el,PDRAG);
},true);
$('grid').addEventListener('mousemove',e=>{ if(PDRAG) e.stopPropagation(); },true);
document.addEventListener('mouseup',e=>{ if(PDRAG){ e.stopPropagation(); const el=PDRAG.el; PDRAG=null; el.focus(); } },true);
document.addEventListener('keyup',()=>{ const el=fEditor(); if(el) $('fbVal').textContent=el.value; else { PTS=null; clearFref(); } });
document.addEventListener('mouseup',()=>{ setTimeout(()=>{ if(!fEditor()){ PTS=null; clearFref(); } },0); });
window.addEventListener('resize',()=>{ clearTimeout(fitTimer); fitTimer=setTimeout(fitColumns,150); });
function gridMenu(obj,x,y){
  const items=[];
  if(y!=null){
    items.push({title:'Inserir linha acima',onclick:()=>obj.insertRow(1,parseInt(y),1)});
    items.push({title:'Inserir linha abaixo',onclick:()=>obj.insertRow(1,parseInt(y))});
    items.push({title:'Apagar linhas selecionadas',onclick:()=>deleteSelected()});
    items.push({type:'line'});
  }
  if(x!=null&&y==null){
    items.push({title:'Ordenar A → Z',onclick:()=>obj.orderBy(parseInt(x),0)});
    items.push({title:'Ordenar Z → A',onclick:()=>obj.orderBy(parseInt(x),1)});
    items.push({type:'line'});
  }
  items.push({title:'Copiar',shortcut:'Ctrl + C',onclick:()=>obj.copy(true)});
  items.push({title:'Desfazer',shortcut:'Ctrl + Z',onclick:()=>obj.undo()});
  items.push({title:'Refazer',shortcut:'Ctrl + Y',onclick:()=>obj.redo()});
  return items;
}
let LASTSEL=null;
function selectedRowIdx(){
  if(!grid||!LASTSEL) return [];
  const a=Math.min(LASTSEL[0],LASTSEL[1]), b=Math.max(LASTSEL[0],LASTSEL[1]); const out=[];
  for(let i=b;i>=a;i--) if(i>=0&&i<grid.options.data.length) out.push(i);
  return out;
}
let pendingDel=[];
function deleteSelected(){
  const idx=selectedRowIdx();
  if(!idx.length){ dMsg('Selecione primeiro as linhas a apagar (clique nos números à esquerda; Shift ou Ctrl para várias).','err'); return; }
  pendingDel=idx; const lo=idx[idx.length-1]+1, hi=idx[0]+1; $('delAskTxt').textContent='Apagar '+idx.length+' linha'+(idx.length===1?'':'s')+' ('+(lo===hi?'linha '+lo:'linhas '+lo+' a '+hi)+')?';
  $('delAsk').hidden=false; $('delYes').focus();
}
$('delYes').onclick=()=>{
  $('delAsk').hidden=true;
  if(!pendingDel.length) return;
  if(pendingDel.length>=grid.options.data.length){ grid.setData([COLS.map(()=> '')]); scheduleSave(); }
  else{
    // agrupa índices consecutivos para apagar em blocos
    const desc=pendingDel.slice(); let i=0;
    while(i<desc.length){ let j=i; while(j+1<desc.length&&desc[j+1]===desc[j]-1) j++; grid.deleteRow(desc[j],j-i+1); i=j+1; }
  }
  dMsg(pendingDel.length+' linha'+(pendingDel.length===1?'':'s')+' apagada'+(pendingDel.length===1?'':'s')+'. Pode desfazer com Ctrl+Z.','ok');
  pendingDel=[]; LASTSEL=null;
};
$('delNo').onclick=()=>{ $('delAsk').hidden=true; pendingDel=[]; };
$('delRowBtn').onclick=deleteSelected;
$('undoBtn').onclick=()=>grid&&grid.undo();
$('redoBtn').onclick=()=>grid&&grid.redo();
$('addRowBtn').onclick=()=>{ if(!grid) return; grid.insertRow(1); const y=grid.options.data.length-1; try{ grid.updateSelectionFromCoords(0,y,0,y); grid.content.scrollTop=grid.content.scrollHeight; }catch(e){} };
$('clrFltBtn').onclick=()=>{ $('gQ').value=''; MSEL.clear(); msChanged(); };

// ---------- pesquisa e filtro por marca na grelha ----------
const fold=v=>String(v??'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();
function applyFilter(){
  if(!grid) return;
  const q=fold($('gQ').value.trim()), m=MSEL.size>0;
  const data=grid.options.data, total=data.length;
  if(!q&&!m){ grid.results=null; grid.updateResult(); $('gCount').textContent=''; return; }
  const words=q.split(/\s+/).filter(Boolean); const res=[];
  for(let y=0;y<total;y++){
    const r=data[y];
    if(gBlank(r)){ res.push(y); continue; }
    if(m&&!MSEL.has(txt(r[gx(I.marca)])||SEM)) continue;
    if(words.length){ const hay=fold(r.slice(0,IDG).map((v,g)=>g===gx(I.data)?dmy(v):v).join(' | ')); if(!words.every(w=>hay.includes(w))) continue; }
    res.push(y);
  }
  try{ grid.resetSelection(); }catch(e){}
  grid.pageNumber=0; grid.results=res; grid.updateResult();
  try{ grid.content.scrollTop=0; }catch(e){}
  $('gCount').textContent='A mostrar '+intf(res.length)+' de '+intf(total)+' linhas';
}
let reTimer=null;
function reapply(){ clearTimeout(reTimer); reTimer=setTimeout(()=>{ if($('gQ').value||MSEL.size) applyFilter(); },50); }
let qTimer=null;
$('gQ').addEventListener('input',()=>{ clearTimeout(qTimer); qTimer=setTimeout(applyFilter,200); });
['gQ','msQ'].forEach(id=>$(id).addEventListener('focus',()=>{ try{ if(grid) grid.resetSelection(); if(window.jspreadsheet) jspreadsheet.current=null; }catch(e){} }));
const MSEL=new Set(); let BCOUNT=new Map();
function fillBrandSelect(){
  const cnt=new Map();
  for(const r of (grid?grid.options.data:[])){ if(gBlank(r)) continue; const b=txt(r[gx(I.marca)])||SEM; cnt.set(b,(cnt.get(b)||0)+1); }
  BCOUNT=cnt; let gone=false; for(const b of [...MSEL]) if(!cnt.has(b)){ MSEL.delete(b); gone=true; } if(gone) applyFilter();
  if(!$('msPop').hidden) msRender(); msLabel();
}
const brandList=()=>[...BCOUNT.keys()].sort((a,b)=>a===SEM?-1:b===SEM?1:a.localeCompare(b,'pt',{sensitivity:'base'}));
function msRender(){
  const q=fold($('msQ').value.trim()), L=$('msList'); L.innerHTML='';
  const list=brandList().filter(b=>!q||fold(b).includes(q));
  if(!list.length) L.innerHTML='<div class="hint" style="padding:10px">Nenhuma marca encontrada</div>';
  for(const b of list){
    const l=document.createElement('label'); l.className='msitem';
    const c=document.createElement('input'); c.type='checkbox'; c.checked=MSEL.has(b);
    c.onchange=()=>{ c.checked?MSEL.add(b):MSEL.delete(b); msChanged(); };
    const t=document.createElement('span'); t.textContent=b; const k=document.createElement('small'); k.textContent=BCOUNT.get(b);
    l.append(c,t,k); L.appendChild(l);
  }
  $('msCount').textContent=MSEL.size?MSEL.size+' marca'+(MSEL.size===1?'':'s')+' escolhida'+(MSEL.size===1?'':'s'):'Nenhuma = todas as marcas';
}
function msLabel(){
  const a=[...MSEL];
  $('msTxt').textContent=!a.length?'Todas as marcas':a.length===1?a[0]:a.length+' marcas: '+a.join(', ');
  const C=$('msChips'); C.innerHTML='';
  a.forEach(b=>{ const x=document.createElement('button'); x.type='button'; x.title='Tirar '+b; x.innerHTML=esc(b)+' <span class="mi" aria-hidden="true">close</span>'; x.onclick=()=>{ MSEL.delete(b); msChanged(); }; C.appendChild(x); });
}
function msChanged(){ msLabel(); if(!$('msPop').hidden) msRender(); applyFilter(); }
function msOpen(o){ $('msPop').hidden=!o; $('msBtn').setAttribute('aria-expanded',o); if(o){ $('msQ').value=''; msRender(); $('msQ').focus(); } }
$('msBtn').onclick=()=>msOpen($('msPop').hidden);
$('msClose').onclick=()=>{ msOpen(false); $('msBtn').focus(); };
$('msQ').oninput=msRender;
$('msQ').addEventListener('keydown',e=>{ if(e.key==='Enter'){ e.preventDefault(); const f=$('msList').querySelector('input'); if(f){ f.checked=!f.checked; f.onchange(); } } });
$('msAll').onclick=()=>{ const q=fold($('msQ').value.trim()); brandList().filter(b=>!q||fold(b).includes(q)).forEach(b=>MSEL.add(b)); msChanged(); };
$('msNone').onclick=()=>{ MSEL.clear(); msChanged(); };
document.addEventListener('mousedown',e=>{ if(!$('msPop').hidden&&!e.target.closest('.ms')) msOpen(false); });
document.addEventListener('keydown',e=>{ if(e.key==='Escape'&&!$('msPop').hidden){ msOpen(false); $('msBtn').focus(); } });

// ---------- alterar em massa ----------
const BK_HINT={set:'Pode escrever um valor ou uma fórmula. Numa fórmula, use # para o número da linha: =J#*0,3*E# calcula 30% do PVP vezes a quantidade de cada linha.',
  rep:'Substitui o texto em todas as células da coluna (não distingue maiúsculas de minúsculas).',add:'Soma o número a cada valor da coluna (use um número negativo para subtrair).',
  mul:'Multiplica cada valor da coluna pelo número (ex.: 1,23 para acrescentar 23%).',clr:'Deixa as células da coluna em branco.',val:'Troca todas as fórmulas das linhas escolhidas pelo resultado atual, em todas as colunas.'};
function bkFill(){
  const sel=$('bkCol'); if(sel.options.length) return;
  COLS.slice(1).forEach((c,g)=>{ const o=document.createElement('option'); o.value=g; o.textContent=LET(g)+' · '+c.t; sel.appendChild(o); });
}
function bkRows(){
  if(!grid) return [];
  const data=grid.options.data; let ys=grid.results?grid.results.slice():data.map((_,y)=>y);
  if($('bkScope').value==='sel'){ if(!LASTSEL) return []; const a=Math.min(...LASTSEL), b=Math.max(...LASTSEL); ys=ys.filter(y=>y>=a&&y<=b); }
  return ys.filter(y=>data[y]&&!gBlank(data[y]));
}
function bkUi(){
  const op=$('bkOp').value, g=+$('bkCol').value, numCol=NUMC.has(sx(g));
  $('bkColW').hidden=op==='val'; $('bkValW').hidden=op==='clr'||op==='val'; $('bkRepW').hidden=op!=='rep';
  $('bkValL').textContent=op==='rep'?'Procurar':op==='add'?'Número a somar':op==='mul'?'Multiplicar por':'Valor';
  $('bkHint').textContent=BK_HINT[op]+((op==='add'||op==='mul')&&!numCol?' Atenção: escolha uma coluna de números (Qt, PVP ou Valor).':'');
  const n=bkRows().length;
  $('bkInfo').textContent=$('bkScope').value==='sel'&&!LASTSEL?'Selecione primeiro linhas na grelha.':'Vai aplicar a '+intf(n)+' linha'+(n===1?'':'s')+'.';
  $('bkOk').disabled=!n;
}
$('bulkBtn').onclick=()=>{ const o=$('bulkBox').hidden; bkFill(); $('bulkBox').hidden=!o; $('bulkBtn').setAttribute('aria-expanded',o); if(o){ bkUi(); $('bkOp').focus(); } };
$('bkCancel').onclick=()=>{ $('bulkBox').hidden=true; $('bulkBtn').setAttribute('aria-expanded',false); };
['bkScope','bkOp','bkCol'].forEach(id=>$(id).addEventListener('change',bkUi));
['bkScope','bkOp','bkCol','bkVal','bkRep'].forEach(id=>$(id).addEventListener('focus',()=>{ try{ if(window.jspreadsheet) jspreadsheet.current=null; }catch(e){} }));
$('bkOk').onclick=()=>{
  const op=$('bkOp').value, g=+$('bkCol').value, i=sx(g), ys=bkRows(), data=grid.options.data;
  const val=$('bkVal').value, changes=[];
  const shown=(y,gg)=>{ const v=data[y][gg]; if(isF(v)){ try{ return grid.records[y][gg].textContent; }catch(e){ return ''; } } return v; };
  if((op==='add'||op==='mul')){ if(!NUMC.has(i)){ dMsg('Escolha uma coluna de números (Qt, PVP ou Valor) para somar ou multiplicar.','err'); return; } if(num(val)==null){ dMsg('Escreva o número a usar.','err'); return; } }
  if(op==='rep'&&!val){ dMsg('Escreva o texto a procurar.','err'); return; }
  const re=op==='rep'?new RegExp(val.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'),'gi'):null;
  for(const y of ys){
    if(op==='val'){ for(let gg=0;gg<IDG;gg++){ const v=data[y][gg]; if(isF(v)) changes.push({x:gg,y,value:cleanCell(sx(gg),shown(y,gg))}); } continue; }
    const old=data[y][g]; let nv;
    if(op==='set'){ nv=isF(val)?normF(val.replace(/#/g,String(y+1))):cleanCell(i,val); }
    else if(op==='clr') nv='';
    else if(op==='rep'){ const t=String(old??''); if(!re.test(t)){ re.lastIndex=0; continue; } re.lastIndex=0; nv=cleanCell(i,t.replace(re,$('bkRep').value)); }
    else { const n=num(shown(y,g)); if(n==null) continue; const k=num(val); nv=Math.round((op==='add'?n+k:n*k)*10000)/10000; }
    if(nv===old) continue;
    changes.push({x:g,y,value:nv});
  }
  if(!changes.length){ dMsg('Nenhuma célula precisava de ser alterada.','ok'); return; }
  grid.setValue(changes);
  dMsg(intf(changes.length)+' célula'+(changes.length===1?'':'s')+' alterada'+(changes.length===1?'':'s')+'. Pode desfazer com Ctrl+Z ou com o botão Desfazer.','ok');
  bkUi();
};

// ---------- importação ----------
const normH=v=>String(v??'').normalize('NFD').replace(/[̀-ͯ]/g,'').toUpperCase().replace(/[^A-Z0-9]/g,'');
const HMAP={DATA:'data',NAT:'at',NOAT:'at',NATEND:'at',ATENDIMENTO:'at',CNP:'cnp',DESIGNACAO:'des',DESCRICAO:'des',PRODUTO:'des',
  QT:'qt',QTD:'qt',QUANT:'qt',QUANTIDADE:'qt',MARCA:'marca',CAMPANHA:'camp',ORIGEM:'orig',TIPO:'tipo',PVP:'pvp',COND:'cond',CONDICAO:'cond',VALOR:'valor',OPERADOR:'op'};
function parseWorkbook(wb){
  const out=[];
  for(const name of wb.SheetNames){
    const aoa=XLSX.utils.sheet_to_json(wb.Sheets[name],{header:1,raw:true,defval:null,blankrows:false});
    let map=null;
    for(const row of aoa){
      if(!row) continue;
      const keys={}; let hits=0;
      row.forEach((v,ci)=>{ const k=HMAP[normH(v)]; if(k&&!(k in keys)){ keys[k]=ci; hits++; } });
      if(hits>=4&&('data' in keys)&&(('marca' in keys)||('des' in keys))){ map=keys; continue; }
      if(!map) continue;
      const d=toYmd(row[map.data]); if(!d) continue;
      const r=COLS.map(()=> '');
      for(const [k,ci] of Object.entries(map)){ r[I[k]]=cleanCell(I[k],row[ci]); }
      if(!txt(r[I.des])&&r[I.valor]==='') continue;
      out.push(r);
    }
  }
  return out;
}
let IMP=null;
$('impBtn').onclick=()=>$('impFile').click();
$('impFile').onchange=async e=>{
  const f=e.target.files[0]; e.target.value=''; if(!f) return;
  dMsg('A ler '+f.name+'…');
  try{
    const wb=XLSX.read(await f.arrayBuffer(),{type:'array',cellDates:true});
    const rows=parseWorkbook(wb);
    if(!rows.length){ dMsg('Não encontrei linhas de campanhas em "'+f.name+'". O ficheiro tem de ter uma linha de títulos com DATA, DESIGNAÇÃO, MARCA, VALOR…','err'); return; }
    const have=new Set(currentRows().map(keyOf));
    const dup=rows.filter(r=>have.has(keyOf(r))).length;
    const ds=rows.map(r=>r[I.data]).filter(Boolean).sort();
    IMP={name:f.name,rows,dup};
    $('impTitle').textContent=f.name;
    $('impInfo').textContent=intf(rows.length)+' linhas lidas, de '+dmy(ds[0])+' a '+dmy(ds[ds.length-1])+'. '+(dup?intf(dup)+' já existem nos dados atuais.':'Nenhuma repetida.')+' As novas linhas são acrescentadas no fim.';
    $('impDup').parentElement.hidden=!dup;
    $('impBox').hidden=false; dMsg('');
  }catch(err){ console.error(err); dMsg('Não foi possível ler o ficheiro. Confirme que é um Excel (.xls ou .xlsx).','err'); }
};
$('impCancel').onclick=()=>{ IMP=null; $('impBox').hidden=true; };
$('impOk').onclick=()=>{
  if(!IMP) return;
  const cur=currentRows(true); const have=new Set(currentRows().map(keyOf));
  let add=IMP.rows; if($('impDup').checked) add=add.filter(r=>!have.has(keyOf(r)));
  add=add.map(r=>{ const c=r.slice(); c[0]=uid(); return c; });
  $('impBox').hidden=true;
  if(!add.length){ dMsg('Nada a acrescentar: todas as linhas já existiam.','ok'); IMP=null; return; }
  const all=cur.concat(add);
  grid.results=null;
  grid.setData(all.map(toGrid)); fillBrandSelect(); reapply();
  dMsg(intf(add.length)+' linhas acrescentadas a partir de '+IMP.name+'.','ok'); IMP=null;
  scheduleSave();
};

// ---------- exportar ----------
$('expBtn').onclick=async()=>{
  const rows=currentRows();
  const aoa=[COLS.slice(1).map(c=>c.t.toUpperCase())].concat(rows.map(r=>r.slice(1).map((v,i)=>i+1===I.data?dmy(v):v)));
  const ws=XLSX.utils.aoa_to_sheet(aoa); ws['!cols']=COLS.slice(1).map(c=>({wch:Math.round((c.w||80)/7)}));
  const wb=XLSX.utils.book_new(); XLSX.utils.book_append_sheet(wb,ws,'Campanhas');
  const buf=XLSX.write(wb,{type:'array',bookType:'xlsx'});
  if(!downloads){ dMsg('A transferência de ficheiros não está disponível nesta vista.','err'); return; }
  try{ await downloads.save({filename:'Campanhas_'+dmy(ymd(new Date()))+'.xlsx',data:new Blob([buf],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'})}); }
  catch(e){ if(!(e&&e.code==='declined')) dMsg('Não foi possível exportar.','err'); }
};

// ---------- separadores ----------
const TABS=['dados','emitir','arquivo'];
function showTab(t){
  TABS.forEach(k=>{ $('tab-'+k).setAttribute('aria-selected',k===t); $('sec-'+k).hidden=k!==t; });
  if(t==='emitir') renderBrands(), renderEmit();
  if(t==='arquivo') renderReports();
  if(t==='dados') setTimeout(fitColumns,0);
  try{ history.replaceState(null,'','#'+t); }catch(e){}
}
TABS.forEach(k=>$('tab-'+k).onclick=()=>showTab(k));

// ---------- derivados ----------
function rebuildReported(){ reportedBy=new Map(); for(const r of REPORTS) for(const id of (r.rowIds||[])) reportedBy.set(id,r); }
let derivedTimer=null;
function refreshDerived(){
  clearTimeout(derivedTimer);
  derivedTimer=setTimeout(()=>{ $('nDados').textContent=intf(currentRows().length); fillBrandSelect(); if(!$('sec-emitir').hidden){ renderBrands(); renderEmit(); } },300);
}

// ---------- emitir ----------
const EBR=new Set(); const UNCHECK=new Set();
const sortB=a=>a.slice().sort((x,y)=>x===SEM?-1:y===SEM?1:x.localeCompare(y,'pt',{sensitivity:'base'}));
function marcasLabel(){ const a=sortB([...EBR]); return a.length<=3?a.join(', '):a.slice(0,3).join(', ')+' e mais '+(a.length-3); }
$('bClear').onclick=()=>{ EBR.clear(); UNCHECK.clear(); $('fTit').dataset.auto='1'; renderBrands(); renderEmit(); };
function brandStats(){
  const m=new Map();
  for(const r of currentRows()){ const b=brandOf(r); const o=m.get(b)||{n:0,novas:0}; o.n++; if(!reportedBy.has(r[0])) o.novas++; m.set(b,o); }
  return [...m.entries()].sort((a,b)=>a[0]===SEM?-1:b[0]===SEM?1:a[0].localeCompare(b[0],'pt',{sensitivity:'base'}));
}
function renderBrands(){
  const q=$('bQ').value.trim().toLowerCase(); const L=$('bList'); L.innerHTML='';
  const all=brandStats(); const have=new Set(all.map(x=>x[0])); for(const b of [...EBR]) if(!have.has(b)) EBR.delete(b);
  $('bSel').textContent=EBR.size?EBR.size+' marca'+(EBR.size===1?'':'s')+' escolhida'+(EBR.size===1?'':'s'):'Nenhuma marca escolhida'; $('bClear').hidden=!EBR.size;
  const fq=fold(q); const st=all.filter(([b])=>!fq||fold(b).includes(fq));
  if(!st.length){ L.innerHTML='<div class="empty" style="border:0">Sem marcas</div>'; return; }
  for(const [b,o] of st){
    const btn=document.createElement('button'); btn.type='button'; btn.setAttribute('aria-pressed',EBR.has(b));
    btn.innerHTML='<span>'+esc(b)+'</span><small>'+o.n+' (<b>'+o.novas+'</b>)</small>';
    btn.onclick=()=>{ EBR.has(b)?EBR.delete(b):EBR.add(b); $('fTit').dataset.auto='1'; renderBrands(); renderEmit(); };
    L.appendChild(btn);
  }
}
$('bQ').oninput=renderBrands;
function emitRows(){
  if(!EBR.size) return [];
  const de=$('eDe').value, ate=$('eAte').value, so=$('eSoNovas').checked;
  return currentRows().filter(r=>EBR.has(brandOf(r))&&(!de||r[I.data]>=de)&&(!ate||r[I.data]<=ate)&&(!so||!reportedBy.has(r[0])))
    .sort((a,b)=>String(a[I.data]).localeCompare(String(b[I.data])));
}
function renderEmit(){
  const on0=EBR.size>0; $('emitEmpty').hidden=on0; $('emitBody').hidden=!on0; if(!on0) return;
  const multi=EBR.size>1;
  $('eTitle').textContent='2. Selecione as linhas de '+marcasLabel();
  const rows=emitRows(); const T=$('eTable');
  const sel=rows.filter(r=>!UNCHECK.has(r[0]));
  let h='<thead><tr><th class="ck"><input type="checkbox" id="eAll" aria-label="Selecionar todas" '+(sel.length===rows.length&&rows.length?'checked':'')+'></th><th>Data</th><th>N.º At.</th><th>Designação</th>'+(multi?'<th>Marca</th>':'')+'<th>Qt</th><th>Campanha</th><th>PVP</th><th>Cond.</th><th>Valor</th><th>Estado</th></tr></thead><tbody>';
  if(!rows.length) h+='<tr><td colspan="11" class="hint" style="text-align:center;padding:18px">'+($('eSoNovas').checked?'Todas as linhas '+(multi?'destas marcas':'desta marca')+' já estão em relatórios. Desmarque "Só linhas ainda não emitidas" para as ver.':'Sem linhas neste período.')+'</td></tr>';
  for(const r of rows){
    const on=!UNCHECK.has(r[0]); const rep=reportedBy.get(r[0]);
    h+='<tr class="'+(on?'':'off')+'"><td class="ck"><input type="checkbox" data-id="'+esc(r[0])+'" '+(on?'checked':'')+' aria-label="Incluir linha"></td><td class="nw">'+dmy(r[I.data])+'</td><td class="nw">'+esc(r[I.at])+'</td><td>'+esc(r[I.des])+'</td>'+(multi?'<td>'+esc(brandOf(r))+'</td>':'')+'<td class="n">'+esc(r[I.qt])+'</td><td>'+esc(r[I.camp])+'</td><td class="n">'+(r[I.pvp]===''?'':eur(r[I.pvp]))+'</td><td class="n">'+esc(r[I.cond])+'</td><td class="n">'+(r[I.valor]===''?'':eur(r[I.valor]))+'</td><td>'+(rep?'<span class="chip info" title="'+esc(rep.titulo)+'">Emitida '+dmy((rep.criadoEm||'').slice(0,10))+'</span>':'<span class="chip ok">Nova</span>')+'</td></tr>';
  }
  T.innerHTML=h+'</tbody>';
  const ea=$('eAll'); if(ea){ ea.indeterminate=sel.length>0&&sel.length<rows.length; ea.onchange=()=>{ rows.forEach(r=>ea.checked?UNCHECK.delete(r[0]):UNCHECK.add(r[0])); renderEmit(); }; }
  T.querySelectorAll('input[data-id]').forEach(c=>c.onchange=()=>{ c.checked?UNCHECK.delete(c.dataset.id):UNCHECK.add(c.dataset.id); renderEmit(); });
  const qt=sel.reduce((s,r)=>s+(+r[I.qt]||0),0), pvp=sel.reduce((s,r)=>s+(+r[I.pvp]||0),0), val=sel.reduce((s,r)=>s+(+r[I.valor]||0),0);
  $('eTot').innerHTML='<div><b>'+sel.length+' de '+rows.length+'</b><span>Linhas selecionadas</span></div><div><b>'+intf(qt)+'</b><span>Quantidade</span></div><div><b>'+eur(pvp)+'</b><span>Total PVP</span></div><div><b>'+eur(val)+'</b><span>Total valor</span></div>';
  if($('fTit').dataset.auto==='1'){ const ds=sel.map(r=>r[I.data]).filter(Boolean).sort(); $('fTit').value=marcasLabel()+(ds.length?' — '+dmy(ds[0])+' a '+dmy(ds[ds.length-1]):''); }
  if(multi){ const pm=new Map(); sel.forEach(r=>{ const b=brandOf(r); const o=pm.get(b)||{n:0,v:0}; o.n++; o.v+=(+r[I.valor]||0); pm.set(b,o); });
    $('eTot').innerHTML+=sortB([...EBR]).map(b=>{ const o=pm.get(b)||{n:0,v:0}; return '<div><b>'+eur(o.v)+'</b><span>'+esc(b)+' · '+o.n+' linha'+(o.n===1?'':'s')+'</span></div>'; }).join(''); }
  $('genBtn').disabled=!sel.length;
}
['eDe','eAte','eSoNovas'].forEach(id=>$(id).addEventListener('change',renderEmit));
$('fTit').addEventListener('input',()=>{ $('fTit').dataset.auto=''; });

// ---------- PDF ----------
let LOGO=null;
function loadLogo(){ return new Promise(ok=>{ const im=new Image(); im.onload=()=>{ const c=document.createElement('canvas'); c.width=im.naturalWidth; c.height=im.naturalHeight; const g=c.getContext('2d'); g.fillStyle='#fff'; g.fillRect(0,0,c.width,c.height); g.drawImage(im,0,0); LOGO={data:c.toDataURL('image/png'),w:c.width,h:c.height}; ok(LOGO); }; im.onerror=()=>ok(null); im.src=document.querySelector('.logo').src; }); }
function buildPdf(rows,opt){
  const {jsPDF}=window.jspdf;
  const doc=new jsPDF({orientation:'landscape',unit:'mm',format:'a4',compress:true});
  const multi=!!(opt.marcas&&opt.marcas.length>1);
  const W=297,M=10, green=[94,140,27], dark=[63,106,15], lime=[141,190,45], soft=[233,245,211];
  const qt=rows.reduce((s,r)=>s+(+r[I.qt]||0),0), pvp=rows.reduce((s,r)=>s+(+r[I.pvp]||0),0), val=rows.reduce((s,r)=>s+(+r[I.valor]||0),0);
  const ds=rows.map(r=>r[I.data]).filter(Boolean).sort();
  if(LOGO){ const h=22,w=h*LOGO.w/LOGO.h; doc.addImage(LOGO.data,'PNG',W-M-w,6,w,h); }
  doc.setFont('helvetica','bold'); doc.setFontSize(16); doc.setTextColor(...dark); doc.text('Relatório de Campanhas',M,14);
  doc.setFontSize(10); doc.setTextColor(...lime); doc.text(FARM.nome,M,19.5);
  doc.setFont('helvetica','normal'); doc.setFontSize(8); doc.setTextColor(90,90,90); doc.text(FARM.morada+' · '+FARM.nif+' · '+FARM.email,M,23.5);
  doc.setFontSize(10); doc.setTextColor(25,25,25);
  doc.setFont('helvetica','bold'); doc.text(multi?'Marcas:':'Marca:',M,31); doc.text('Período:',M,36);
  doc.setFont('helvetica','normal'); doc.text(doc.splitTextToSize(opt.marca,140)[0],M+17,31); doc.text(ds.length?dmy(ds[0])+' a '+dmy(ds[ds.length-1]):'—',M+17,36);
  const bx=W-M-78; doc.setFillColor(...soft); doc.setDrawColor(...green); doc.rect(bx,30,78,8,'FD');
  doc.setFont('helvetica','bold'); doc.text('Total a regularizar:',bx+3,35.3); doc.text(eur(val),bx+75,35.3,{align:'right'});
  const spec=[['Data',17,'center',r=>dmy(r[I.data])],['N.º At.',15,'center',r=>String(r[I.at])],['CNP',15,'center',r=>String(r[I.cnp])],['Designação',multi?48:62,'left',r=>String(r[I.des])]];
  if(multi) spec.push(['Marca',24,'left',r=>brandOf(r)]);
  spec.push(['Qt',9,'center',r=>String(r[I.qt])],['Campanha',multi?32:42,'left',r=>String(r[I.camp])],['Origem',24,'left',r=>String(r[I.orig])],['Tipo',20,'left',r=>String(r[I.tipo])],
    ['PVP',17,'right',r=>r[I.pvp]===''?'':eur(r[I.pvp])],['Cond.',15,'right',r=>String(r[I.cond])],['Valor',18,'right',r=>r[I.valor]===''?'':eur(r[I.valor])],['Operador',23,'center',r=>String(r[I.op])]);
  const ix=t=>spec.findIndex(c=>c[0]===t);
  const columnStyles={}; spec.forEach((c,i)=>columnStyles[i]={cellWidth:c[1],halign:c[2]});
  const foot=spec.map(()=>''); foot[ix('Designação')]={content:'Total ('+rows.length+' linha'+(rows.length===1?'':'s')+')',styles:{halign:'right'}};
  foot[ix('Qt')]={content:intf(qt),styles:{halign:'center'}}; foot[ix('PVP')]={content:eur(pvp),styles:{halign:'right'}}; foot[ix('Valor')]={content:eur(val),styles:{halign:'right'}};
  doc.autoTable({head:[spec.map(c=>c[0])],body:rows.map(r=>spec.map(c=>c[3](r))),startY:41,margin:{left:M,right:M,top:12,bottom:14},theme:'grid',
    styles:{font:'helvetica',fontSize:7.2,cellPadding:1.2,lineColor:green,lineWidth:0.15,textColor:[25,25,25],overflow:'linebreak',valign:'top'},
    headStyles:{fillColor:green,textColor:255,fontStyle:'bold',halign:'center',valign:'middle'},
    alternateRowStyles:{fillColor:[243,249,233]},
    columnStyles, foot:[foot],
    footStyles:{fillColor:soft,textColor:[25,25,25],fontStyle:'bold'},showFoot:'lastPage'});
  if(multi){
    const pm=new Map(); rows.forEach(r=>{ const b=brandOf(r); const o=pm.get(b)||{n:0,q:0,v:0}; o.n++; o.q+=(+r[I.qt]||0); o.v+=(+r[I.valor]||0); pm.set(b,o); });
    let y=doc.lastAutoTable.finalY+8; const need=12+(pm.size+2)*5.5; if(y+need>196){ doc.addPage(); y=16; }
    doc.setFont('helvetica','bold'); doc.setFontSize(10); doc.setTextColor(...dark); doc.text('Resumo por marca',M,y);
    doc.autoTable({head:[['Marca','Linhas','Qt','Total valor']],body:sortB([...pm.keys()]).map(b=>{ const o=pm.get(b); return [b,String(o.n),intf(o.q),eur(o.v)]; }),
      startY:y+2,margin:{left:M,right:M,top:12,bottom:14},tableWidth:130,theme:'grid',
      styles:{font:'helvetica',fontSize:8,cellPadding:1.3,lineColor:green,lineWidth:0.15,textColor:[25,25,25]},
      headStyles:{fillColor:green,textColor:255,fontStyle:'bold'},alternateRowStyles:{fillColor:[243,249,233]},
      columnStyles:{1:{halign:'center',cellWidth:18},2:{halign:'center',cellWidth:18},3:{halign:'right',cellWidth:32}},
      foot:[['Total',String(rows.length),intf(qt),eur(val)]],footStyles:{fillColor:soft,textColor:[25,25,25],fontStyle:'bold',halign:'right'}});
  }
  const n=doc.getNumberOfPages();
  for(let i=1;i<=n;i++){ doc.setPage(i); doc.setFont('helvetica','normal'); doc.setFontSize(7); doc.setTextColor(110,110,110);
    doc.text(doc.splitTextToSize(FARM.nome+' — Relatório de Campanhas · '+opt.marca,190)[0],M,203); doc.text('Emitido em '+opt.emitido+' · Página '+i+' de '+n,W-M,203,{align:'right'}); }
  return {doc,qt,pvp,val,de:ds[0]||'',ate:ds[ds.length-1]||''};
}
function eMsg(t,cls){ const m=$('eMsg'); m.textContent=t||''; m.className='msg'+(cls?' '+cls:''); }
$('genBtn').onclick=async()=>{
  const rows=emitRows().filter(r=>!UNCHECK.has(r[0])); if(!rows.length) return;
  const btn=$('genBtn'); btn.disabled=true; eMsg('A gerar o PDF…');
  try{
    if(!LOGO) await loadLogo();
    const emitido=nowStamp();
    const marcas=sortB([...new Set(rows.map(brandOf))]); const label=marcas.length<=3?marcas.join(', '):marcas.length+' marcas';
    const out=buildPdf(rows,{marca:marcas.length>6?marcas.slice(0,6).join(', ')+' e mais '+(marcas.length-6):marcas.join(', '),marcas,emitido});
    const blob=out.doc.output('blob');
    const rec={titulo:$('fTit').value.trim()||label,marca:label,marcas,de:out.de,ate:out.ate,linhas:rows.length,qt:out.qt,pvp:Math.round(out.pvp*100)/100,valor:Math.round(out.val*100)/100,
      criadoEm:new Date().toISOString(),rowIds:rows.map(r=>r[0]),tratamento:$('fTrat').value.trim(),entrega:$('fEnt').value,modo:$('fModo').value.trim(),dataReg:$('fReg').value,notas:$('fNotas').value.trim()};
    if(assets&&db){
      eMsg('A guardar o PDF…');
      const up=await assets.upload(blob,{type:'application/pdf'});
      rec.assetId=up.id;
      const ref=db.collection('relatorios').doc(); await ref.set(rec); rec.id=ref.id;
    }else{
      rec.id=uid(); rec.localUrl=URL.createObjectURL(blob); REPORTS.unshift(rec); rebuildReported(); renderAfterReports();
    }
    ['fTrat','fEnt','fModo','fReg','fNotas'].forEach(id=>$(id).value=''); $('fTit').dataset.auto='1'; UNCHECK.clear();
    eMsg('Relatório "'+rec.titulo+'" guardado em Relatórios emitidos.','ok');
    openViewer(rec,blob);
  }catch(e){ console.error(e); eMsg(e&&e.code==='quota_or_state'?'Sem espaço para guardar mais PDFs. Apague relatórios antigos.':'Não foi possível guardar o relatório. Tente de novo.','err'); }
  btn.disabled=false; renderEmit();
};

// ---------- relatórios emitidos ----------
let RFILT='', EDIT=null, ASK=null;
const estado=r=>r.dataReg?'ok':(r.entrega?'due':'pend');
const ESTADO={pend:'Por entregar',due:'Entregue, por regularizar',ok:'Regularizado'};
function renderAfterReports(){ $('nRep').textContent=REPORTS.length; renderReports(); if(!$('sec-emitir').hidden){ renderBrands(); renderEmit(); } }
function renderReports(){
  const cnt={pend:0,due:0,ok:0}; REPORTS.forEach(r=>cnt[estado(r)]++);
  const seg=$('seg'); seg.innerHTML='';
  [['','Todos',REPORTS.length,''],['pend',ESTADO.pend,cnt.pend,'pend'],['due',ESTADO.due,cnt.due,'due'],['ok',ESTADO.ok,cnt.ok,'ok']].forEach(([k,l,n,c])=>{
    const b=document.createElement('button'); b.type='button'; b.className=c; b.setAttribute('aria-pressed',RFILT===k); b.innerHTML='<b>'+n+'</b><span>'+esc(l)+'</span>';
    b.onclick=()=>{ RFILT=k; renderReports(); }; seg.appendChild(b); });
  const q=$('rQ').value.trim().toLowerCase();
  const list=REPORTS.filter(r=>(!RFILT||estado(r)===RFILT)&&(!q||[r.titulo,r.marca,(r.marcas||[]).join(' '),r.tratamento,r.modo,r.notas].join(' ').toLowerCase().includes(q)));
  $('rCount').textContent=list.length+' de '+REPORTS.length+' relatório'+(REPORTS.length===1?'':'s');
  const T=$('rTable');
  if(!REPORTS.length){ T.innerHTML='<tbody><tr><td><div class="empty">Ainda não há relatórios. Vá a "Emitir relatório", escolha uma marca e gere o PDF.</div></td></tr></tbody>'; return; }
  let h='<thead><tr><th></th><th>Relatório</th><th>Total</th><th>Tratamento / envio</th><th>Data de entrega</th><th>Modo de regularização</th><th>Data de regularização</th><th>Estado</th><th></th></tr></thead><tbody>';
  for(const r of list){
    const e=estado(r);
    if(EDIT===r.id){
      h+='<tr data-id="'+esc(r.id)+'"><td><div class="pdfi">PDF</div></td><td class="tit"><input id="xTit" value="'+esc(r.titulo)+'" aria-label="Nome"><small>'+esc(r.marca)+' · '+dmy(r.de)+' a '+dmy(r.ate)+'</small></td><td class="n">'+eur(r.valor)+'</td>'+
        '<td><input id="xTrat" list="dlTrat" value="'+esc(r.tratamento)+'" aria-label="Tratamento / envio"></td><td><input type="date" id="xEnt" value="'+esc(r.entrega)+'" aria-label="Data de entrega"></td>'+
        '<td><input id="xModo" list="dlModo" value="'+esc(r.modo)+'" aria-label="Modo de regularização"></td><td><input type="date" id="xReg" value="'+esc(r.dataReg)+'" aria-label="Data de regularização"></td>'+
        '<td><input id="xNotas" value="'+esc(r.notas)+'" placeholder="Notas" aria-label="Notas"></td><td class="acts"><button class="ghost sm" data-a="cancel">Cancelar</button><button class="primary sm" data-a="save">Guardar</button></td></tr>';
      continue;
    }
    h+='<tr data-id="'+esc(r.id)+'" class="'+(ASK===r.id?'ask':'')+'"><td><div class="pdfi">PDF</div></td><td class="tit"><b>'+esc(r.titulo)+'</b><small>'+esc(r.marca)+' · '+dmy(r.de)+' a '+dmy(r.ate)+' · '+r.linhas+' linhas · emitido '+dmy((r.criadoEm||'').slice(0,10))+(r.notas?' · '+esc(r.notas):'')+'</small></td>'+
      '<td class="n">'+eur(r.valor)+'</td><td>'+(esc(r.tratamento)||'<span class="hint">—</span>')+'</td><td class="nw">'+(dmy(r.entrega)||'<span class="hint">—</span>')+'</td><td>'+(esc(r.modo)||'<span class="hint">—</span>')+'</td><td class="nw">'+(dmy(r.dataReg)||'<span class="hint">—</span>')+'</td>'+
      '<td><span class="chip '+e+'">'+ESTADO[e]+'</span></td><td class="acts">'+
      (ASK===r.id?'Apagar relatório e PDF? <button class="danger sm" data-a="delyes">Apagar</button><button class="ghost sm" data-a="delno">Cancelar</button>':
      '<button class="ghost sm" data-a="view" title="Ver PDF"><span class="mi">visibility</span>Ver</button><button class="ghost sm" data-a="dl" title="Descarregar PDF"><span class="mi">download</span></button><button class="ghost sm" data-a="edit" title="Editar"><span class="mi">edit</span></button><button class="danger sm" data-a="del" title="Apagar"><span class="mi">delete</span></button>')+'</td></tr>';
  }
  if(!list.length) h+='<tr><td colspan="9" class="hint" style="text-align:center;padding:18px">Nenhum relatório corresponde à pesquisa.</td></tr>';
  T.innerHTML=h+'</tbody>';
}
$('rQ').oninput=renderReports;
function rMsg(t,cls){ const m=$('rMsg'); m.textContent=t||''; m.className='msg'+(cls?' '+cls:''); }
$('rTable').addEventListener('click',async ev=>{
  const b=ev.target.closest('button[data-a]'); if(!b) return;
  const id=b.closest('tr').dataset.id; const r=REPORTS.find(x=>x.id===id); if(!r) return;
  const a=b.dataset.a;
  if(a==='view') openViewer(r);
  else if(a==='dl') downloadPdf(r,b);
  else if(a==='edit'){ EDIT=id; ASK=null; renderReports(); $('xTrat').focus(); }
  else if(a==='cancel'){ EDIT=null; renderReports(); }
  else if(a==='save'){
    const patch={titulo:$('xTit').value.trim()||r.titulo,tratamento:$('xTrat').value.trim(),entrega:$('xEnt').value,modo:$('xModo').value.trim(),dataReg:$('xReg').value,notas:$('xNotas').value.trim()};
    b.disabled=true;
    try{ if(db) await db.doc('relatorios/'+id).update(patch); Object.assign(r,patch); EDIT=null; rMsg('Alterações guardadas.','ok'); renderAfterReports(); }
    catch(e){ console.error(e); rMsg('Não foi possível guardar. Tente de novo.','err'); b.disabled=false; }
  }
  else if(a==='del'){ ASK=id; EDIT=null; renderReports(); }
  else if(a==='delno'){ ASK=null; renderReports(); }
  else if(a==='delyes'){
    b.disabled=true;
    try{
      if(db) await db.doc('relatorios/'+id).delete();
      if(assets&&r.assetId){ try{ await assets.delete(r.assetId); }catch(e){ console.warn(e); } }
      REPORTS=REPORTS.filter(x=>x.id!==id); ASK=null; rebuildReported(); renderAfterReports();
      rMsg('Relatório apagado. As suas linhas voltam a contar como não emitidas.','ok');
    }catch(e){ console.error(e); rMsg('Não foi possível apagar. Tente de novo.','err'); b.disabled=false; }
  }
});

// ---------- visualizador ----------
let VCUR=null, vTok=0, pdfReady=null;
function loadScript(src){ return new Promise((ok,ko)=>{ const t=document.createElement('script'); t.src=src; t.onload=ok; t.onerror=()=>ko(new Error('script')); document.head.appendChild(t); }); }
function setupPdf(){
  if(!pdfReady) pdfReady=loadScript(PDFJS).then(()=>{
    try{ const b=new Blob(["importScripts('"+PDFJS_WORKER+"');"],{type:'text/javascript'}); pdfjsLib.GlobalWorkerOptions.workerPort=new Worker(URL.createObjectURL(b)); }
    catch(e){ pdfjsLib.GlobalWorkerOptions.workerSrc=PDFJS_WORKER; }
  });
  return pdfReady;
}
async function fetchPdf(r){ const u=r.localUrl||('/_blob/'+r.assetId); const res=await fetch(u); if(!res.ok) throw new Error('http '+res.status); return await res.blob(); }
async function openViewer(r,blob){
  VCUR=r; const tok=++vTok;
  $('vTitle').textContent=r.titulo; $('vDl').hidden=!downloads;
  const body=$('vBody'); body.innerHTML='<div class="empty">A abrir o PDF…</div>'; $('viewer').hidden=false; $('vClose').focus();
  try{
    blob=blob||await fetchPdf(r); await setupPdf();
    const pdf=await pdfjsLib.getDocument({data:new Uint8Array(await blob.arrayBuffer())}).promise; if(tok!==vTok) return;
    body.innerHTML=''; const w=Math.min(body.clientWidth-32,1100), dpr=window.devicePixelRatio||1;
    for(let i=1;i<=pdf.numPages;i++){
      const page=await pdf.getPage(i); if(tok!==vTok) return;
      const sc=w/page.getViewport({scale:1}).width; const vp=page.getViewport({scale:sc*dpr});
      const cv=document.createElement('canvas'); cv.width=vp.width; cv.height=vp.height; cv.style.width=(vp.width/dpr)+'px';
      body.appendChild(cv); await page.render({canvasContext:cv.getContext('2d'),viewport:vp}).promise;
    }
  }catch(e){ console.error(e); if(tok===vTok) body.innerHTML='<div class="empty">Não foi possível mostrar o PDF aqui. Use "Descarregar PDF".</div>'; }
}
function closeViewer(){ vTok++; $('viewer').hidden=true; $('vBody').innerHTML=''; VCUR=null; }
$('vClose').onclick=closeViewer;
document.addEventListener('keydown',e=>{ if(e.key==='Escape'&&!$('viewer').hidden) closeViewer(); });
$('vDl').onclick=()=>{ if(VCUR) downloadPdf(VCUR,$('vDl')); };
async function downloadPdf(r,btn){
  if(!downloads){ rMsg('A transferência de ficheiros não está disponível nesta vista.','err'); return; }
  const old=btn.innerHTML; btn.disabled=true;
  try{ const blob=await fetchPdf(r); const name=(r.titulo||'relatorio').replace(/[\\/:*?"<>|]+/g,'-').trim()+'.pdf'; await downloads.save({filename:name,data:blob}); }
  catch(e){ if(!(e&&e.code==='declined')){ console.error(e); rMsg('Não foi possível descarregar o PDF.','err'); } }
  btn.innerHTML=old; btn.disabled=false;
}

// ---------- arranque ----------
(async function start(){
  const h=(location.hash||'').slice(1); if(TABS.includes(h)) showTab(h);
  loadLogo();
  const cl=window.claude;
  const [d,a,dl]=await Promise.all(['db','assets','downloads'].map(n=>cl&&cl.use?cl.use(n).catch(()=>null):Promise.resolve(null)));
  db=d; assets=a; downloads=dl;
  let rows=[];
  if(db){
    try{ rows=await loadRows(); setSave('Guardado · '+intf(rows.length)+' linhas'); }
    catch(e){ console.error(e); setSave('Não foi possível ler os dados','err'); }
    db.collection('relatorios').onSnapshot(s=>{
      const local=REPORTS.filter(r=>r.localUrl);
      REPORTS=s.docs.map(x=>Object.assign({id:x.id},x.data())).concat(local).sort((p,q)=>String(q.criadoEm).localeCompare(String(p.criadoEm)));
      if(EDIT&&!REPORTS.some(r=>r.id===EDIT)) EDIT=null;
      rebuildReported(); renderAfterReports();
    },e=>{ console.error(e); rMsg('A lista de relatórios deixou de atualizar. Recarregue a página.','err'); });
  }else{
    setSave('Modo de pré-visualização: nada fica guardado','err');
  }
  buildGrid(rows);
  $('nDados').textContent=intf(rows.length); fillBrandSelect();
  if(!rows.length) dMsg('Ainda não há dados. Use "Importar Excel" para carregar o ficheiro das campanhas.');
  renderAfterReports();
  if(!$('sec-emitir').hidden){ renderBrands(); renderEmit(); }
})();
</script>

</body>
</html>

/* ALKO Proxy control dashboard â€” no external dependencies, no telemetry upload. */
'use strict';
const token = document.querySelector('meta[name="alko-token"]').content;
const names = {overview:'Overview',actions:'Quick actions',scanner:'World scanner',automations:'Automations',executor:'Lua executor',modules:'Modules',logs:'Console logs',settings:'Settings'};
const $ = id => document.getElementById(id);
let current = 'overview';
let statusCache = null;
let scanCache = null;
let settingsCache = null;
const luaExample = $('lua-source').value;

function notify(message, error=false) {
  const toast = $('toast');
  toast.textContent = message; toast.className = error ? 'error' : '';
  toast.style.display = 'block';
  clearTimeout(notify.timer); notify.timer = setTimeout(() => toast.style.display='none', 4800);
}
async function req(path, data) {
  const opts = data === undefined ? {} : {method:'POST',headers:{'Content-Type':'application/json','X-ALKO-Token':token},body:JSON.stringify(data)};
  let resp;
  try {resp = await fetch('/api/'+path,opts);} catch(e) {throw new Error('Cannot contact ALKO dashboard server');}
  let json;
  try {json = await resp.json();} catch {throw new Error('Invalid response from dashboard server');}
  if (!resp.ok) throw new Error(json.error || `Request failed (${resp.status})`);
  return json;
}
async function safe(run) {try{await run();}catch(e){notify(e.message,true);}}
function view(key) {
  if (!(key in names)) return;
  current=key;
  document.querySelectorAll('.view').forEach(x=>x.classList.toggle('active',x.id===key));
  document.querySelectorAll('[data-view]').forEach(x=>x.classList.toggle('active',x.dataset.view===key));
  $('breadcrumb').textContent=names[key];
  if(key==='scanner') refreshScan();
  if(key==='settings') refreshSettings();
  if(key==='logs') refreshLogs();
  window.scrollTo({top:0,behavior:'smooth'});
}
document.querySelectorAll('[data-view]').forEach(el=>el.addEventListener('click',()=>view(el.dataset.view)));
document.querySelectorAll('[data-go]').forEach(el=>el.addEventListener('click',()=>view(el.dataset.go)));

async function refreshStatus(){
  try{
    let s=await req('status'); statusCache=s;
    const running=s.engine==='running',online=s.bridge==='online';
    $('kpi-engine').textContent=running?'RUNNING':'OFFLINE';
    $('kpi-engine-sub').textContent=running?`PID ${s.pid}`:'Not started';
    $('kpi-bridge').textContent=online?'ONLINE':'OFFLINE';
    $('kpi-queued').textContent=s.queued;
    $('engine-chip').innerHTML=`<i></i>${online?'Bridge online':running?'Engine running Â· no bridge':'Engine offline'}`;
    $('engine-chip').classList.toggle('online',online);
    $('engine-detail').textContent=running?`Process ${s.pid}`:'No process running';
    const connection = {
      connected: 'ENET CONNECTED',
      connecting: 'CONNECTING UPSTREAM',
      disconnected: !running ? 'NOT CONNECTED' : {
        waiting: 'WAITING FOR GAME HTTPS',
        requested: 'CHECKING GAME HTTPS',
        failed: 'GAME HTTPS FAILED',
        ready: 'WAITING FOR GAME ENET',
      }[s.bootstrap] || 'NOT CONNECTED',
      unknown: 'CONNECTION UNKNOWN',
    };
    $('wire-status').textContent=connection[s.connection] || 'CONNECTION UNKNOWN';
    $('side-status').textContent=online?'NATIVE BRIDGE ACTIVE':'CONTROL PANEL ACTIVE';
    $('start-engine').disabled=running;
    $('stop-engine').disabled=!running;
    const w=s.workflow, done=w.completed||0,total=w.total||0;
    $('workflow-progress').textContent=`${done} / ${total}`;
    $('workflow-progressbar').style.width= total?`${100*done/total}%`:'0%';
    $('workflow-state').textContent=w.running?`Running: ${w.name}`:w.error?`Stopped: ${w.error}`:total?`Completed ${done} of ${total} steps`:'Idle. Waiting for a workflow.';
  } catch(e){$('engine-chip').textContent='Dashboard disconnected';}
}
async function refreshSettings(){
  try{const s=await req('settings');settingsCache=s;
    $('engine-path').value=s.engine_path||'';
    $('world-label').value=s.world_label||'';
    $('allow-lua').checked=!!s.allow_lua;
    $('confirm-trash').checked=!!s.confirm_trash;
    $('lua-policy').textContent=s.allow_lua?'Lua executor enabled':'Custom Lua is disabled in Settings.';
  }catch(e){notify(e.message,true);}
}
async function refreshScan(){
  try {scanCache=await req('scan');renderScan();}catch(e){notify(e.message,true);}
}
function renderScan(){
  const scan=scanCache?.data; if(!scan)return;
  const totals=scan.totals||{};
  $('scan-fg').textContent=totals.foreground?.toLocaleString()||'â€”';
  $('scan-bg').textContent=totals.background?.toLocaleString()||'â€”';
  $('scan-drops').textContent=totals.dropped?.toLocaleString()||'â€”';
  $('scan-size').textContent=scan.size?.width?`${scan.size.width} Ã— ${scan.size.height}`:'â€”';
  $('scan-meta').textContent=scanCache.source==='none'?'No scan captured yet':`${scan.world} Â· ${scanCache.source} Â· ${new Date(scanCache.updated_at*1000).toLocaleString()}`;
  const term=$('scan-search').value.trim().toLowerCase();
  const rows=[];
  ['foreground','background','dropped'].forEach(cat=>scan[cat]?.forEach(row=>{
    if(!term||String(row.id)===term||row.name.toLowerCase().includes(term))rows.push({...row,cat});
  }));
  rows.sort((a,b)=>b.count-a.count);
  const table=$('scan-rows'); table.replaceChildren();
  if(!rows.length){const tr=document.createElement('tr'),td=document.createElement('td');td.colSpan=3;td.className='empty';td.textContent='No matching scan items. Run /gscan to capture loaded-world data.';tr.append(td);table.append(tr);return;}
  for(const row of rows.slice(0,400)){
    const tr=document.createElement('tr');
    for(const [txt,cls] of [[`${row.name}  Â·  #${row.id}`,''],[row.cat,'category'],[row.count.toLocaleString(),'number']]){
      const td=document.createElement('td');td.textContent=txt;td.className=cls;tr.append(td);
    } table.append(tr);
  }
}
async function refreshLogs(){
  try{const data=await req('logs');const box=$('log-lines');box.replaceChildren();
    for (const row of data.logs){const line=document.createElement('div'),time=document.createElement('span');time.className='log-time';time.textContent=`[${row.time}]`;line.append(time,document.createTextNode(row.message));box.append(line);}
    box.scrollTop=box.scrollHeight;
  }catch(e){notify(e.message,true);}
}
async function issue(command,options={}){
  return safe(async()=>{
    let confirmTrash=options.confirm;
    if(command.startsWith('/qtrash') && !confirmTrash){
      if(!confirm(`This will request to TRASH inventory items:\n${command}\nContinue?`))return;
      confirmTrash=true;
    }
    const data=await req('command',{command,confirm:!!confirmTrash});
    $('command-output').textContent=`Queued ${data.command} Â· job ${data.id.slice(0,8)} Â· not a server acknowledgement`;
    notify(`Command queued: ${command}`);
    refreshStatus();
  });
}
async function writeClip(value){try{await navigator.clipboard.writeText(value);notify('Copied '+value);}catch{notify('Clipboard blocked by browser',true);}}
$('start-engine').addEventListener('click',()=>safe(async()=>{await req('engine/start',{});notify('Native engine process started â€” test game connection separately');refreshStatus();}));
$('stop-engine').addEventListener('click',()=>safe(async()=>{await req('engine/stop',{});notify('Engine process stopped');refreshStatus();}));
document.querySelectorAll('[data-command]').forEach(el=>el.addEventListener('click',()=>issue(el.dataset.command)));
$('warp-send').addEventListener('click',()=>issue(`/warp ${$('warp-world').value.trim().toUpperCase()}`));
$('drop-send').addEventListener('click',()=>issue(`/qdrop ${$('item-id').value} ${$('item-count').value}`));
$('trash-send').addEventListener('click',()=>issue(`/qtrash ${$('item-id').value} ${$('item-count').value}`));
$('count-send').addEventListener('click',()=>issue(`/counts ${$('tile-id').value}`));
$('send-command').addEventListener('click',()=>issue($('custom-command').value.trim()));
$('custom-command').addEventListener('keydown',e=>{if(e.key==='Enter')issue($('custom-command').value.trim());});
$('run-scan').addEventListener('click',async()=>{await issue('/gscan');setTimeout(refreshScan,1500)});
$('scan-search').addEventListener('input',renderScan);
$('import-scan').addEventListener('click',()=>safe(async()=>{const data=JSON.parse($('scan-import').value);await req('scan/import',data);notify('Local scan imported');refreshScan();}));
$('workflow-start').addEventListener('click',()=>safe(async()=>{
  const data=await req('workflow/start',{name:$('workflow-name').value,steps:JSON.parse($('workflow-steps').value),repeat:Number($('workflow-repeat').value)});
  notify(`Workflow started: ${data.name}`);refreshStatus();
}));
$('workflow-stop').addEventListener('click',()=>safe(async()=>{await req('workflow/stop',{});notify('Workflow cancelled');refreshStatus();}));
$('script-run').addEventListener('click',()=>safe(async()=>{
  if(!confirm('Run this Lua script inside the native proxy engine? It can send game packets.'))return;
  const d=await req('scripts/run',{source:$('lua-source').value});notify('Lua script queued: '+d.id.slice(0,8));
}));
$('script-reset').addEventListener('click',()=>{$('lua-source').value=luaExample;notify('Example script restored');});
$('save-settings').addEventListener('click',()=>safe(async()=>{
  const data={engine_path:$('engine-path').value,world_label:$('world-label').value,allow_lua:$('allow-lua').checked,confirm_trash:$('confirm-trash').checked};
  await req('settings',data);notify('Settings saved locally');refreshSettings();
}));
$('refresh-logs').addEventListener('click',refreshLogs);
$('quit-app').addEventListener('click',()=>safe(async()=>{if(!confirm('Close ALKO Proxy? The local dashboard and any launched engine will stop.'))return;await req('app/quit',{});notify('ALKO Proxy closing');}));
const modules=[
  ['âŒ—','World scanner','Reads loaded tile foreground/background and dropped item counts.','IMPLEMENTED','ready'],
  ['âŒ˜','Command palette','Routes validated slash commands to the patched C++ engine.','IMPLEMENTED Â· REQUIRES ENGINE','ready'],
  ['â—ˆ','Quick inventory','Fast drop and trash dialog requests from legacy packet formats.','EXPERIMENTAL',''],
  ['â™™','World/player intel','Local position, player counts, dropped-object summaries.','IMPLEMENTED Â· REQUIRES ENGINE','ready'],
  ['â†»','Automations','Finite command sequences, delays, repeat limits and cancellation.','IMPLEMENTED Â· REQUIRES ENGINE','ready'],
  ['â–£','Lua scripting','Optional Lua executor using the upstream safe-library environment.','IMPLEMENTED Â· REQUIRES ENGINE','ready'],
  ['âœ³','Farm report','Seed extra/tile statistics; does not auto-harvest or place.','PARTIAL',''],
  ['â–¥','Fast vending','Context-sensitive vend purchasing/restocking needs packet tests.','PLANNED','future'],
  ['â†”','Zoom / visual tools','Older clients expose mods; modern client requires testing.','PLANNED','future'],
  ['â—«','Multibot','Separate future engine, not integrated into this version.','PLANNED','future'],
  ['â–¨','World history','Saved world shortcuts and scanner history.','PLANNED','future'],
  ['â™¢','Security / diagnostics','Local-only dashboard, CSRF token, command allowlist, log redaction.','IMPLEMENTED','ready'],
];
function renderModules(){const grid=$('modules-grid');for(const [symbol,name,desc,label,cls] of modules){const el=document.createElement('div');el.className='module';const sym=document.createElement('div');sym.className='symbol';sym.textContent=symbol;const title=document.createElement('h2');title.textContent=name;const p=document.createElement('p');p.textContent=desc;const tag=document.createElement('span');tag.className='tag '+cls;tag.textContent=label;el.append(sym,title,p,tag);grid.append(el);}}
renderModules();
refreshStatus();refreshScan();refreshSettings();
setInterval(()=>{refreshStatus(); if(current==='scanner')refreshScan();if(current==='logs')refreshLogs();},2500);

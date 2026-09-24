(() => {
  const PRESENTATION_VERSION='0.6.4';
  const style=document.createElement('style');
  style.dataset.autoAgentPolish='v064';
  style.textContent=`
    :root{--chat-accent:#8fc7b8}
    .conversation{width:min(clamp(720px,68cqi,1040px),100%)}
    .msg-row{width:min(clamp(720px,68cqi,1040px),100%);margin-bottom:clamp(22px,2cqi,32px);animation:aa-message-in .22s cubic-bezier(.2,.8,.2,1);content-visibility:auto;contain-intrinsic-size:1px 120px}
    .msg-body{max-width:min(92%,clamp(660px,62cqi,900px))}
    .msg-row.user .msg-body{max-width:min(86%,clamp(540px,50cqi,760px));padding:clamp(10px,.9cqi,13px) clamp(14px,1.25cqi,18px);border-radius:20px 20px 6px 20px;background:#1b2227;border-color:#2a343a;box-shadow:0 6px 22px rgba(0,0,0,.12)}
    .meta{margin:1px 0 clamp(8px,.75cqi,11px);font-size:clamp(10.5px,calc(9.8px + .15cqi),12px);letter-spacing:.095em;color:#899894}
    .msg-text{font-size:clamp(15.5px,calc(14.1px + .26cqi),18px)!important;line-height:clamp(1.62,1.54 + .16cqi,1.8)!important;letter-spacing:-.006em;color:#eef2f4;text-wrap:pretty}
    .msg-row.user .msg-text{font-size:clamp(15px,calc(13.9px + .22cqi),17.5px)!important;line-height:clamp(1.56,1.5 + .12cqi,1.68)!important;letter-spacing:-.003em}
    .msg-row.pending .avatar{animation:aa-breathe 1.55s ease-in-out infinite}
    .msg-row.pending .msg-text{color:#aeb9bd}
    .msg-row.completed .msg-body{animation:aa-answer-ready .28s ease-out}
    .msg-row.error .msg-body{padding:14px 16px;border:1px solid #4a3030;background:#211718;border-radius:14px}

    .md p{margin:.82em 0}.md p:first-child{margin-top:0}.md p:last-child{margin-bottom:0}
    .md h1,.md h2,.md h3,.md h4{margin:1.6em 0 .62em;color:#f8fafb;font-weight:680;line-height:1.27;letter-spacing:-.018em;text-wrap:balance}
    .md h1:first-child,.md h2:first-child,.md h3:first-child,.md h4:first-child{margin-top:.1em}
    .md h1{font-size:clamp(1.38em,calc(1.18em + .28cqi),1.58em)}.md h2{font-size:clamp(1.23em,calc(1.12em + .18cqi),1.36em);padding-bottom:.28em;border-bottom:1px solid #202a30}.md h3{font-size:clamp(1.10em,calc(1.04em + .12cqi),1.19em)}.md h4{font-size:clamp(1.01em,calc(.98em + .07cqi),1.07em);color:#dfe6e8}
    .md ul,.md ol{margin:.72em 0 1em 1.5em;padding:0}.md li{margin:.38em 0;padding-left:.16em}.md li::marker{color:#80918e}
    .md blockquote{margin:1em 0;padding:.58em .85em;border-left:3px solid #456d67;background:#11191c;color:#c4cfd2;border-radius:0 9px 9px 0}
    .md code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.88em;background:#161d22;border:1px solid #29343a;border-radius:6px;padding:.12em .34em}
    .md a{color:#83bfb4;text-decoration:none;text-underline-offset:3px}.md a:hover{text-decoration:underline}
    .md hr{border:0;border-top:1px solid #263138;margin:1.55em 0}.md strong{font-weight:720;color:#fff}.md em{color:#d8e0e2}
    .code-block{margin:1.05em 0 1.2em;overflow:hidden;border:1px solid #263139;border-radius:13px;background:#0a0f13;box-shadow:0 8px 28px rgba(0,0,0,.16)}
    .code-head{height:clamp(35px,2.8cqi,40px);display:flex;align-items:center;gap:8px;padding:0 clamp(10px,.9cqi,13px) 0 clamp(12px,1.1cqi,16px);border-bottom:1px solid #1f292f;background:#10171b;color:#7f8e95;font:600 clamp(10.5px,calc(9.8px + .14cqi),12px)/1 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
    .code-spacer{flex:1}.code-block pre{margin:0;padding:clamp(14px,1.2cqi,18px) clamp(15px,1.4cqi,20px);overflow:auto;background:transparent;border:0;border-radius:0;line-height:1.58}.code-block pre code{padding:0;border:0;background:transparent;font-size:clamp(12.5px,calc(11.8px + .16cqi),14px);white-space:pre;color:#dce4e7}
    .code-copy,.msg-copy{border:0;background:transparent;color:#8f9ba1;cursor:pointer;border-radius:7px;transition:background .15s,color .15s,transform .15s}.code-copy{padding:5px 7px;font-size:clamp(10.5px,calc(9.8px + .14cqi),12px)}
    .code-copy:hover,.msg-copy:hover{background:#1b2429;color:#e8eeef}.code-copy:active,.msg-copy:active{transform:scale(.96)}
    .table-wrap{margin:1em 0 1.15em;overflow:auto;border:1px solid #263138;border-radius:12px;background:#0f1519}.md table{border-collapse:collapse;width:100%;min-width:420px;font-size:.93em}.md th,.md td{padding:clamp(9px,.8cqi,12px) clamp(10px,1cqi,14px);border-bottom:1px solid #222d33;text-align:left;vertical-align:top}.md th{background:#141c20;color:#f2f5f6;font-weight:650}.md tr:last-child td{border-bottom:0}
    .task-box{display:inline-grid;width:16px;height:16px;margin:0 7px 0 0;border:1px solid #47575e;border-radius:4px;place-items:center;vertical-align:-2px;color:#0d1513;background:#131b1f;font-size:11px}.task-box.checked{background:var(--chat-accent);border-color:var(--chat-accent)}
    .callout{margin:1em 0!important;padding:.72em .9em;border:1px solid #2c393e;border-radius:11px;background:#121a1e}.callout.warning{border-color:#5b4b2e;background:#1b1811}.callout.success{border-color:#2d4d42;background:#111b18}.callout.danger{border-color:#583535;background:#1d1415}.callout.info{border-color:#304756;background:#11191f}
    .msg-actions{min-height:28px;display:flex;align-items:center;gap:4px;margin-top:8px;opacity:0;transform:translateY(-2px);transition:opacity .15s,transform .15s}.msg-row.agent:hover .msg-actions,.msg-actions:focus-within{opacity:1;transform:none}
    .msg-copy{display:inline-flex;align-items:center;gap:6px;padding:5px 8px;font-size:clamp(10.5px,calc(9.8px + .14cqi),12px)}.msg-copy svg{width:14px;height:14px;fill:none;stroke:currentColor;stroke-width:1.7}.copy-ok{color:var(--chat-accent)!important}
    .history-list{display:flex;flex-direction:column;gap:2px;margin:2px 7px 12px;min-height:0;max-height:32vh;overflow:auto;padding-right:2px}.history-group{padding:10px 8px 4px;color:#65747a;font:700 clamp(8.5px,calc(8px + .1vw),10px)/1 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;letter-spacing:.12em;text-transform:uppercase}
    .history-item{display:flex;align-items:center;gap:8px;width:100%;padding:8px 9px;border-radius:9px;background:transparent;border:0;color:#aeb9bd;text-align:left;cursor:pointer;font-size:clamp(11.5px,calc(10.6px + .16vw),13px);line-height:1.3}.history-item:hover{background:#171d21;color:#edf2f3}.history-item.active{background:#192125;color:#fff}.history-title{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}.history-agent{width:18px;height:18px;display:grid;place-items:center;flex:0 0 18px;border:1px solid #2a3938;border-radius:5px;color:#7ba79e;font:700 clamp(8.5px,calc(8px + .1vw),10px)/1 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
    .sidebar-collapsed .history-list,.sidebar-collapsed .history-section-label{display:none!important}
    @keyframes aa-message-in{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}@keyframes aa-answer-ready{from{opacity:.55;transform:translateY(3px)}to{opacity:1;transform:none}}@keyframes aa-breathe{0%,100%{box-shadow:0 0 0 0 rgba(143,199,184,0)}50%{box-shadow:0 0 0 5px rgba(143,199,184,.08)}}
    @container workspace (max-width:760px){.conversation,.msg-row{width:100%}.msg-body{max-width:92%}.md table{min-width:360px}}@container workspace (min-width:1280px){.conversation,.msg-row{width:min(72cqi,1080px)}.msg-body{max-width:min(900px,88%)}}@media(max-width:900px){.history-list{max-height:26vh}.msg-actions{opacity:1}}
    @media(prefers-reduced-motion:reduce){.msg-row,.msg-row.completed .msg-body,.msg-row.pending .avatar{animation:none!important}*{scroll-behavior:auto!important}}
  `;
  document.head.appendChild(style);

  function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
  function safeUrl(url){try{const u=new URL(url,location.origin);return ['http:','https:'].includes(u.protocol)?u.href:'#';}catch(_){return '#';}}
  function inlineMd(text){
    let out=esc(text);
    const code=[];
    out=out.replace(/`([^`]+)`/g,(_,v)=>{const i=code.push(`<code>${v}</code>`)-1;return `@@CODE${i}@@`;});
    out=out.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,(_,label,url)=>`<a href="${esc(safeUrl(url))}" target="_blank" rel="noopener noreferrer">${label}</a>`);
    out=out.replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>').replace(/__([^_]+)__/g,'<strong>$1</strong>').replace(/~~([^~]+)~~/g,'<del>$1</del>').replace(/\*([^*\n]+)\*/g,'<em>$1</em>');
    return out.replace(/@@CODE(\d+)@@/g,(_,i)=>code[Number(i)]||'');
  }
  function splitCells(line){let s=line.trim();if(s.startsWith('|'))s=s.slice(1);if(s.endsWith('|'))s=s.slice(0,-1);return s.split('|').map(x=>x.trim());}
  function tableSeparator(line){const cells=splitCells(line);return cells.length>0&&cells.every(c=>/^:?-{3,}:?$/.test(c));}
  function codeBlock(code,lang){return `<div class="code-block"><div class="code-head"><span>${esc(lang||'code')}</span><span class="code-spacer"></span><button type="button" class="code-copy" data-copy-code>Copy</button></div><pre><code>${esc(code)}</code></pre></div>`;}
  function tableBlock(header,separator,rows){
    const heads=splitCells(header),aligns=splitCells(separator).map(c=>c.startsWith(':')&&c.endsWith(':')?'center':c.endsWith(':')?'right':'left');
    return `<div class="table-wrap"><table><thead><tr>${heads.map((c,i)=>`<th style="text-align:${aligns[i]||'left'}">${inlineMd(c)}</th>`).join('')}</tr></thead><tbody>${rows.map(r=>{const cells=splitCells(r);return `<tr>${heads.map((_,i)=>`<td style="text-align:${aligns[i]||'left'}">${inlineMd(cells[i]||'')}</td>`).join('')}</tr>`;}).join('')}</tbody></table></div>`;
  }
  function markdown(text){
    const lines=String(text??'').replace(/\r\n/g,'\n').split('\n'),html=[];let paragraph=[],list=null,inCode=false,lang='',code=[];
    const flushP=()=>{if(paragraph.length){html.push(`<p>${inlineMd(paragraph.join('\n')).replace(/\n/g,'<br>')}</p>`);paragraph=[];}};
    const flushList=()=>{if(list){html.push(`</${list}>`);list=null;}};
    const openList=t=>{if(list!==t){flushList();html.push(`<${t}>`);list=t;}};
    for(let i=0;i<lines.length;i++){
      const raw=lines[i],f=raw.match(/^```\s*([A-Za-z0-9_+.-]*)\s*$/);
      if(f){if(!inCode){flushP();flushList();inCode=true;lang=f[1]||'';code=[];}else{html.push(codeBlock(code.join('\n'),lang));inCode=false;lang='';code=[];}continue;}
      if(inCode){code.push(raw);continue;} if(!raw.trim()){flushP();flushList();continue;}
      if(i+1<lines.length&&raw.includes('|')&&tableSeparator(lines[i+1])){
        flushP();flushList();const sep=lines[i+1],rows=[];i+=2;while(i<lines.length&&lines[i].trim()&&lines[i].includes('|')){rows.push(lines[i]);i++;}i--;html.push(tableBlock(raw,sep,rows));continue;
      }
      let m;
      if((m=raw.match(/^(#{1,4})\s+(.+)$/))){flushP();flushList();const n=m[1].length;html.push(`<h${n}>${inlineMd(m[2])}</h${n}>`);continue;}
      if(/^\s*([-*_])(?:\s*\1){2,}\s*$/.test(raw)){flushP();flushList();html.push('<hr>');continue;}
      if((m=raw.match(/^\s*[-*+]\s+(.+)$/))){flushP();openList('ul');const task=m[1].match(/^\[([ xX])\]\s+(.+)$/);if(task){const checked=/[xX]/.test(task[1]);html.push(`<li style="list-style:none;margin-left:-1.45em"><span class="task-box ${checked?'checked':''}">${checked?'✓':''}</span>${inlineMd(task[2])}</li>`);}else html.push(`<li>${inlineMd(m[1])}</li>`);continue;}
      if((m=raw.match(/^\s*\d+[.)]\s+(.+)$/))){flushP();openList('ol');html.push(`<li>${inlineMd(m[1])}</li>`);continue;}
      if((m=raw.match(/^>\s?(.*)$/))){flushP();flushList();html.push(`<blockquote>${inlineMd(m[1])}</blockquote>`);continue;}
      paragraph.push(raw);
    }
    if(inCode)html.push(codeBlock(code.join('\n'),lang));else{flushP();flushList();}
    return html.join('');
  }
  function classify(root){
    root.querySelectorAll(':scope > p').forEach(p=>{const t=(p.textContent||'').trim().toLowerCase();let type='';if(t.startsWith('⚠')||/^(warning|caution|lưu ý|chú ý)\b/.test(t))type='warning';else if(t.startsWith('✅')||/^(success|done|hoàn tất|kết quả)\b/.test(t))type='success';else if(t.startsWith('❌')||/^(error|failed|failure|lỗi)\b/.test(t))type='danger';else if(t.startsWith('ℹ')||/^(note|info|ghi chú)\b/.test(t))type='info';if(type)p.classList.add('callout',type);});
  }
  function bindCopies(root){
    root.querySelectorAll('[data-copy-code]').forEach(btn=>btn.onclick=async()=>{const code=btn.closest('.code-block')?.querySelector('code')?.textContent||'';try{await navigator.clipboard.writeText(code);btn.textContent='Copied';btn.classList.add('copy-ok');setTimeout(()=>{btn.textContent='Copy';btn.classList.remove('copy-ok');},1200);}catch(_){}});
  }
  function actionBar(el,text,role){
    if(role!=='assistant')return;const body=el.closest('.msg-body');if(!body)return;let bar=body.querySelector(':scope > .msg-actions');if(!bar){bar=document.createElement('div');bar.className='msg-actions';body.appendChild(bar);}bar.replaceChildren();const b=document.createElement('button');b.type='button';b.className='msg-copy';b.innerHTML='<svg viewBox="0 0 24 24"><rect x="8" y="8" width="11" height="11" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></svg><span>Copy</span>';b.onclick=async()=>{try{await navigator.clipboard.writeText(String(text??''));const s=b.querySelector('span');s.textContent='Copied';b.classList.add('copy-ok');setTimeout(()=>{s.textContent='Copy';b.classList.remove('copy-ok');},1200);}catch(_){}};bar.appendChild(b);
  }
  window.AutoAgentRenderMessage=(el,text,role='assistant')=>{if(!el)return;if(role==='assistant'||role==='error'){el.classList.add('md');el.innerHTML=markdown(text);classify(el);bindCopies(el);}else{el.classList.remove('md');el.textContent=String(text??'');}actionBar(el,text,role);};
  async function jsonFetch(url,opts={}){
    const r=await fetch(url,{cache:'no-store',headers:{accept:'application/json',...(opts.headers||{})},...opts});
    const d=await r.json().catch(()=>({}));
    if(!r.ok)throw new Error(d.error||`HTTP ${r.status}`);
    return d;
  }

  const nav=document.querySelector('.sidebar nav');
  let listEl=null;
  let activeConversation='';
  if(nav){
    const label=document.createElement('div');label.className='nav-section-label history-section-label';label.textContent='History';
    listEl=document.createElement('div');listEl.className='history-list';
    nav.append(label,listEl);
  }

  function formatHistoryTime(ts){
    if(!ts)return '';
    const d=new Date(Number(ts)*1000);const now=new Date();
    return d.toDateString()===now.toDateString()?d.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}):d.toLocaleDateString();
  }

  function historyBucket(ts){
    const d=new Date(Number(ts||0)*1000),now=new Date(),today=new Date(now.getFullYear(),now.getMonth(),now.getDate()),day=Math.floor((today-new Date(d.getFullYear(),d.getMonth(),d.getDate()))/86400000);
    return day<=0?'Today':day===1?'Yesterday':day<=7?'Previous 7 days':'Older';
  }

  async function refreshHistory(){
    if(!listEl)return;
    try{
      const d=await jsonFetch('/api/history?limit=30');
      listEl.replaceChildren();
      let bucket='';
      for(const c of d.conversations||[]){
        const next=historyBucket(c.updated_at);
        if(next!==bucket){bucket=next;const g=document.createElement('div');g.className='history-group';g.textContent=bucket;listEl.appendChild(g);}
        const btn=document.createElement('button');btn.className='history-item'+(c.id===activeConversation?' active':'');btn.type='button';btn.title=`${c.title||'New chat'} · ${formatHistoryTime(c.updated_at)}`;
        const title=document.createElement('span');title.className='history-title';title.textContent=c.title||'New chat';
        const agent=document.createElement('span');agent.className='history-agent';const name=(c.last_agent||'').toLowerCase();agent.textContent=name==='openclaw'?'O':name==='hermes'?'H':'·';agent.title=c.last_agent||'';
        btn.append(title,agent);btn.onclick=()=>loadConversation(c.id);listEl.appendChild(btn);
      }
    }catch(err){console.warn('history refresh failed',err);}
  }

  function rowFor(msg){
    const row=document.createElement('div');row.className=`msg-row ${msg.role==='user'?'user':msg.role==='error'?'error':'agent'}`;
    if(msg.role!=='user'){
      const avatar=document.createElement('div');avatar.className='avatar';avatar.textContent=msg.role==='error'?'!':'AI';row.appendChild(avatar);
    }
    const body=document.createElement('div');body.className='msg-body';
    if(msg.role!=='user'){
      const meta=document.createElement('div');meta.className='meta';meta.textContent=msg.role==='error'?'Error':(msg.agent||'Agent').toUpperCase();body.appendChild(meta);
    }
    const text=document.createElement('div');text.className='msg-text';window.AutoAgentRenderMessage(text,msg.content,msg.role==='user'?'user':msg.role);body.appendChild(text);row.appendChild(body);return row;
  }

  async function loadConversation(id){
    try{
      const d=await jsonFetch(`/api/history/${encodeURIComponent(id)}`);
      const conversation=document.getElementById('conversation');const welcome=document.getElementById('welcome');
      if(!conversation)return;
      conversation.querySelectorAll('.msg-row').forEach(n=>n.remove());if(welcome)welcome.style.display='none';
      for(const m of d.messages||[])conversation.appendChild(rowFor(m));
      activeConversation=id;
      if(window.AutoAgentChat&&window.AutoAgentChat.setConversationId)window.AutoAgentChat.setConversationId(id);
      const chatButton=document.querySelector('.nav-btn[data-tab="chat"]');if(chatButton)chatButton.click();
      refreshHistory();
      const last=conversation.querySelector('.msg-row:last-of-type');if(last)last.scrollIntoView({block:'end'});
    }catch(err){console.warn('history load failed',err);}
  }

  window.AutoAgentHistory={refresh:refreshHistory,load:loadConversation};
  window.addEventListener('autoagent:history-changed',refreshHistory);
  window.addEventListener('autoagent:newchat',()=>{activeConversation='';refreshHistory();});
  refreshHistory();
  window.AutoAgentPresentationVersion=PRESENTATION_VERSION;
})();

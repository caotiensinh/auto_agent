(() => {
  const style = document.createElement('style');
  style.textContent = `
    :root{--chat-font:17px;--chat-line:1.72}
    .msg-text{font-size:var(--chat-font)!important;line-height:var(--chat-line)!important;letter-spacing:.002em;color:#eef2f4}
    .msg-row.user .msg-text{font-size:17px!important;line-height:1.62!important}
    .msg-body{max-width:920px}
    .md p{margin:.65em 0}.md p:first-child{margin-top:0}.md p:last-child{margin-bottom:0}
    .md h1,.md h2,.md h3,.md h4{margin:1.15em 0 .45em;line-height:1.28;color:#f7fafb;font-weight:650}
    .md h1{font-size:1.42em}.md h2{font-size:1.28em}.md h3{font-size:1.13em}.md h4{font-size:1.02em}
    .md ul,.md ol{margin:.55em 0 .8em 1.35em;padding:0}.md li{margin:.28em 0;padding-left:.12em}
    .md blockquote{margin:.8em 0;padding:.15em 0 .15em .9em;border-left:3px solid #3a6260;color:#bac6c9}
    .md code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.9em;background:#171e23;border:1px solid #283238;border-radius:6px;padding:.12em .34em}
    .md pre{margin:.9em 0;padding:14px 16px;overflow:auto;background:#0b1014;border:1px solid #253037;border-radius:12px;line-height:1.55}
    .md pre code{padding:0;border:0;background:transparent;font-size:14px;white-space:pre}
    .md a{color:#7bb5b0;text-decoration:none}.md a:hover{text-decoration:underline}
    .md hr{border:0;border-top:1px solid #293238;margin:1.2em 0}
    .md strong{font-weight:700;color:#fff}
    .history-list{display:flex;flex-direction:column;gap:3px;margin:2px 7px 12px;min-height:0;max-height:30vh;overflow:auto}
    .history-item{display:flex;align-items:center;gap:8px;width:100%;padding:8px 9px;border-radius:9px;background:transparent;border:0;color:#aeb9bd;text-align:left;cursor:pointer;font-size:12px;line-height:1.3}
    .history-item:hover{background:#171d21;color:#edf2f3}.history-item.active{background:#192125;color:#fff}
    .history-title{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}.history-agent{font-size:10px;color:#66817f;text-transform:uppercase}
    .sidebar-collapsed .history-list,.sidebar-collapsed .history-section-label{display:none!important}
    @media(max-width:900px){:root{--chat-font:16px}.msg-row.user .msg-text{font-size:16px!important}.history-list{max-height:24vh}}
  `;
  document.head.appendChild(style);

  function esc(s){return String(s ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
  function safeUrl(url){try{const u=new URL(url,location.origin);return ['http:','https:'].includes(u.protocol)?u.href:'#';}catch(_){return '#';}}
  function inlineMd(text){
    let out=esc(text);
    const code=[];
    out=out.replace(/`([^`]+)`/g,(_,v)=>{const i=code.push(`<code>${v}</code>`)-1;return `@@CODE${i}@@`;});
    out=out.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,(_,label,url)=>`<a href="${esc(safeUrl(url))}" target="_blank" rel="noopener noreferrer">${label}</a>`);
    out=out.replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>');
    out=out.replace(/__([^_]+)__/g,'<strong>$1</strong>');
    out=out.replace(/(?<!\*)\*([^*\n]+)\*(?!\*)/g,'<em>$1</em>');
    out=out.replace(/@@CODE(\d+)@@/g,(_,i)=>code[Number(i)]||'');
    return out;
  }

  function markdown(text){
    const lines=String(text ?? '').replace(/\r\n/g,'\n').split('\n');
    const html=[]; let paragraph=[]; let list=null; let inCode=false; let codeLang=''; let code=[];
    const flushP=()=>{if(paragraph.length){html.push(`<p>${inlineMd(paragraph.join('\n')).replace(/\n/g,'<br>')}</p>`);paragraph=[];}};
    const flushList=()=>{if(list){html.push(`</${list}>`);list=null;}};
    const openList=(tag)=>{if(list!==tag){flushList();html.push(`<${tag}>`);list=tag;}};
    for(const raw of lines){
      const fence=raw.match(/^```\s*([A-Za-z0-9_+.-]*)\s*$/);
      if(fence){
        if(!inCode){flushP();flushList();inCode=true;codeLang=fence[1]||'';code=[];}
        else{const cls=codeLang?` class="language-${esc(codeLang)}"`:'';html.push(`<pre><code${cls}>${esc(code.join('\n'))}</code></pre>`);inCode=false;codeLang='';code=[];}
        continue;
      }
      if(inCode){code.push(raw);continue;}
      if(!raw.trim()){flushP();flushList();continue;}
      let m;
      if((m=raw.match(/^(#{1,4})\s+(.+)$/))){flushP();flushList();const n=m[1].length;html.push(`<h${n}>${inlineMd(m[2])}</h${n}>`);continue;}
      if(/^\s*([-*_])(?:\s*\1){2,}\s*$/.test(raw)){flushP();flushList();html.push('<hr>');continue;}
      if((m=raw.match(/^\s*[-*+]\s+(.+)$/))){flushP();openList('ul');html.push(`<li>${inlineMd(m[1])}</li>`);continue;}
      if((m=raw.match(/^\s*\d+[.)]\s+(.+)$/))){flushP();openList('ol');html.push(`<li>${inlineMd(m[1])}</li>`);continue;}
      if((m=raw.match(/^>\s?(.*)$/))){flushP();flushList();html.push(`<blockquote>${inlineMd(m[1])}</blockquote>`);continue;}
      paragraph.push(raw);
    }
    if(inCode){html.push(`<pre><code>${esc(code.join('\n'))}</code></pre>`);} else {flushP();flushList();}
    return html.join('');
  }

  window.AutoAgentRenderMessage=(el,text,role='assistant')=>{
    if(!el)return;
    if(role==='assistant'||role==='error'){
      el.classList.add('md');
      el.innerHTML=markdown(text);
    }else{
      el.classList.remove('md');
      el.textContent=String(text ?? '');
    }
  };

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

  async function refreshHistory(){
    if(!listEl)return;
    try{
      const d=await jsonFetch('/api/history?limit=24');
      listEl.replaceChildren();
      for(const c of d.conversations||[]){
        const b=document.createElement('button');b.className='history-item'+(c.id===activeConversation?' active':'');b.type='button';b.title=`${c.title||'New chat'} · ${formatHistoryTime(c.updated_at)}`;
        const title=document.createElement('span');title.className='history-title';title.textContent=c.title||'New chat';
        const agent=document.createElement('span');agent.className='history-agent';agent.textContent=(c.last_agent||'').slice(0,3);
        b.append(title,agent);b.onclick=()=>loadConversation(c.id);listEl.appendChild(b);
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
})();

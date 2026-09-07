(() => {
  const prompt = document.getElementById('prompt');
  const send = document.getElementById('send');
  const mode = document.getElementById('mode');
  const conversation = document.getElementById('conversation');
  const welcome = document.getElementById('welcome');
  const newChat = document.getElementById('newChat');
  if (!prompt || !send || !mode || !conversation || !welcome) return;

  let conversationId = (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()));
  let busy = false;

  function parseJsonResponse(r) {
    return r.text().then(text => {
      const ct = (r.headers.get('content-type') || '').toLowerCase();
      if (!ct.includes('application/json')) {
        const preview = (text || '').replace(/\s+/g, ' ').trim().slice(0, 180);
        throw new Error(`HTTP ${r.status} ${r.statusText}: expected JSON, received ${ct || 'unknown content-type'}${preview ? ` - ${preview}` : ''}`);
      }
      let data;
      try { data = JSON.parse(text || '{}'); }
      catch (_) { throw new Error(`HTTP ${r.status}: malformed JSON response`); }
      if (!r.ok) throw new Error(data.error || data.message || `HTTP ${r.status} ${r.statusText}`);
      return data;
    });
  }

  function createPending(agent) {
    welcome.style.display = 'none';
    const row = document.createElement('div');
    row.className = 'msg-row agent';
    const avatar = document.createElement('div');
    avatar.className = 'avatar';
    avatar.textContent = 'AI';
    const body = document.createElement('div');
    body.className = 'msg-body';
    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = `${agent || 'Auto Agent'} · working`;
    const text = document.createElement('div');
    text.className = 'msg-text';
    text.textContent = 'Thinking…';
    body.append(meta, text);
    row.append(avatar, body);
    conversation.appendChild(row);
    row.scrollIntoView({behavior:'smooth', block:'end'});
    return {row, meta, text};
  }

  function failPending(pending, error) {
    pending.row.className = 'msg-row error';
    pending.avatar && (pending.avatar.textContent = '!');
    pending.meta.textContent = 'Error';
    pending.text.textContent = String(error);
  }

  function setBusy(value) {
    busy = value;
    send.disabled = value;
    mode.disabled = value;
    if (!value) prompt.focus();
  }

  function addUserMessage(message) {
    welcome.style.display = 'none';
    const row = document.createElement('div');
    row.className = 'msg-row user';
    const body = document.createElement('div');
    body.className = 'msg-body';
    const text = document.createElement('div');
    text.className = 'msg-text';
    text.textContent = message;
    body.appendChild(text);
    row.appendChild(body);
    conversation.appendChild(row);
    row.scrollIntoView({behavior:'smooth', block:'end'});
  }

  async function sleep(ms) {
    await new Promise(resolve => setTimeout(resolve, ms));
  }

  async function pollJob(job, pending) {
    const deadline = Date.now() + 15 * 60 * 1000;
    let delay = Math.max(500, Number(job.retry_after_ms || 800));
    while (Date.now() < deadline) {
      await sleep(delay);
      const r = await fetch(job.poll_url, {cache:'no-store', headers:{'accept':'application/json'}});
      const data = await parseJsonResponse(r);
      if (data.status === 'done') {
        pending.meta.textContent = data.agent || job.agent || 'Auto Agent';
        pending.text.textContent = data.answer || '';
        mode.value = data.agent || mode.value;
        pending.row.scrollIntoView({behavior:'smooth', block:'end'});
        return;
      }
      if (data.status === 'error') {
        pending.row.className = 'msg-row error';
        pending.meta.textContent = 'Error';
        pending.text.textContent = data.error || 'Agent execution failed';
        return;
      }
      const elapsed = Number(data.elapsed_ms || 0);
      pending.meta.textContent = `${data.agent || job.agent || 'Auto Agent'} · working`;
      pending.text.textContent = elapsed >= 1000 ? `Thinking… ${Math.floor(elapsed / 1000)}s` : 'Thinking…';
      delay = Math.min(2500, Math.max(800, Number(data.retry_after_ms || 1200)));
    }
    throw new Error('Agent task exceeded the 15 minute client wait limit.');
  }

  async function asyncSend() {
    if (busy) return;
    const message = prompt.value.trim();
    if (!message) return;
    const selectedMode = mode.value;
    prompt.value = '';
    prompt.style.height = 'auto';
    addUserMessage(message);
    const pending = createPending(selectedMode === 'auto' ? 'Auto Agent' : selectedMode);
    setBusy(true);

    try {
      const r = await fetch('/api/chat', {
        method: 'POST',
        headers: {'content-type':'application/json', 'accept':'application/json'},
        body: JSON.stringify({message, mode:selectedMode, conversation_id:conversationId})
      });
      const job = await parseJsonResponse(r);
      if (!job.job_id || !job.poll_url) throw new Error('Async chat submission returned no job id.');
      pending.meta.textContent = `${job.agent || 'Auto Agent'} · queued`;
      await pollJob(job, pending);
    } catch (error) {
      pending.row.className = 'msg-row error';
      pending.meta.textContent = 'Error';
      pending.text.textContent = String(error);
    } finally {
      setBusy(false);
    }
  }

  // Replace the old synchronous button handler.
  send.onclick = asyncSend;

  // Capture Enter before the old synchronous key handler can run.
  prompt.addEventListener('keydown', event => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      event.stopImmediatePropagation();
      asyncSend();
    }
  }, true);

  if (newChat) {
    newChat.onclick = () => {
      if (busy) return;
      conversationId = (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()));
      conversation.querySelectorAll('.msg-row').forEach(node => node.remove());
      welcome.style.display = 'grid';
      mode.value = 'auto';
      const chatButton = document.querySelector('.nav-btn[data-tab="chat"]');
      if (chatButton) chatButton.click();
      prompt.focus();
    };
  }
})();

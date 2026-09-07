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

  function renderMessage(el, text, role='assistant') {
    if (window.AutoAgentRenderMessage) window.AutoAgentRenderMessage(el, text, role);
    else el.textContent = String(text ?? '');
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
    return {row, avatar, meta, text};
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
    renderMessage(text, message, 'user');
    body.appendChild(text);
    row.appendChild(body);
    conversation.appendChild(row);
    row.scrollIntoView({behavior:'smooth', block:'end'});
  }

  function formatDuration(seconds) {
    seconds = Math.max(0, Math.floor(Number(seconds || 0)));
    if (seconds < 60) return `${seconds}s`;
    const minutes = Math.floor(seconds / 60);
    const remSeconds = seconds % 60;
    if (minutes < 60) return remSeconds ? `${minutes}m ${remSeconds}s` : `${minutes}m`;
    const hours = Math.floor(minutes / 60);
    const remMinutes = minutes % 60;
    return remMinutes ? `${hours}h ${remMinutes}m` : `${hours}h`;
  }

  function policyLabel(policy) {
    if (!policy) return '';
    const hard = policy.hard_limit_seconds;
    if (hard == null) return 'agent runtime: no hard cap';
    return `agent runtime: ${formatDuration(hard)} max`;
  }

  async function sleep(ms) {
    await new Promise(resolve => setTimeout(resolve, ms));
  }

  async function pollJob(job, pending) {
    let delay = Math.max(500, Number(job.retry_after_ms || 800));
    let transientFailures = 0;
    const pollHeaders = {'accept':'application/json'};
    if (job.poll_token) pollHeaders['X-Auto-Agent-Job-Token'] = job.poll_token;

    for (;;) {
      await sleep(delay);
      let data;
      try {
        const r = await fetch(job.poll_url, {cache:'no-store', headers:pollHeaders});
        data = await parseJsonResponse(r);
        transientFailures = 0;
      } catch (error) {
        transientFailures += 1;
        if (transientFailures >= 8) throw error;
        pending.meta.textContent = `${job.agent || 'Auto Agent'} · reconnecting`;
        pending.text.textContent = `Temporary polling error. Retrying (${transientFailures}/8)…`;
        delay = Math.min(10000, Math.max(1500, delay * 1.8));
        continue;
      }

      const policy = data.runtime_policy || job.runtime_policy || {};
      if (data.status === 'done') {
        pending.meta.textContent = (data.agent || job.agent || 'Auto Agent').toUpperCase();
        // Verbatim agent content. Markdown rendering changes presentation only.
        renderMessage(pending.text, data.answer || '', 'assistant');
        mode.value = data.agent || mode.value;
        pending.row.scrollIntoView({behavior:'smooth', block:'end'});
        window.dispatchEvent(new CustomEvent('autoagent:history-changed'));
        return;
      }
      if (data.status === 'error') {
        pending.row.className = 'msg-row error';
        pending.avatar.textContent = '!';
        pending.meta.textContent = 'Error';
        renderMessage(pending.text, data.error || 'Agent execution failed', 'error');
        window.dispatchEvent(new CustomEvent('autoagent:history-changed'));
        return;
      }

      const elapsed = Number(data.elapsed_ms || 0) / 1000;
      const policyText = policyLabel(policy);
      pending.meta.textContent = `${data.agent || job.agent || 'Auto Agent'} · working`;
      pending.text.textContent = `Thinking… ${formatDuration(elapsed)}${policyText ? ` · ${policyText}` : ''}`;
      delay = Math.min(3000, Math.max(800, Number(data.retry_after_ms || 1200)));
    }
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
      if (job.conversation_id) conversationId = job.conversation_id;
      const label = policyLabel(job.runtime_policy);
      pending.meta.textContent = `${job.agent || 'Auto Agent'} · queued`;
      pending.text.textContent = label ? `Queued · ${label}` : 'Queued…';
      window.dispatchEvent(new CustomEvent('autoagent:history-changed'));
      await pollJob(job, pending);
    } catch (error) {
      pending.row.className = 'msg-row error';
      pending.avatar.textContent = '!';
      pending.meta.textContent = 'Error';
      renderMessage(pending.text, String(error), 'error');
    } finally {
      setBusy(false);
    }
  }

  function clearForNewChat() {
    if (busy) return false;
    conversationId = (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()));
    conversation.querySelectorAll('.msg-row').forEach(node => node.remove());
    welcome.style.display = 'grid';
    mode.value = 'auto';
    const chatButton = document.querySelector('.nav-btn[data-tab="chat"]');
    if (chatButton) chatButton.click();
    prompt.focus();
    window.dispatchEvent(new CustomEvent('autoagent:newchat'));
    return true;
  }

  send.onclick = asyncSend;
  prompt.addEventListener('keydown', event => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      event.stopImmediatePropagation();
      asyncSend();
    }
  }, true);

  if (newChat) newChat.onclick = clearForNewChat;

  window.AutoAgentChat = {
    getConversationId: () => conversationId,
    setConversationId: id => { if (id) conversationId = String(id); },
    newChat: clearForNewChat,
    busy: () => busy,
  };
})();

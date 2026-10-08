// One render per opaque frame. Source is a message, never executable HTML; no parent data is read.
(() => {
  let used = false;
  document.addEventListener('click', e => e.preventDefault(), true);
  window.addEventListener('message', async e => {
    if (used || e.source !== parent || e.data?.gradstep !== 'diagram' || typeof e.data.requestID !== 'string' || !/^[0-9a-f-]{36}$/.test(e.data.requestID) || typeof e.data.source !== 'string' || typeof e.data.dark !== 'boolean') return;
    used = true;
    const post = ok => parent.postMessage({ gradstep: 'diagram-result', requestID: e.data.requestID, ok }, '*');
    try {
      const source = e.data.source;
      if (!source.trim() || new TextEncoder().encode(source).length > 16000 || /%%\{|^\s*---/.test(source)) throw new Error('unsupported');
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: e.data.dark ? 'dark' : 'default',
        maxTextSize: 16000, maxEdges: 100, suppressErrorRendering: true, htmlLabels: false,
        fontFamily: 'system-ui, sans-serif',
        secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'suppressErrorRendering', 'dompurifyConfig', 'themeCSS', 'themeVariables', 'theme', 'fontFamily', 'htmlLabels'] });
      const { svg } = await mermaid.render('gradstep-diagram', source);
      document.getElementById('diagram').innerHTML = svg;
      // No navigation, remote images or embedded HTML, even if an upstream renderer regresses.
      document.querySelectorAll('script,foreignObject,image,iframe,object,embed').forEach(n => n.remove());
      document.querySelectorAll('*').forEach(n => { for (const a of [...n.attributes]) if (/^on|href$/i.test(a.name)) n.removeAttribute(a.name); });
      document.documentElement.style.colorScheme = e.data.dark ? 'dark' : 'light';
      post(true);
    } catch { document.getElementById('diagram').replaceChildren(); post(false); }
  });
})();

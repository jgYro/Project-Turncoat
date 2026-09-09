/* D3 consumes only the public {nodes, links} API; it has no storage/Grim knowledge. */
(() => {
  'use strict';
  const el = id => document.getElementById(id);
  const params = new URLSearchParams(location.search);
  const token = document.querySelector('meta[name="turncoat-token"]').content;
  const propertiesTree = new TurncoatJsonTree(el('properties'),link=>{
    const source=TurncoatDocumentLink(selected?.properties.sourceUrl);
    if(source && new URL(source,location.origin).searchParams.get('id')===new URL(link,location.origin).searchParams.get('id'))
      return link+'&'+new URLSearchParams({dataset:investigation||el('dataset').value,node:selected.id});
    return link;
  });
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
  let investigation = params.get('investigation'), job = null, pollTimer = null, busy = false;
  let searchAvailable = false;
  const svg = d3.select('#graph');
  const viewport = svg.append('g');
  const linkLayer = viewport.append('g');
  const nodeLayer = viewport.append('g');
  let followLayout = true, fitTimer = null, zoomLevel = 1, lastFit = 0;
  svg.append('defs').append('marker').attr('id', 'arrow').attr('viewBox', '0 -5 10 10')
    .attr('refX', 20).attr('refY', 0).attr('markerWidth', 6).attr('markerHeight', 6)
    .attr('orient', 'auto').append('path').attr('d', 'M0,-5L10,0L0,5').attr('fill', '#667b89');
  const zoom = d3.zoom().scaleExtent([0.02, 5]).on('zoom', event => {
    viewport.attr('transform', event.transform); zoomLevel = event.transform.k;
    if (event.sourceEvent) followLayout = false;
    updateLabels();
  });
  svg.call(zoom).on('dblclick.zoom', null);
  const nodeColors = d3.scaleOrdinal().domain(['Patent', 'Name mention', 'Paper', 'Assignee', 'Name search', 'Investigation'])
    .range(['#63e4dc','#efc579','#89aaff','#d9a0df','#78a5b4','#e1eaee']);
  const edgeColors = d3.scaleOrdinal(['#65b9b5','#cbb078','#7e9bd2','#af8bbd','#8cbbc0']);
  const nodes = new Map(), links = new Map(), expansions = new Map(), pending = new Set();
  let selected = null, generation = 0, searchGeneration = 0, paused = false;
  let searchPage = null, activeQuery = '';
  let limits = {neighborLimit: 100, maxNodes: 500, maxEdges: 1000};
  let nodeSelection = nodeLayer.selectAll('g'), linkSelection = linkLayer.selectAll('path');
  const simulation = d3.forceSimulation().force('link', d3.forceLink().id(d => d.id).distance(115))
    .force('charge', d3.forceManyBody().strength(-260)).force('center', d3.forceCenter())
    .force('collide', d3.forceCollide().radius(29)).on('tick', tick).on('end', () => {if (followLayout) fitGraph();});
  const endpoint = value => typeof value === 'object' ? value.id : value;
  const caption = node => String(node.properties.name || node.properties.title || node.id) +
    (node.label === 'Name search' ? ` · ${node.properties.provider === 'arXiv' ? 'arXiv' : 'Patents'}` : '');
  const apiPath = suffix => `/api/${encodeURIComponent(el('dataset').value)}${suffix}`;
  function status(message, error = false) {
    el('graph-status').textContent = message;
    el('graph-status').classList.toggle('error', error);
  }
  async function request(path, body) {
    const response = await fetch(path, {method: body === undefined ? 'GET' : 'POST',
      headers: {Accept: 'application/json', ...(body === undefined ? {} : {'Content-Type':'application/json','X-Turncoat-Token':token})},
      body: body === undefined ? undefined : JSON.stringify(body)});
    const data = await response.json();
    if (!response.ok) {const error = new Error(data.error?.message || `HTTP ${response.status}`); error.status = response.status; throw error;}
    return data;
  }
  function inspect(node) {
    selected = node;
    el('selection-hint').hidden = !!node;
    el('node-details').hidden = !node;
    el('node-id').textContent = node?.id || '';
    el('node-label').textContent = node?.label || '';
    propertiesTree.update(node?.properties || null, node?.id || '');
    el('chat-link').hidden = !node;
    el('drilldown-node').hidden = !node || !['Patent','Paper','Name mention','Name search','Person','Author','Inventor'].includes(node.label);
    if(node)el('chat-link').href='/chat?'+new URLSearchParams({dataset:investigation||el('dataset').value,node:node.id});
    el('selected-title').textContent = node ? caption(node) : '';
    el('evidence-note').textContent = node?.label === 'Name mention'
      ? 'A name listed on this source record. People with the same name have not been merged.'
      : node?.label === 'Name search' ? 'Results match a name query. This does not establish a shared identity or university affiliation.' : '';
    el('name-spelling').hidden = node?.label !== 'Name mention';
    el('spelling').value = node?.properties.originalName || '';
    const source = node?.properties.sourceUrl || node?.properties.queryUrl;
    let safeSource = false;
    try { const url = new URL(source); safeSource = url.protocol === 'https:' && ['arxiv.org','export.arxiv.org','patents.google.com'].includes(url.hostname) && !url.username && !url.password; } catch {}
    el('source-link').hidden = !safeSource;
    if (safeSource) {
      const reader=TurncoatDocumentLink(source);
      el('source-link').href=reader?reader+'&'+new URLSearchParams({dataset:investigation||el('dataset').value,node:node.id}):source;
      el('source-link').textContent=reader?'Read document →':'Open source ↗';
      if(reader)el('source-link').removeAttribute('target');else el('source-link').target='_blank';
    } else el('source-link').removeAttribute('href');
    nodeSelection.classed('selected', d => d.id === node?.id);
    updateLabels();
    updateExpansion();
  }
  function updateLabels() {
    const neighbors = new Set();
    if (selected) for (const link of links.values()) {
      if (endpoint(link.source) === selected.id) neighbors.add(endpoint(link.target));
      if (endpoint(link.target) === selected.id) neighbors.add(endpoint(link.source));
    }
    nodeLayer.selectAll('g.node').classed('quiet', d => nodes.size > 30 && zoomLevel < 1.1 &&
      ['Patent','Paper'].includes(d.label) && d.id !== selected?.id && !neighbors.has(d.id));
    // Keep visible names readable when the overview zooms out to fit a large graph.
    nodeLayer.selectAll('g.node text').attr('transform', `scale(${1 / zoomLevel})`);
  }
  function fitGraph(animate = true) {
    const values = [...nodes.values()].filter(n => Number.isFinite(n.x) && Number.isFinite(n.y));
    const {width,height} = el('canvas').getBoundingClientRect();
    if (width <= 0 || height <= 0) return;
    lastFit = performance.now();
    svg.interrupt();
    if (!values.length) {svg.call(zoom.transform,d3.zoomIdentity.translate(width/2,height/2)); return;}
    const [left,right] = d3.extent(values,n=>n.x), [top,bottom] = d3.extent(values,n=>n.y);
    const padX = Math.min(100,width*.2), padY = Math.min(55,height*.2);
    const scale = Math.max(.02,Math.min(1.15,(width-2*padX)/(right-left+60),(height-2*padY)/(bottom-top+60)));
    const transform = d3.zoomIdentity.translate(width/2-scale*(left+right)/2,height/2-scale*(top+bottom)/2).scale(scale);
    if (animate && !reducedMotion) svg.transition().duration(220).call(zoom.transform,transform);
    else svg.call(zoom.transform,transform);
  }
  function updateExpansion() {
    el('discover').disabled = !investigation || busy || !selected || !['Patent','Paper','Name mention'].includes(selected.label) || job?.requests >= job?.limits.maxRequests;
    el('discover').textContent = selected?.label === 'Name mention' ? 'Search this name' : 'Search related names';
    const page = selected && expansions.get(selected.id);
    el('expand').disabled = !selected || pending.has(selected.id) || (page && !page.hasMore);
    el('more').hidden = !page?.hasMore;
    el('more').disabled = !!selected && pending.has(selected.id);
    el('expansion-status').textContent = page
      ? `${page.offset + page.returned} of ${page.total} relationships loaded for this node.${page.hasMore ? ' More relationships are available.' : ''}`
      : (selected ? 'Expand to load this node’s relationships.' : '');
  }
  function tick() {
    linkSelection.attr('d', d => {
      if (d.source.id === d.target.id) {
        const r = 30 + d.parallel * 12;
        return `M${d.source.x},${d.source.y}c${r},${-r * 2} ${-r},${-r * 2} 0,-1`;
      }
      const dx = d.target.x - d.source.x, dy = d.target.y - d.source.y;
      const radius = Math.hypot(dx, dy) * (1.3 + d.parallel * 0.6);
      return `M${d.source.x},${d.source.y}A${radius},${radius} 0 0,1 ${d.target.x},${d.target.y}`;
    });
    nodeSelection.attr('transform', d => `translate(${d.x || 0},${d.y || 0})`);
    if (followLayout && performance.now()-lastFit > 250) fitGraph();
  }
  function legend() {
    el('legend').replaceChildren();
    for (const [title, labels, colors, isEdge] of [
      ['Nodes', new Set([...nodes.values()].map(n => n.label)), nodeColors, false],
      ['Relationships', new Set([...links.values()].map(l => l.label)), edgeColors, true]]) {
      const heading = document.createElement('h3'); heading.textContent = title; el('legend').append(heading);
      for (const label of [...labels].sort()) {
        const row = document.createElement('div'); row.className = 'legend-row';
        const icon = d3.select(row).append('svg').attr('aria-hidden', true);
        if (isEdge) icon.append('line').attr('x1', 0).attr('x2', 16).attr('y1', 8).attr('y2', 8).attr('stroke', colors(label)).attr('stroke-width', 3);
        else icon.append('circle').attr('cx', 8).attr('cy', 8).attr('r', 6).attr('fill', colors(label));
        const text = document.createElement('span'); text.textContent = label; row.append(text); el('legend').append(row);
      }
    }
  }
  function render() {
    const nodeData = [...nodes.values()], linkData = [...links.values()], pairs = new Map();
    for (const link of linkData) {
      const pair = JSON.stringify([endpoint(link.source), endpoint(link.target)].sort());
      link.parallel = pairs.get(pair) || 0; pairs.set(pair, link.parallel + 1);
    }
    linkSelection = linkLayer.selectAll('path').data(linkData, d => d.id).join(enter => {
      const path = enter.append('path').attr('class', 'link arriving').attr('marker-end', 'url(#arrow)'); path.append('title'); return path;
    }).attr('stroke', d => edgeColors(d.label)).classed('candidate', d => d.label === 'name_search_hit');
    linkSelection.select('title').text(d => `${d.label}\n${d.id}\n${JSON.stringify(d.properties)}`);
    nodeSelection = nodeLayer.selectAll('g').data(nodeData, d => d.id).join(enter => {
      const group = enter.append('g').attr('class', 'node arriving').attr('tabindex', 0).attr('role', 'button');
      group.append('circle').attr('class','halo').attr('r',18);
      group.append('circle').attr('class','core').attr('r', d => d.label === 'Patent' ? 10 : 7);
      group.append('text').attr('x', 21).attr('y', 4); group.append('title');
      group.on('click', (_, node) => inspect(node)).on('dblclick', (event, node) => {event.preventDefault(); inspect(node); expand(node);})
        .on('contextmenu', (event,node) => {inspect(node);window.TurncoatDrilldown?.contextMenu(event,node,investigation||el('dataset').value,event.currentTarget);})
        .on('keydown', (event, node) => {if(event.key==='ContextMenu'||event.key==='F10'&&event.shiftKey){window.TurncoatDrilldown?.contextMenu(event,node,investigation||el('dataset').value,event.currentTarget);}else if (event.key === 'Enter' || event.key === ' ') {event.preventDefault(); inspect(node);}})
        .call(d3.drag().on('start', (event, node) => {
          followLayout = false; svg.interrupt();
          if (!paused && !event.active) simulation.alphaTarget(0.2).restart(); node.fx = node.x; node.fy = node.y;
        }).on('drag', (event, node) => {node.fx = node.x = event.x; node.fy = node.y = event.y; tick();})
          .on('end', (event, node) => {if (!event.active) simulation.alphaTarget(0); node.fx = null; node.fy = null;}));
      return group;
    }).attr('aria-label', d => `${caption(d)}, ${d.label}`).classed('selected', d => d.id === selected?.id);
    nodeSelection.select('.core').attr('fill', d => nodeColors(d.label));
    nodeSelection.select('.halo').attr('stroke', d => nodeColors(d.label));
    nodeSelection.select('text').text(d => {const text = caption(d); return text.length > 32 ? text.slice(0, 31) + '…' : text;});
    nodeSelection.select('title').text(d => `${caption(d)}\n${d.label}\n${d.id}`);
    simulation.nodes(nodeData); simulation.force('link').links(linkData);
    if (!paused) simulation.alpha(0.6).restart(); else tick();
    el('counts').textContent = `${nodes.size} nodes · ${links.size} relationships`;
    el('canvas-empty').hidden = nodes.size > 0;
    legend();
    updateLabels();
    clearTimeout(fitTimer);
    if (followLayout) {fitGraph(false); fitTimer = setTimeout(() => {if (followLayout) fitGraph();}, 500);}
  }
  function merge(data) {
    const newNodes = data.nodes.filter(n => !nodes.has(n.id)), newLinks = data.links.filter(l => !links.has(l.id));
    if (nodes.size + newNodes.length > limits.maxNodes || links.size + newLinks.length > limits.maxEdges)
      throw new Error(`Canvas limit reached (${limits.maxNodes} nodes, ${limits.maxEdges} relationships). Clear the graph and choose a new seed. This page was not added.`);
    for (const node of data.nodes) {
      if (nodes.has(node.id)) {Object.assign(nodes.get(node.id), {label:node.label, properties:node.properties}); continue;}
      const related = data.links.find(link => endpoint(link.target) === node.id && nodes.has(endpoint(link.source)));
      const parent = related && nodes.get(endpoint(related.source));
      nodes.set(node.id, {...node, ...(parent ? {x:parent.x + Math.random()*36-18, y:parent.y + Math.random()*36-18} : {})});
    }
    for (const link of newLinks) links.set(link.id, {...link});
    if (newNodes.length || newLinks.length) render();
    else nodeSelection.select('text').text(d => caption(d).length > 32 ? caption(d).slice(0,31)+'…' : caption(d));
  }
  async function expand(node) {
    if (!node || pending.has(node.id)) return;
    const previous = expansions.get(node.id);
    if (previous && !previous.hasMore) return;
    const epoch = generation, offset = previous?.nextOffset || 0;
    pending.add(node.id); updateExpansion(); status(`Loading relationships for ${caption(node)}…`);
    try {
      const data = await request(apiPath(`/node/${encodeURIComponent(node.id)}/neighbors?limit=${limits.neighborLimit}&offset=${offset}`));
      if (epoch !== generation) return;
      merge(data); expansions.set(node.id, data.meta);
      status(data.meta.hasMore ? `${offset + data.meta.returned} of ${data.meta.total} relationships loaded. Select Load more relationships to continue.` : `Loaded all ${data.meta.total} relationships for ${caption(node)}.`);
    } catch (error) {if (epoch === generation) status(error.message, true);}
    finally {if (epoch === generation) {pending.delete(node.id); updateExpansion();}}
  }
  function clear() {
    generation++; nodes.clear(); links.clear(); expansions.clear(); pending.clear();
    followLayout = true; clearTimeout(fitTimer);
    simulation.stop(); render(); inspect(null); status('Search for a seed node to explore.');
  }
  async function seed(node) {
    detachInvestigation();
    clear(); merge({nodes: [node], links: []}); inspect(nodes.get(node.id)); await expand(selected);
  }
  async function search(more = false) {
    const epoch = ++searchGeneration, dataset = el('dataset').value;
    if (!dataset) return;
    const query = more ? activeQuery : el('search').value.trim();
    if (!query) return;
    const offset = more ? searchPage?.nextOffset || 0 : 0;
    if (!more) {activeQuery = query; searchPage = null; el('results').replaceChildren();}
    el('search-status').textContent = 'Searching…'; el('search-submit').disabled = true; el('search-more').hidden = true;
    try {
      const data = await request(apiPath(`/search?q=${encodeURIComponent(query)}&limit=30&offset=${offset}`));
      if (epoch !== searchGeneration || dataset !== el('dataset').value) return;
      searchPage = data.meta;
      for (const node of data.nodes) {
        const button = document.createElement('button'); button.className = 'result'; button.textContent = caption(node);
        const detail = document.createElement('small'); detail.textContent = `${node.label} · ${node.id}`; button.append(detail);
        button.addEventListener('click', () => seed(node)); el('results').append(button);
      }
      el('search-status').textContent = `${offset + data.meta.returned} of ${data.meta.total} results`;
      el('search-more').hidden = !data.meta.hasMore;
    } catch (error) {if (epoch === searchGeneration) el('search-status').textContent = error.message;}
    finally {if (epoch === searchGeneration) el('search-submit').disabled = false;}
  }
  el('search-form').addEventListener('submit', event => {event.preventDefault(); search();});
  el('search-more').addEventListener('click', () => search(true));
  el('expand').addEventListener('click', () => expand(selected)); el('more').addEventListener('click', () => expand(selected));
  el('clear').addEventListener('click', () => {detachInvestigation(); clear();});
  el('center').addEventListener('click', () => {followLayout = true; fitGraph();});
  el('pause').addEventListener('click', () => {paused = !paused; el('pause').textContent = paused ? 'Resume layout' : 'Pause layout'; if (paused) simulation.stop(); else simulation.alpha(0.4).restart();});
  el('dataset').addEventListener('change', () => {detachInvestigation(); searchGeneration++; el('search-submit').disabled = false; clear(); el('results').replaceChildren(); el('search-status').textContent = ''; el('search-more').hidden = true; searchPage = null;});
  const workspace = el('graph-workspace'), compact = matchMedia('(max-width: 1000px)');
  const panelIds = {left:'search-panel',right:'details-panel'}, panelNames = {left:'workspace',right:'inspector'};
  const panelKey = 'turncoat-graph-panels-v1';
  let storedPanels = {};
  try {storedPanels = JSON.parse(localStorage.getItem(panelKey)) || {};} catch {}
  const panels = {};
  for (const side of ['left','right']) {
    const saved = storedPanels[side] || {};
    panels[side] = {mode:saved.mode === 'floating' ? 'floating' : 'docked', hidden:compact.matches || saved.hidden === true,
      x:Number.isFinite(saved.x)?saved.x:null, y:Number.isFinite(saved.y)?saved.y:null};
  }
  function savePanels() {try {localStorage.setItem(panelKey,JSON.stringify(panels));} catch {}}
  function positionPanel(side) {
    if (!workspace.clientWidth || !workspace.clientHeight) return;
    const panel = el(panelIds[side]), state = panels[side];
    if (state.mode !== 'floating' || state.hidden) return;
    const width = workspace.clientWidth, height = workspace.clientHeight;
    const x = state.x ?? (side === 'left' ? 12 : width-panel.offsetWidth-12), y = state.y ?? 12;
    state.x = Math.max(0,Math.min(x,width-panel.offsetWidth)); state.y = Math.max(0,Math.min(y,height-panel.offsetHeight));
    panel.style.left = state.x+'px'; panel.style.top = state.y+'px';
  }
  function applyPanel(side) {
    const state = panels[side], panel = el(panelIds[side]), toggle = el('toggle-'+side);
    panel.hidden = state.hidden; panel.classList.toggle('floating',state.mode === 'floating');
    workspace.classList.toggle(side+'-free',state.hidden || state.mode === 'floating');
    toggle.setAttribute('aria-expanded',String(!state.hidden));
    toggle.setAttribute('aria-label',(state.hidden?'Show ':'Hide ')+panelNames[side]+' panel');
    toggle.title = toggle.getAttribute('aria-label');
    const dock = panel.querySelector('[data-panel-action="dock"]'), header = panel.querySelector('.panel-header');
    const action = state.mode === 'floating' ? 'Dock' : 'Undock';
    dock.textContent = action; dock.title = action+' '+panelNames[side]+' panel'; dock.setAttribute('aria-label',dock.title);
    header.tabIndex = state.mode === 'floating' ? 0 : -1;
    header.title = state.mode === 'floating' ? 'Drag to move. Focus here and use arrow keys to move; Escape hides the panel.' : '';
    if (state.mode === 'docked') for (const property of ['left','top','width','height']) panel.style.removeProperty(property);
    positionPanel(side);
  }
  function showPanel(side, visible) {
    panels[side].hidden = !visible;
    if (compact.matches && visible) {const other = side === 'left' ? 'right' : 'left'; panels[other].hidden = true; applyPanel(other);}
    applyPanel(side); savePanels();
    if (visible) el(panelIds[side]).querySelector('[data-panel-action="dock"]').focus(); else el('toggle-'+side).focus();
  }
  for (const side of ['left','right']) {
    const panel = el(panelIds[side]), header = panel.querySelector('.panel-header');
    el('toggle-'+side).addEventListener('click',()=>showPanel(side,panels[side].hidden));
    panel.querySelector('[data-panel-action="hide"]').addEventListener('click',()=>showPanel(side,false));
    panel.querySelector('[data-panel-action="dock"]').addEventListener('click',()=>{
      panels[side].mode = panels[side].mode === 'floating' ? 'docked' : 'floating'; applyPanel(side); savePanels();
      if (panels[side].mode === 'floating') header.focus();
    });
    panel.addEventListener('keydown',event=>{if (event.key === 'Escape') {event.preventDefault();showPanel(side,false);}});
    header.addEventListener('keydown',event=>{
      if (event.target !== header || panels[side].mode !== 'floating' || !['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(event.key)) return;
      event.preventDefault(); const amount = event.shiftKey ? 40 : 10;
      panels[side].x += event.key === 'ArrowRight' ? amount : event.key === 'ArrowLeft' ? -amount : 0;
      panels[side].y += event.key === 'ArrowDown' ? amount : event.key === 'ArrowUp' ? -amount : 0;
      positionPanel(side);savePanels();
    });
    let drag = null;
    header.addEventListener('pointerdown',event=>{
      if (panels[side].mode !== 'floating' || event.button !== 0 || event.target.closest('button')) return;
      event.preventDefault();header.focus();header.setPointerCapture(event.pointerId);
      drag = {x:event.clientX,y:event.clientY,left:panels[side].x,top:panels[side].y};panel.classList.add('dragging');
    });
    header.addEventListener('pointermove',event=>{
      if (!drag) return;
      panels[side].x = drag.left+event.clientX-drag.x;panels[side].y = drag.top+event.clientY-drag.y;positionPanel(side);
    });
    for (const event of ['pointerup','pointercancel','lostpointercapture']) header.addEventListener(event,()=>{drag=null;panel.classList.remove('dragging');savePanels();});
    applyPanel(side);
  }
  compact.addEventListener('change',()=>{
    if (compact.matches) for (const side of ['left','right']) panels[side].hidden = true;
    for (const side of ['left','right']) applyPanel(side);
  });
  const panelResize = new ResizeObserver(()=>{for (const side of ['left','right']) positionPanel(side);});
  panelResize.observe(workspace);for (const id of Object.values(panelIds)) panelResize.observe(el(id));
  let canvasSize = null;
  new ResizeObserver(() => {
    const {width, height} = el('canvas').getBoundingClientRect();
    if (width <= 0 || height <= 0 || (canvasSize?.width === width && canvasSize?.height === height)) return;
    svg.attr('viewBox', `0 0 ${width} ${height}`); zoom.extent([[0,0],[width,height]]);
    el('canvas').style.setProperty('--radar-size',Math.min(460,width*.7,height*.75)+'px');
    // Layout uses stable world coordinates. Panel changes resize the camera, not the simulation.
    if (followLayout || !canvasSize) fitGraph(false);
    else {
      svg.interrupt();
      const current = d3.zoomTransform(svg.node()), center = current.invert([canvasSize.width/2,canvasSize.height/2]);
      svg.call(zoom.transform,d3.zoomIdentity.translate(width/2-current.k*center[0],height/2-current.k*center[1]).scale(current.k));
    }
    canvasSize = {width,height};
  }).observe(el('canvas'));
  function detachInvestigation() {
    el('share-investigation').hidden=true;
    clearTimeout(pollTimer); investigation = null; job = null; busy = false;
    document.body.classList.remove('is-investigating'); el('stop-investigation').hidden = true;
    el('job-state').textContent = 'LOCAL GRAPH';
    el('mission-note').textContent = 'Browsing saved evidence. An active investigation continues in the background; reopen it to stop or inspect progress.';
    history.replaceState(null, '', '/graph'); updateExpansion();
  }
  async function savedInvestigations() {
    const data = await request('/api/investigations'); el('investigations-list').replaceChildren();
    if (!data.investigations.length) el('investigations-list').textContent = 'No investigations saved yet.';
    for (const item of data.investigations) {
      const link = document.createElement('a'); link.href = `/graph?investigation=${encodeURIComponent(item.id)}`;
      link.textContent = item.job.publicationNumber;
      const state = document.createElement('small'); state.textContent = `${item.job.state} · ${item.job.requests} requests`; link.append(state);
      el('investigations-list').append(link);
    }
  }
  async function pollInvestigation() {
    clearTimeout(pollTimer);
    if (!investigation) return;
    const id = investigation;
    try {
      const data = await request(`/api/investigations/${encodeURIComponent(id)}`);
      if (id !== investigation) return;
      job = data.job; busy = data.busy;
      el('share-investigation').hidden=false;el('share-investigation').dataset.investigation=id;
      limits.maxNodes = Math.max(limits.maxNodes, job.limits.maxNodes);
      limits.maxEdges = Math.max(limits.maxEdges, job.limits.maxEdges);
      merge(data);
      if (selected) {el('selected-title').textContent = caption(selected); propertiesTree.update(selected.properties,selected.id);}
      if (!selected && nodes.has(job.seed)) inspect(nodes.get(job.seed));
      if (![...el('dataset').options].some(option => option.value === id)) {
        const option = document.createElement('option'); option.value = id; option.textContent = job.publicationNumber + ' investigation'; el('dataset').append(option);
      }
      el('dataset').value = id; el('dataset').disabled = false;
      el('search-submit').disabled = !searchAvailable;
      el('mission-title').textContent = job.publicationNumber + ' / investigation';
      el('mission-note').textContent = 'Source-listed names → name searches → candidate publications. Dashed links are search hits, not verified identities. Select a result to explore further.';
      el('job-state').textContent = job.state.toUpperCase();
      el('request-count').textContent = `${job.requests} / ${job.limits.maxRequests} REQUESTS · 2 PROVIDERS`;
      el('stop-investigation').hidden = job.state !== 'running';
      document.body.classList.toggle('is-investigating', job.state === 'running');
      const events = job.events.slice(-12).reverse(), signature = JSON.stringify(events);
      if (el('activity-log').dataset.signature !== signature) {
        el('activity-log').dataset.signature = signature; el('activity-log').replaceChildren();
        for (const event of events) {const row = document.createElement('li'), time = document.createElement('time'); time.textContent = event.at.slice(11,19) + ' UTC'; row.append(time, document.createTextNode(event.message)); el('activity-log').append(row);}
      }
      const last = job.events.at(-1)?.message;
      status(last || 'Preparing the seed patent…', ['failed','partial','limited'].includes(job.state));
      updateExpansion();
      if (job.state === 'running' || busy) pollTimer = setTimeout(pollInvestigation, 900);
      else await savedInvestigations();
    } catch (error) {
      const retry = !error.status || error.status >= 500;
      status(error.message + (retry ? ' Retrying saved progress…' : ''), true);
      if (retry && id === investigation) pollTimer = setTimeout(pollInvestigation, 3000);
    }
  }
  el('discover').addEventListener('click', async () => {
    if (!selected || !investigation || busy) return;
    busy = true; updateExpansion();
    try {await request(`/api/investigations/${encodeURIComponent(investigation)}/expand`, {node:selected.id, spelling:selected.label === 'Name mention' ? el('spelling').value : ''}); await pollInvestigation();}
    catch(error) {busy = false; updateExpansion(); status(error.message, true);}
  });
  el('drilldown-node').addEventListener('click',()=>window.TurncoatDrilldown?.openNode(selected,investigation||el('dataset').value));
  document.addEventListener('turncoat:workspace-view',event=>{if(event.detail.graph){if(!paused)simulation.alpha(.1).restart();else tick();}else simulation.stop();});
  window.addEventListener('pagehide', () => clearTimeout(pollTimer));
  el('stop-investigation').addEventListener('click', async () => {
    if (!investigation) return;
    try {await request(`/api/investigations/${encodeURIComponent(investigation)}/cancel`, {}); await pollInvestigation();}
    catch(error) {status(error.message, true);}
  });
  Promise.all([request('/api/health'), request('/api/datasets'), savedInvestigations()]).then(async ([health, data]) => {
    searchAvailable = health.fts5;
    limits = health.limits; el('dataset').replaceChildren();
    for (const dataset of data.datasets) {const option = document.createElement('option'); option.value = dataset.id; option.textContent = `${dataset.id} (${dataset.nodes} nodes)`; el('dataset').append(option);}
    el('dataset').disabled = data.datasets.length === 0;
    el('search-submit').disabled = !health.fts5 || data.datasets.length === 0;
    if (!data.datasets.length) status('No datasets yet. Import a JSONL dataset with the CLI, then refresh this page.');
    else if (!health.fts5) status('Search is unavailable: this server has FTS5 disabled or unsupported.', true);
    if (params.has('patent') && !investigation) {
      status('Starting investigation…');
      const created = await request('/api/investigations', {publication:params.get('patent')});
      investigation = created.id; history.replaceState(null, '', created.url);
    }
    if (investigation) await pollInvestigation();
  }).catch(error => status(error.message, true));
})();

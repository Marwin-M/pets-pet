// Pet's Pet sidebar renderer. Local records are supplied by the native controller.
(function setupPetsPetSidebar(settings) {
  const key = '__petsPetSidebar';
  const version = 9;
  const previous = window[key];
  if (previous?.version === version) {
    previous.configure(settings);
    return previous.requested();
  }
  previous?.destroy?.();

  const threadSelector = '[data-app-action-sidebar-thread-row][data-app-action-sidebar-thread-id]';
  const projectSelector = '[data-app-action-sidebar-project-row][data-app-action-sidebar-project-id]';
  const threadMark = 'data-petspet-thread-tokens';
  const projectMark = 'data-petspet-project-size';
  const owned = 'data-petspet-sidebar-owned';
  const threadElements = new Map();
  const projectElements = new Map();
  const threadBadges = new WeakSet();
  let enabled = { tokens: false, projects: false };
  let records = {};
  let lastContact = Date.now();
  let disposed = false;
  let repaint = 0;
  let hoverTimer = 0;
  let hoverTarget = null;
  let projectDirectoryCache = null;
  let directoryReadAt = 0;
  let quota = null;
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  const style = document.createElement('style');
  style.setAttribute(owned, 'style');
  style.textContent = `
    [${threadMark}] { box-sizing: border-box; display: inline-flex; width: 12px; height: 12px;
      min-width: 12px; flex-shrink: 0; border-radius: 3px; border: 1px solid #8884;
      align-self: center; user-select: none; -webkit-app-region: no-drag; }
    ${threadSelector}:has(> [${threadMark}]), ${threadSelector} :has(> [${threadMark}]) {
      display: flex; align-items: center; column-gap: 6px; min-width: 0;
    }
    [${threadMark}] + [data-thread-title] { min-width: 0; flex: 1; overflow: hidden;
      text-overflow: ellipsis; white-space: nowrap; }
    [${projectMark}] { flex: 0 0 auto; margin-inline: 6px 4px; max-width: 82px;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      font: 11px/1.4 -apple-system, BlinkMacSystemFont, sans-serif;
      font-variant-numeric: tabular-nums; color: var(--color-text-tertiary, inherit); opacity: .62; }
    [${owned}="tooltip"] { position: fixed; top: 0; left: 0; pointer-events: none; z-index: 2147483000;
      max-width: min(340px, calc(100vw - 20px)); padding: 9px 11px; border-radius: 8px;
      border: 1px solid #8884; box-shadow: 0 3px 14px #0002;
      font: 12px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; white-space: pre-line; }
    [${owned}="tooltip"][hidden] { display: none; }
    [${owned}="quota"] { box-sizing: border-box; position: absolute; inset-inline: 0; z-index: 21;
      display: flex; justify-content: center; height: 80px; padding: 0; background: none;
      opacity: .78; pointer-events: none; user-select: none; }
    [${owned}="quota"] img { display: block; width: 144px; height: 80px; max-width: none; }
    [${owned}="quota-spacer"] { flex: 0 0 auto; width: 1px; pointer-events: none; }
  `;
  const tooltip = document.createElement('div');
  tooltip.id = 'petspet-thread-tokens-tooltip';
  tooltip.setAttribute(owned, 'tooltip');
  tooltip.setAttribute('role', 'tooltip');
  tooltip.hidden = true;
  const quotaSlot = document.createElement('div');
  quotaSlot.setAttribute(owned, 'quota');
  const quotaImage = document.createElement('img');
  quotaImage.draggable = false;
  quotaSlot.append(quotaImage);
  const quotaLayout = new ResizeObserver(queuePaint);
  const quotaObserved = new Set();
  const quotaSpacers = new Map();

  function clearQuotaSpacing() {
    for (const spacer of quotaSpacers.values()) spacer.remove();
    quotaSpacers.clear();
  }

  function observeQuota(elements) {
    const next = new Set(elements);
    for (const element of quotaObserved) if (!next.has(element)) { quotaLayout.unobserve(element); quotaObserved.delete(element); }
    for (const element of next) if (!quotaObserved.has(element)) { quotaLayout.observe(element); quotaObserved.add(element); }
  }

  function validQuotaPayload(proposed) {
    // Only native PNGs are accepted; the renderer cannot fetch arbitrary URLs.
    return !!(proposed && ['light', 'dark'].every(key => typeof proposed[key] === 'string' &&
      proposed[key].length <= 128000 && /^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(proposed[key])) &&
      typeof proposed.label === 'string' && proposed.label.length <= 512);
  }

  function quotaBottomOffset(rootBottom, avatarBottom) {
    if (!Number.isFinite(rootBottom) || !Number.isFinite(avatarBottom)) return null;
    const bottom = rootBottom - avatarBottom - 8;
    return bottom >= 0 && bottom <= 80 ? bottom : null;
  }

  function paintQuota() {
    if (!quota) { quotaSlot.remove(); clearQuotaSpacing(); observeQuota([]); return; }
    // Anchor to the sidebar, without creating a separate footer or reducing
    // the list viewport. A transparent spacer in the scrolling content lets
    // the last chat scroll above the floating component.
    const roots = [...document.querySelectorAll('[data-sidebar-navigation-root]')].filter(root =>
      root.getClientRects().length && !root.closest('[hidden], [inert], [aria-hidden="true"], [data-sidebar-collapsed]'));
    const root = roots.length === 1 ? roots[0] : null;
    const scrolls = root ? [...root.querySelectorAll('[data-app-action-sidebar-scroll], .overflow-y-auto')]
      .filter(element => element.getClientRects().length && element.getBoundingClientRect().width >= 160 &&
        element.getBoundingClientRect().height >= 80 && ['auto', 'scroll'].includes(getComputedStyle(element).overflowY)) : [];
    const avatars = root ? [...root.parentElement.querySelectorAll('[data-app-navigation-rail] .sidebar-item button .rounded-full')]
      .filter(element => element.getClientRects().length && !element.closest('[hidden], [inert]') && getComputedStyle(element).visibility !== 'hidden' &&
        element.getBoundingClientRect().width >= 16 && element.getBoundingClientRect().width <= 48) : [];
    // Avatar initials deliberately have aria-hidden=true; they are still the
    // visible circle. The button supplies the accessible name.
    const avatar = avatars.length === 1 ? avatars[0] : null;
    if (!avatar || !scrolls.length || root.getBoundingClientRect().width < 160) {
      quotaSlot.remove(); clearQuotaSpacing(); observeQuota(root ? [root] : []); return;
    }
    observeQuota([root, avatar, ...scrolls]);
    // The native 144×80 image contains 8 pt transparent padding around its
    // 128×64 body. Align the body's bottom, rather than the PNG's outer edge.
    const bottom = quotaBottomOffset(root.getBoundingClientRect().bottom, avatar.getBoundingClientRect().bottom);
    if (bottom === null) { quotaSlot.remove(); clearQuotaSpacing(); return; }
    const offset = `${bottom}px`;
    if (quotaSlot.style.bottom !== offset) quotaSlot.style.bottom = offset;
    for (const [scroll, spacer] of quotaSpacers) if (!scrolls.includes(scroll)) { spacer.remove(); quotaSpacers.delete(scroll); }
    const imageTop = root.getBoundingClientRect().bottom - bottom - 80;
    for (const scroll of scrolls) {
      let spacer = quotaSpacers.get(scroll);
      if (!spacer) { spacer = document.createElement('div'); spacer.setAttribute(owned, 'quota-spacer'); spacer.setAttribute('aria-hidden', 'true'); quotaSpacers.set(scroll, spacer); }
      const height = `${Math.max(0, scroll.getBoundingClientRect().bottom - imageTop)}px`;
      if (spacer.style.height !== height) spacer.style.height = height;
      if (spacer.parentElement !== scroll || scroll.lastElementChild !== spacer) scroll.append(spacer);
    }
    const source = (quota.appearance === 'dark' || quota.appearance !== 'light' && darkMode()) ? quota.dark : quota.light;
    if (quotaImage.getAttribute('src') !== source) quotaImage.src = source;
    setAttribute(quotaImage, 'alt', quota.label);
    if (quotaSlot.parentElement !== root) root.append(quotaSlot);
  }

  function darkMode() {
    const html = document.documentElement;
    if (html.classList.contains('dark') || html.dataset.theme === 'dark') return true;
    if (html.classList.contains('light') || html.dataset.theme === 'light') return false;
    const scheme = getComputedStyle(html).colorScheme;
    return scheme === 'dark' || scheme !== 'light' && media.matches;
  }
  function localThread(row) {
    if (row.getAttribute('data-app-action-sidebar-thread-host-id') !== 'local' ||
        row.getAttribute('data-app-action-sidebar-thread-kind') !== 'local') return null;
    const raw = row.getAttribute('data-app-action-sidebar-thread-id') || '';
    return /^local:[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i.test(raw) ? raw.slice(6).toLowerCase() : null;
  }
  function projectId(row) {
    const id = row.getAttribute('data-app-action-sidebar-project-id');
    return id && id.length <= 512 ? id : null;
  }
  function localProject(row) {
    return (row.querySelector('[data-sidebar-project-kind]') || row.closest('[data-sidebar-project-kind]'))
      ?.getAttribute('data-sidebar-project-kind') === 'local';
  }
  function conciseTokens(value) {
    if (value >= 100000000) return `${Number((value / 100000000).toFixed(2))}亿`;
    if (value >= 10000) return `${Number((value / 10000).toFixed(2))}万`;
    return value.toLocaleString('zh-CN');
  }
  function tokenView(row) {
    const id = localThread(row), source = records.tokens;
    if (!id) return { state: 'unknown', hint: '此对话没有可读取的本地 Token 记录' };
    if (!source) return { state: 'loading', hint: '正在读取对话用量' };
    if (!source.ok) return { state: 'unknown', hint: '用量读取失败，正在重试' };
    if (!Number.isFinite(source.checkedAt) || Date.now() - source.checkedAt > 30000)
      return { state: 'stale', hint: '用量数据已过期，等待重新连接' };
    const value = source.totals?.[id];
    if (!Number.isSafeInteger(value) || value < 0) return { state: 'unknown', hint: '此对话没有可读取的本地 Token 记录' };
    const grade = value === 0 ? 0 : value < 1000000 ? 1 : value < 10000000 ? 2 : value < 100000000 ? 3 : 4;
    const detail = source.details?.[id];
    const valid = detail && ['input', 'cached', 'output', 'total'].every(field => Number.isSafeInteger(detail[field]) && detail[field] >= 0)
      && detail.total === value && detail.input + detail.output === value && detail.cached <= detail.input;
    const lines = [`累计使用 ${conciseTokens(value)} Token`];
    if (valid) lines.push(
      `输入（未命中缓存）：${conciseTokens(detail.input - detail.cached)} Token`,
      `缓存命中：${conciseTokens(detail.cached)} Token`,
      `输出：${conciseTokens(detail.output)} Token`
    );
    else lines.push('输入、缓存、输出明细暂不可用');
    return { state: 'ready', grade, hint: lines.join('\n') };
  }
  function diskLabel(bytes) {
    const names = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    const unit = bytes ? Math.min(5, Math.floor(Math.log(bytes) / Math.log(1000))) : 0;
    const value = bytes / 1000 ** unit;
    return `${Number(value.toFixed(unit === 0 ? 0 : value < 10 ? 2 : 1))} ${names[unit]}`;
  }
  function projectView(row) {
    if (!localProject(row)) return { text: '-', state: 'unavailable', hint: '此项目没有本机文件夹可供统计' };
    const source = records.projects;
    if (!source) return { text: '…', state: 'pending', hint: '正在统计文件夹大小' };
    if (!source.ok) return { text: '-', state: 'error', hint: '文件夹大小暂时无法读取' };
    const item = source.sizes?.[projectId(row)];
    if (!item || item.state === 'pending') return { text: '…', state: 'pending', hint: '正在统计文件夹大小' };
    if (item.state !== 'ready' || !Number.isSafeInteger(item.bytes) || item.bytes < 0)
      return { text: '-', state: 'unavailable', hint: item.message || '此项目没有可读取的目录' };
    const text = diskLabel(item.bytes);
    return { text, state: 'ready', hint: `文件夹大小：${text}（${item.bytes.toLocaleString('zh-CN')} 字节）\n按 Finder「大小」口径统计文件内容，非磁盘占用\n按十进制换算（1 MB = 1,000,000 字节）\n包含隐藏文件和构建缓存；多目录项目合计统计${item.stale ? '\n正在后台更新大小' : '\n统计结果最多缓存 5 分钟'}` };
  }
  function hideHint() {
    clearTimeout(hoverTimer); hoverTimer = 0; hoverTarget = null; tooltip.hidden = true;
  }
  function setAttribute(element, name, value) {
    if (element.getAttribute(name) !== value) element.setAttribute(name, value);
  }
  function content(element, text) { if (element.textContent !== text) element.textContent = text; }
  function newBadge(mark) {
    const element = document.createElement('span');
    element.setAttribute(mark, ''); element.setAttribute(owned, 'badge');
    return element;
  }
  function syncRows(selector, map, active, anchor, draw, mark) {
    const keep = new Set();
    if (active) for (const row of document.querySelectorAll(selector)) {
      const position = anchor(row);
      if (!position?.parentElement) continue;
      let element = map.get(row);
      if (element && (element.parentElement !== position.parentElement ||
          (mark === threadMark ? element.nextElementSibling !== position : position.nextElementSibling !== element))) {
        if (hoverTarget === element) hideHint();
        element.remove(); map.delete(row); element = null;
      }
      if (!element) {
        element = newBadge(mark);
        if (mark === threadMark) threadBadges.add(element);
        if (mark === threadMark) position.before(element); else position.after(element);
        map.set(row, element);
      }
      keep.add(row); draw(row, element);
    }
    for (const [row, element] of map) if (!keep.has(row)) {
      if (hoverTarget === element) hideHint();
      element.remove(); map.delete(row);
    }
  }
  function positionHint() {
    if (!hoverTarget?.isConnected) { hideHint(); return; }
    content(tooltip, hoverTarget.getAttribute('data-petspet-hint') || '');
    const dark = darkMode();
    tooltip.style.background = dark ? '#292929' : '#fafafa';
    tooltip.style.color = dark ? '#f0f0f0' : '#262626';
    tooltip.hidden = false;
    const rect = hoverTarget.getBoundingClientRect(), width = tooltip.offsetWidth, height = tooltip.offsetHeight;
    tooltip.style.left = `${Math.max(10, Math.min(rect.left, innerWidth - width - 10))}px`;
    tooltip.style.top = `${Math.max(10, rect.bottom + height + 16 <= innerHeight ? rect.bottom + 7 : rect.top - height - 7)}px`;
  }
  function paint() {
    repaint = 0;
    if (disposed || !document.body) return;
    if (!style.isConnected) document.head.append(style);
    if (!tooltip.isConnected) document.body.append(tooltip);
    paintQuota();
    const tones = darkMode() ? ['#383838', '#595959', '#868686', '#b6b6b6', '#eeeeee']
                             : ['#e7e7e7', '#cdcdcd', '#9e9e9e', '#696969', '#252525'];
    syncRows(threadSelector, threadElements, enabled.tokens,
      row => row.querySelector('[data-thread-title]'), (row, element) => {
        const view = tokenView(row);
        setAttribute(element, 'data-state', view.state);
        setAttribute(element, 'data-level', String(view.grade ?? ''));
        setAttribute(element, 'role', 'img');
        setAttribute(element, 'aria-describedby', tooltip.id);
        setAttribute(element, 'aria-label', view.hint.replaceAll('\n', '，'));
        setAttribute(element, 'data-petspet-hint', view.hint);
        const color = view.state === 'ready' ? tones[view.grade] : 'transparent';
        if (element.style.getPropertyValue('--petspet-shade') !== color) {
          element.style.setProperty('--petspet-shade', color);
          element.style.background = 'var(--petspet-shade)';
        }
      }, threadMark);
    syncRows(projectSelector, projectElements, enabled.projects, row => {
      if (!projectId(row)) return null;
      const labelled = document.getElementById(row.getAttribute('aria-labelledby') || '');
      return labelled && row.contains(labelled) ? labelled : row.querySelector('[data-marquee-text]')?.parentElement;
    }, (row, element) => {
      const view = projectView(row);
      content(element, view.text);
      setAttribute(element, 'data-state', view.state);
      setAttribute(element, 'title', view.hint);
      setAttribute(element, 'aria-label', view.hint);
    }, projectMark);
    if (!tooltip.hidden) positionHint();
  }
  function queuePaint() {
    if (!disposed && !repaint) repaint = window.setTimeout(paint, 60);
  }
  function pointer(event) {
    if (event.pointerType === 'touch' || event.buttons) { hideHint(); return; }
    const element = event.target instanceof Element ? event.target.closest(`[${threadMark}]`) : null;
    const valid = element?.isConnected && threadBadges.has(element) ? element : null;
    if (valid === hoverTarget) return;
    hideHint();
    if (valid) {
      hoverTarget = valid;
      hoverTimer = window.setTimeout(() => { if (hoverTarget === valid && !document.hidden) positionHint(); }, 160);
    }
  }
  function layout(event) {
    if (event.type === 'scroll' && event.target instanceof Element && hoverTarget && !event.target.contains(hoverTarget)) return;
    hideHint(); queuePaint();
  }
  function escape(event) { if (event.key === 'Escape') hideHint(); }
  function leave(event) { if (!event.relatedTarget) hideHint(); }
  const observer = new MutationObserver(changes => {
    if (changes.some(change => !(change.target instanceof Element) || !change.target.closest(`[${owned}]`))) queuePaint();
  });
  observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true,
    attributeFilter: ['data-app-action-sidebar-thread-id', 'data-app-action-sidebar-thread-host-id',
      'data-app-action-sidebar-thread-kind', 'data-app-action-sidebar-project-id', 'data-sidebar-project-kind',
      'aria-labelledby', 'class', 'data-theme', 'hidden', 'inert', 'aria-hidden', 'data-sidebar-collapsed', 'data-sidebar-navigation-root'] });
  const events = [
    [document, 'pointerover', pointer, true], [document, 'pointermove', pointer, true],
    [document, 'pointerout', leave, true], [document, 'pointerdown', hideHint, true],
    [document, 'keydown', escape, true], [document, 'visibilitychange', hideHint, false],
    [document, 'scroll', layout, true], [window, 'resize', layout, false], [window, 'blur', hideHint, false]
  ];
  for (const [target, name, listener, capture] of events) target.addEventListener(name, listener, capture);
  media.addEventListener('change', queuePaint);
  const clock = window.setInterval(() => {
    if (Date.now() - lastContact > 30000) api.destroy();
    else if (records.tokens && Date.now() - records.tokens.checkedAt > 30000 &&
             [...threadElements.values()].some(element => element.dataset.state === 'ready')) queuePaint();
  }, 1000);

  async function directories() {
    if (projectDirectoryCache && Date.now() - directoryReadAt < 30000) return projectDirectoryCache;
    let expiry;
    const bootstrap = await Promise.race([
      Promise.resolve().then(() => window.electronBridge?.getInitialSidebarBootstrap?.()).catch(() => null),
      new Promise(resolve => { expiry = setTimeout(() => resolve(null), 1200); })
    ]).finally(() => clearTimeout(expiry));
    const projects = bootstrap?.globalStateEntries?.find(entry => entry?.key === 'local-projects')?.value;
    const map = new Map();
    if (projects && typeof projects === 'object') for (const id of Object.keys(projects)) {
      const paths = projects[id]?.rootPaths;
      if (id.length <= 512 && Array.isArray(paths) && paths.length <= 8 &&
          paths.every(path => typeof path === 'string' && path.startsWith('/') && path.length <= 4096 && !path.includes('\0')))
        map.set(id, paths);
    }
    projectDirectoryCache = map; directoryReadAt = Date.now();
    return map;
  }
  const api = {
    version,
    configure(next) {
      enabled = { tokens: next?.tokens === true, projects: next?.projects === true };
      const proposed = next?.quota;
      quota = validQuotaPayload(proposed) ? proposed : null;
      lastContact = Date.now(); paint();
    },
    async requested() {
      const ids = enabled.tokens
        ? [...new Set([...document.querySelectorAll(threadSelector)].map(localThread).filter(Boolean))].slice(0, 2000) : [];
      let projects = [];
      if (enabled.projects) {
        const map = await directories();
        projects = [...document.querySelectorAll(projectSelector)].filter(localProject)
          .map(row => ({ id: projectId(row), roots: map.get(projectId(row)) || [] })).filter(project => project.id).slice(0, 200);
      }
      const visible = element => element.getClientRects().length && !element.closest('[hidden],[inert],[aria-hidden="true"]') &&
        getComputedStyle(element).visibility !== 'hidden' && getComputedStyle(element).display !== 'none';
      const navigation = [...document.querySelectorAll('[data-sidebar-navigation-root],[data-app-navigation-rail]')].some(visible);
      const editor = [...document.querySelectorAll('textarea,[contenteditable="true"]')].some(element => visible(element) &&
        !element.disabled && element.getAttribute('aria-disabled') !== 'true' && !element.readOnly);
      const loading = [...document.querySelectorAll('body[aria-busy="true"],main[aria-busy="true"],[role="main"][aria-busy="true"]')].some(visible);
      const clientReady = document.readyState === 'complete' && navigation && editor && !loading;
      return { ids, projects, clientReady, quotaMounted: quotaSlot.isConnected, threadRows: document.querySelectorAll(threadSelector).length,
        projectRows: document.querySelectorAll(projectSelector).length };
    },
    update(next) {
      lastContact = Date.now(); records = next && typeof next === 'object' ? next : {};
      paint(); return { ok: true };
    },
    destroy() {
      if (disposed) return { ok: true };
      disposed = true; observer.disconnect(); quotaLayout.disconnect(); quotaObserved.clear(); clearQuotaSpacing(); clearInterval(clock); clearTimeout(repaint); hideHint();
      media.removeEventListener('change', queuePaint);
      for (const [target, name, listener, capture] of events) target.removeEventListener(name, listener, capture);
      for (const element of [...threadElements.values(), ...projectElements.values(), style, tooltip, quotaSlot]) element.remove();
      threadElements.clear(); projectElements.clear();
      if (window[key] === api) delete window[key];
      return { ok: true };
    }
  };
  window[key] = api;
  api.configure(settings);
  return api.requested();
})

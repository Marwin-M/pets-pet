// Quota component above the account avatar. No chat contents are read.
(() => {
  const key = '__petsPetWindowsQuotaV1', version = 2;
  if (window[key]?.version === version) return true;
  window[key]?.destroy(); // Remove the previous horizontal widget and its list spacers.
  const owned = 'data-petspet-windows';
  let payload = null, disposed = false, queued = false, lastContact = Date.now();
  const media = matchMedia('(prefers-color-scheme: dark)');
  const slot = document.createElement('div'), image = document.createElement('img');
  slot.setAttribute(owned, 'quota'); slot.setAttribute('aria-hidden', 'true');
  slot.style.cssText = 'position:fixed;display:block;opacity:.78;pointer-events:none;user-select:none;z-index:21;background:none;';
  image.draggable = false; image.alt = ''; image.style.cssText = 'display:block;max-width:none;pointer-events:none;';
  slot.append(image);
  const observed = new Set();
  function observe(elements) {
    const next = new Set(elements);
    for (const e of observed) if (!next.has(e)) { resize.unobserve(e); observed.delete(e); }
    for (const e of next) if (!observed.has(e)) { resize.observe(e); observed.add(e); }
  }
  function clear() { slot.remove(); observe([]); }
  function valid(p) {
    return !!(p && ['light', 'dark'].every(k => typeof p[k] === 'string' && p[k].length <= 256000 && /^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(p[k])) &&
      Number.isFinite(p.width) && p.width >= 32 && p.width <= 128 && Number.isFinite(p.height) && p.height >= 64 && p.height <= 256 &&
      Math.abs(p.height / p.width - 2) < .01 && ['system','light','dark'].includes(p.appearance));
  }
  function visible(e) {
    return e.getClientRects().length && !e.closest('[hidden],[inert],[aria-hidden="true"]') && getComputedStyle(e).visibility !== 'hidden';
  }
  function paint() {
    queued = false;
    if (disposed || !payload || document.hidden) { clear(); return; }
    const rails = [...document.querySelectorAll('[data-app-navigation-rail]')].filter(visible);
    const rail = rails.length === 1 ? rails[0] : null;
    // The account initials may themselves have aria-hidden=true.
    const avatars = rail ? [...rail.querySelectorAll('.sidebar-item button .rounded-full')].filter(e =>
      e.getClientRects().length && !e.closest('[hidden],[inert]') && getComputedStyle(e).visibility !== 'hidden' &&
      e.getBoundingClientRect().width >= 16 && e.getBoundingClientRect().width <= 48) : [];
    const avatar = avatars.length === 1 ? avatars[0] : null;
    if (!rail || !avatar) { clear(); return; }
    const bounds = rail.getBoundingClientRect(), account = avatar.getBoundingClientRect();
    const width = Math.min(payload.width, bounds.width - 8), height = payload.height * width / payload.width;
    const left = account.left + account.width / 2 - width / 2, top = account.top - 10 - height;
    if (width < 24 || top < bounds.top + 8 || left < bounds.left || left + width > bounds.right) { clear(); return; }
    const accountButton = avatar.closest('button');
    const blocked = [...rail.querySelectorAll('button,a,[role="button"]')].some(e => {
      if (e === accountButton || e.contains(avatar) || !visible(e)) return false;
      const r = e.getBoundingClientRect();
      return r.left < left + width && r.right > left && r.top < top + height && r.bottom > top;
    });
    if (blocked) { clear(); return; }
    observe([rail, avatar]);
    const set = (e, k, v) => { if (e.style[k] !== v) e.style[k] = v; };
    set(slot,'left',left+'px'); set(slot,'top',top+'px');
    set(slot,'width',width+'px'); set(slot,'height',height+'px');
    set(image,'width',width+'px'); set(image,'height',height+'px');
    const doc = document.documentElement;
    const dark = doc.classList.contains('dark') || !doc.classList.contains('light') && media.matches;
    const source = payload.appearance === 'dark' || payload.appearance === 'system' && dark ? payload.dark : payload.light;
    if (image.getAttribute('src') !== source) image.src = source;
    if (!slot.isConnected) document.body.append(slot);
  }
  function queue() { if (!queued && !disposed) { queued = true; requestAnimationFrame(paint); } }
  const observer = new MutationObserver(queue);
  observer.observe(document.documentElement, {subtree:true,childList:true,attributes:true,attributeFilter:['hidden','inert','aria-hidden','class']});
  const resize = new ResizeObserver(queue); resize.observe(document.documentElement);
  window.addEventListener('resize',queue); document.addEventListener('visibilitychange',queue); media.addEventListener('change',queue);
  const clock = setInterval(() => { if (Date.now() - lastContact > 15000) api.destroy(); else queue(); },1000);
  const api = window[key] = {
    version,
    configure(p) { lastContact = Date.now(); payload = valid(p) ? p : null; paint(); return {mounted:slot.isConnected,layout:'verticalAboveAvatar'}; },
    destroy() { disposed = true; observer.disconnect(); clearInterval(clock); clear(); resize.disconnect(); window.removeEventListener('resize',queue); document.removeEventListener('visibilitychange',queue); media.removeEventListener('change',queue); if(window[key]===api)delete window[key]; return true; }
  };
  return true;
})()

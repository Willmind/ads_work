const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const easing = 'cubic-bezier(.22,.7,.24,1)';
const animations = new WeakMap();
export function entrance(element) {
  if (reduced.matches) return;
  element.animate([{ opacity: 0, transform: 'translateY(5px)' }, { opacity: 1, transform: 'translateY(0)' }], { duration: 180, easing });
}
export function resizeCard(element, previousHeight) {
  animations.get(element)?.cancel();
  if (reduced.matches) return;
  const animation = element.animate([{ height: `${previousHeight}px` }, { height: `${element.getBoundingClientRect().height}px` }], { duration: 220, easing });
  animations.set(element, animation);
}
export function dismiss(element) {
  animations.get(element)?.cancel();
  if (reduced.matches) { element.hidden = true; return; }
  const animation = element.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 140, easing });
  animations.set(element, animation);
  animation.onfinish = () => { element.hidden = true; animations.delete(element); };
}
export function showToast(element) {
  animations.get(element)?.cancel(); animations.delete(element);
  element.hidden = false;
  if (!reduced.matches) element.animate([{ opacity: 0, translate: '0 6px' }, { opacity: 1, translate: '0 0' }], { duration: 180, easing });
}
export function installDisclosures() {
  for (const details of document.querySelectorAll('details')) {
    const summary = details.querySelector(':scope > summary');
    const content = summary.nextElementSibling;
    let animation;
    let expanded = details.open;
    details.addEventListener('toggle', () => {
      if (!animation) { expanded = details.open; details.dataset.expanded = String(expanded); }
    });
    summary.addEventListener('click', event => {
      event.preventDefault();
      const start = details.getBoundingClientRect().height;
      animation?.cancel(); animation = undefined;
      expanded = !expanded;
      details.dataset.expanded = String(expanded);
      if (reduced.matches) { details.open = expanded; return; }
      details.open = true;
      const end = expanded ? details.getBoundingClientRect().height : summary.getBoundingClientRect().height + details.clientTop * 2;
      animation = details.animate([{ height: `${start}px`, overflow: 'hidden' }, { height: `${end}px`, overflow: 'hidden' }], { duration: 220, easing });
      content?.animate([{ opacity: expanded ? 0 : 1 }, { opacity: expanded ? 1 : 0 }], { duration: 180, easing });
      animation.onfinish = () => { details.open = expanded; animation = undefined; };
    });
  }
}
export function createTabs(tabs) {
  const indicator = document.createElement('span'); indicator.className = 'tab-indicator'; indicator.setAttribute('aria-hidden', 'true'); tabs.prepend(indicator);
  const update = () => {
    const active = tabs.querySelector('[aria-selected=true]');
    indicator.style.width = `${active.offsetWidth}px`;
    indicator.style.transform = `translateX(${active.offsetLeft}px)`;
  };
  new ResizeObserver(update).observe(tabs);
  update();
  return update;
}
export function createBackupPicker(select) {
  const trigger = document.querySelector('#backupPicker');
  const menu = document.querySelector('#backupMenu');
  let signature = '';
  let animation;
  let opened = false;
  let anchor;
  function close(restoreFocus = false) {
    if (!opened) return;
    opened = false; trigger.setAttribute('aria-expanded', 'false'); animation?.cancel();
    if (restoreFocus) trigger.focus({ preventScroll: true });
    if (reduced.matches) { menu.hidden = true; return; }
    animation = menu.animate([{ opacity: 1, transform: 'translateY(0)' }, { opacity: 0, transform: 'translateY(-4px)' }], { duration: 140, easing });
    animation.onfinish = () => { menu.hidden = true; animation = undefined; };
  }
  function refresh() {
    trigger.querySelector('span').textContent = select.selectedOptions[0]?.textContent || '选择备份';
    const next = JSON.stringify([...select.options].map(option => [option.value, option.textContent]));
    if (signature !== next) {
      close(); signature = next; menu.replaceChildren();
      for (const option of select.options) {
        const item = document.createElement('button'); item.type = 'button'; item.setAttribute('role', 'option'); item.dataset.value = option.value;
        item.textContent = option.textContent; item.tabIndex = -1; menu.append(item);
      }
    }
    for (const item of menu.children) item.setAttribute('aria-selected', String(item.dataset.value === select.value));
  }
  function open(edge) {
    if (trigger.disabled || !select.options.length) return;
    animation?.cancel(); opened = true; menu.hidden = false; trigger.setAttribute('aria-expanded', 'true');
    const rect = trigger.getBoundingClientRect(); anchor = rect;
    const available = Math.max(rect.top - 8, innerHeight - rect.bottom - 8);
    menu.style.width = `${Math.min(rect.width, innerWidth - 24)}px`;
    menu.style.maxHeight = `${Math.min(248, available)}px`;
    menu.style.left = `${Math.min(Math.max(12, rect.left), innerWidth - menu.offsetWidth - 12)}px`;
    const above = innerHeight - rect.bottom < Math.min(180, menu.scrollHeight) && rect.top > innerHeight - rect.bottom;
    menu.style.top = `${above ? rect.top - menu.offsetHeight - 5 : rect.bottom + 5}px`;
    if (!reduced.matches) animation = menu.animate([{ opacity: 0, transform: 'translateY(-4px) scale(.985)' }, { opacity: 1, transform: 'translateY(0) scale(1)' }], { duration: 180, easing });
    const items = [...menu.children];
    const target = edge === 'first' ? items[0] : edge === 'last' ? items.at(-1) : items.find(item => item.dataset.value === select.value);
    target?.focus({ preventScroll: true });
  }
  trigger.addEventListener('click', () => opened ? close(true) : open());
  trigger.addEventListener('keydown', event => {
    if (!['ArrowDown', 'ArrowUp'].includes(event.key)) return;
    event.preventDefault(); open(event.key === 'ArrowDown' ? 'first' : 'last');
  });
  menu.addEventListener('click', event => {
    const item = event.target.closest('[role=option]'); if (!item || trigger.disabled) return;
    select.value = item.dataset.value; refresh(); select.dispatchEvent(new Event('change')); close(true);
  });
  menu.addEventListener('keydown', event => {
    if (event.key === 'Escape') { event.preventDefault(); close(true); return; }
    if (event.key === 'Tab') { close(true); return; }
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault(); const items = [...menu.children]; const current = items.indexOf(document.activeElement);
    const index = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : (current + (event.key === 'ArrowDown' ? 1 : items.length - 1)) % items.length;
    items[index]?.focus({ preventScroll: true });
  });
  document.addEventListener('pointerdown', event => { if (!menu.contains(event.target) && !trigger.contains(event.target)) close(); });
  document.addEventListener('focusin', event => { if (!menu.contains(event.target) && !trigger.contains(event.target)) close(); });
  window.addEventListener('resize', () => close());
  window.addEventListener('scroll', event => {
    if (!opened || menu.contains(event.target)) return;
    const rect = trigger.getBoundingClientRect();
    if (Math.abs(rect.top - anchor.top) > 1 || Math.abs(rect.left - anchor.left) > 1) close();
  }, true);
  return { refresh, close };
}


const refreshJobs = new WeakMap();
export function refreshFeedback(button, operation, updateControls = () => {}) {
  if (refreshJobs.has(button)) return refreshJobs.get(button);
  button.dataset.refreshing = 'true'; button.setAttribute('aria-busy', 'true'); button.disabled = true;
  const duration = 480;
  const animation = reduced.matches ? undefined : button.querySelector('svg.icon')?.animate(
    [{ transform: 'rotate(0deg)' }, { transform: 'rotate(360deg)' }], { duration, iterations: Infinity, easing: 'linear' });
  const job = (async () => {
    try { return await operation(); }
    finally {
      if (animation && !reduced.matches && !document.hidden) {
        const turns = Math.max(1, Math.ceil(Number(animation.currentTime || 0) / duration));
        animation.effect.updateTiming({ iterations: turns });
        // Hidden native test hosts may stop advancing animation frames.
        let timeout;
        await Promise.race([animation.finished.then(() => true, () => false), new Promise(resolve => { timeout = setTimeout(resolve, duration + 100); })]);
        clearTimeout(timeout);
      }
      animation?.cancel();
      delete button.dataset.refreshing; button.removeAttribute('aria-busy');
      refreshJobs.delete(button); button.disabled = false; updateControls();
    }
  })();
  refreshJobs.set(button, job);
  return job;
}

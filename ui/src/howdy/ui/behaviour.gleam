//// The browser side of the interactive components: dialogs, popovers,
//// menus, tooltips, tabs and selects.
////
//// Those components are built on what the browser already does. A dialog
//// is a `<dialog>` opened with an invoker command, a popover or menu uses
//// the popover API and CSS anchor positioning, an accordion is a set of
//// `<details>`. The browser traps focus in a modal, closes on Escape and
//// outside clicks, and puts focus back afterwards.
////
//// This script adds what the browser does not:
////
//// - arrow keys, Home, End and typeahead in menus and selects, arrow keys
////   between tabs and between the days of a calendar;
//// - choosing a select, combobox or calendar option, and switching tab
////   panels;
//// - filtering a command menu as you type, and its keyboard shortcut;
//// - showing a tooltip on hover and focus, and closing a toast;
//// - collapsing the sidebar on wide screens and remembering it;
//// - fallbacks for browsers without invoker commands, `closedby` on
////   dialogs, or CSS anchor positioning.
////
//// It listens on the document and follows events into open shadow roots,
//// so the same script serves the page and every live view on it. The
//// components find each other by element id, and ids are looked up in the
//// tree that holds the element, so a trigger and what it opens must both be
//// in the page or both in the same live view.
////
//// `howdy/ui/page` includes the script in every page. If you render the
//// document yourself, add `script()` to its head.
////
//// The browser owns open and selected state. A live view that wants to know
//// listens for the native events: `close` on a dialog, `toggle` on a
//// popover or `<details>`, `change` on the hidden input of a select,
//// combobox or calendar, or `click` on a tab, menu item or command item.

import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// The script, as a module script for the document head.
pub fn script() -> Element(msg) {
  html.script([attribute.type_("module")], source)
}

// Kept free of double quotes and backslashes so it reads the same in Gleam
// as in the browser.
const source = "
if (!window.howdyBehaviour) {
window.howdyBehaviour = true;
const hasCommands = 'command' in HTMLButtonElement.prototype;
const hasClosedBy = 'closedBy' in HTMLDialogElement.prototype;
const hasAnchors = CSS.supports('anchor-name: --a');
const openers = new WeakMap();
const watched = new WeakSet();
const tooltips = new WeakMap();
// Popovers closing because another is taking over, so focus stays put.
const handingOver = new WeakSet();

const byId = (node, id) => (id ? node.getRootNode().getElementById(id) : null);
const inPath = (event, selector) =>
  event.composedPath().find((node) => node instanceof Element && node.matches(selector));
const enabled = (container, selector) =>
  [...container.querySelectorAll(selector)].filter((el) => !el.matches(':disabled, [aria-disabled=true]'));
const isOpen = (popover) => popover.matches(':popover-open');
const wide = matchMedia('(min-width: 768px)');
// The document and the shadow roots of the live views on it.
const roots = () => [
  document,
  ...[...document.querySelectorAll('lustre-server-component')].map((host) => host.shadowRoot).filter(Boolean),
];
const deepFocus = () => {
  let focused = document.activeElement;
  while (focused?.shadowRoot?.activeElement) focused = focused.shadowRoot.activeElement;
  return focused;
};

// Without anchor positioning, put a floating element beside its anchor.
const place = (floating, anchor) => {
  if (hasAnchors) return;
  floating.style.visibility = '';
  // Context menus are placed at the pointer when they open.
  if (!anchor || floating.hasAttribute('data-howdy-at-pointer')) return;
  const a = anchor.getBoundingClientRect();
  const f = floating.getBoundingClientRect();
  const gap = 6;
  const above = floating.dataset.howdySide === 'top';
  let top = above ? a.top - f.height - gap : a.bottom + gap;
  if (!above && top + f.height > innerHeight) top = Math.max(gap, a.top - f.height - gap);
  if (above && top < 0) top = a.bottom + gap;
  let left = above ? a.left + (a.width - f.width) / 2 : a.left;
  left = Math.max(gap, Math.min(left, innerWidth - f.width - gap));
  Object.assign(floating.style, { inset: 'auto', margin: '0', top: top + 'px', left: left + 'px' });
};

// Popovers are watched from the first time something opens them.
const watch = (popover) => {
  if (watched.has(popover)) return;
  watched.add(popover);
  let hadFocus = false;
  popover.addEventListener('beforetoggle', (event) => {
    if (event.newState === 'open' && !hasAnchors) popover.style.visibility = 'hidden';
    if (event.newState === 'closed') hadFocus = popover.contains(deepFocus());
  });
  popover.addEventListener('toggle', (event) => {
    const opener = openers.get(popover);
    if (opener?.closest('[role=menubar]')) opener.setAttribute('aria-expanded', String(event.newState === 'open'));
    // Browsers put focus back on the shadow host, not the trigger, when a
    // popover in a live view closes, so put it back ourselves.
    if (event.newState === 'closed') {
      const focused = deepFocus();
      if (handingOver.delete(popover)) return;
      if (hadFocus && (!focused || focused === document.body || focused === popover.getRootNode().host || popover.contains(focused))) openers.get(popover)?.focus();
      return;
    }
    place(popover, openers.get(popover));
    if (popover.matches('[role=menu], [role=listbox]')) {
      const items = enabled(popover, '[role^=menuitem], [role=option]');
      (items.find((el) => el.getAttribute('aria-selected') === 'true') || items[0])?.focus();
      return;
    }
    popover.querySelector(`[data-howdy-command] > input, [data-howdy-calendar] [data-date][tabindex='0']`)?.focus();
    const command = popover.querySelector('[data-howdy-command]');
    if (command) activate(command, commandItems(command).find((el) => el.matches('[aria-selected=true]')) || commandItems(command)[0]);
  });
};

const open = (popover, opener) => {
  openers.set(popover, opener);
  watch(popover);
  if (!isOpen(popover)) popover.showPopover({ source: opener });
};

const close = (popover) => {
  if (isOpen(popover)) popover.hidePopover();
  openers.get(popover)?.focus();
};

const selectTab = (tab) => {
  for (const other of tab.closest('[role=tablist]').querySelectorAll('[role=tab]')) {
    const selected = other === tab;
    other.setAttribute('aria-selected', String(selected));
    other.tabIndex = selected ? 0 : -1;
    const panel = byId(other, other.getAttribute('aria-controls'));
    if (panel) panel.hidden = !selected;
  }
};

// Change a text node in place: live views patch the node they rendered.
const setText = (node, text) => {
  if (node.firstChild?.nodeType === Node.TEXT_NODE) node.firstChild.data = text;
  else node.textContent = text;
};

const setValue = (input, value) => {
  if (!input || input.value === value) return;
  input.value = value;
  input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
  input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
};

// A select, combobox or date picker: show the choice, close, keep the value.
const settle = (root, value, label, from) => {
  setText(root.querySelector('[data-howdy-select-value]'), label);
  root.querySelector(':scope > button').removeAttribute('data-placeholder');
  close(from.closest('[popover]'));
  setValue(root.querySelector(':scope > input'), value);
};

const choose = (option) => {
  if (option.matches('[aria-disabled=true]')) return;
  const root = option.closest('[data-howdy-select]');
  for (const other of root.querySelectorAll('[role=option]')) {
    other.setAttribute('aria-selected', String(other === option));
  }
  settle(root, option.dataset.value, option.textContent.trim(), option);
};

const pickDay = (day) => {
  const calendar = day.closest('[data-howdy-calendar]');
  for (const other of calendar.querySelectorAll('[data-date]')) {
    other.setAttribute('aria-pressed', String(other === day));
    other.tabIndex = other === day ? 0 : -1;
  }
  const picker = day.closest('[data-howdy-select]');
  if (picker) settle(picker, day.dataset.date, day.dataset.label, day);
  else setValue(calendar.querySelector(':scope > input'), day.dataset.date);
};

const moveDay = (day, days) => {
  const calendar = day.closest('[data-howdy-calendar]');
  let next = day;
  do {
    const date = new Date(next.dataset.date + 'T00:00:00Z');
    date.setUTCDate(date.getUTCDate() + days);
    next = calendar.querySelector(`[data-date='${date.toISOString().slice(0, 10)}']`);
  } while (next?.disabled);
  return next;
};

const commandItems = (command) =>
  [...command.querySelectorAll('[role=option]')].filter((el) => !el.hidden && !el.matches('[aria-disabled=true]'));

// The option Enter would choose. Focus stays in the search box.
const activate = (command, item) => {
  const input = command.querySelector(':scope > input');
  for (const el of command.querySelectorAll('[data-active]')) el.removeAttribute('data-active');
  if (!item) return input.removeAttribute('aria-activedescendant');
  if (!item.id) item.id = input.id + '-option-' + [...command.querySelectorAll('[role=option]')].indexOf(item);
  item.setAttribute('data-active', '');
  input.setAttribute('aria-activedescendant', item.id);
  item.scrollIntoView({ block: 'nearest' });
};

const filter = (command) => {
  const input = command.querySelector(':scope > input');
  if (!input.hasAttribute('data-howdy-server-filtered')) {
    const words = input.value.toLowerCase().split(' ').filter(Boolean);
    for (const item of command.querySelectorAll('[role=option]')) {
      const text = ((item.dataset.keywords || '') + ' ' + item.textContent).toLowerCase();
      item.hidden = !words.every((word) => text.includes(word));
    }
    for (const group of command.querySelectorAll('[role=group]')) {
      group.hidden = !group.querySelector('[role=option]:not([hidden])');
    }
    const empty = command.querySelector('[data-howdy-command-empty]');
    if (empty) empty.hidden = !!command.querySelector('[role=option]:not([hidden])');
  }
  activate(command, commandItems(command)[0]);
};

const step = (items, current, key) => {
  const i = items.indexOf(current);
  if (key === 'Home') return items[0];
  if (key === 'End') return items[items.length - 1];
  if (key === 'ArrowDown' || key === 'ArrowRight') return items[(i + 1) % items.length];
  return items[(i - 1 + items.length) % items.length];
};

let typed = '';
let typedAt = 0;
const typeahead = (items, current, key) => {
  const now = Date.now();
  typed = (now - typedAt > 600 ? '' : typed) + key.toLowerCase();
  typedAt = now;
  const i = items.indexOf(current) + (typed.length > 1 ? 0 : 1);
  const ordered = [...items.slice(i), ...items.slice(0, i)];
  return ordered.find((el) => el.textContent.trim().toLowerCase().startsWith(typed));
};

// Tooltips and hover cards: shown after a pause on hover or focus, kept
// while the pointer or focus is on them.
const tooltip = (trigger) => {
  if (tooltips.has(trigger)) return tooltips.get(trigger);
  const card = trigger.hasAttribute('data-howdy-hover-card');
  const tip = byId(trigger, card ? trigger.dataset.howdyHoverCard : trigger.dataset.howdyTooltip);
  if (!tip) return null;
  const [openAfter, closeAfter] = card ? [500, 300] : [300, 100];
  let timer;
  const show = () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (isOpen(tip)) return;
      if (!hasAnchors) tip.style.visibility = 'hidden';
      tip.showPopover();
      place(tip, trigger);
    }, openAfter);
  };
  const hide = () => {
    clearTimeout(timer);
    timer = setTimeout(() => isOpen(tip) && tip.hidePopover(), closeAfter);
  };
  trigger.addEventListener('pointerenter', show);
  trigger.addEventListener('pointerleave', hide);
  trigger.addEventListener('focus', show);
  trigger.addEventListener('blur', hide);
  trigger.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && isOpen(tip)) tip.hidePopover();
  });
  tip.addEventListener('pointerenter', () => clearTimeout(timer));
  tip.addEventListener('pointerleave', hide);
  tip.addEventListener('focusin', () => clearTimeout(timer));
  tip.addEventListener('focusout', hide);
  tip.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && isOpen(tip)) {
      tip.hidePopover();
      trigger.focus();
    }
  });
  tooltips.set(trigger, show);
  return show;
};

// The first hover or focus wires a tooltip up, then shows it.
const startTooltip = (event) => {
  const trigger = inPath(event, '[data-howdy-tooltip], [data-howdy-hover-card]');
  if (trigger && !tooltips.has(trigger)) tooltip(trigger)?.();
};
document.addEventListener('pointerover', startTooltip);
document.addEventListener('focusin', startTooltip);

document.addEventListener('pointerover', (event) => {
  const item = inPath(event, '[data-howdy-command] [role=option]');
  if (item && !item.matches('[aria-disabled=true]')) activate(item.closest('[data-howdy-command]'), item);
});

document.addEventListener('focusin', (event) => {
  const input = event.composedPath()[0];
  if (!(input instanceof HTMLInputElement) || !input.parentElement?.matches('[data-howdy-command]')) return;
  const command = input.parentElement;
  if (!command.querySelector('[data-active]:not([hidden])')) activate(command, commandItems(command)[0]);
});

document.addEventListener('input', (event) => {
  const input = event.composedPath()[0];
  if (input instanceof HTMLInputElement && input.parentElement?.matches('[data-howdy-command]')) filter(input.parentElement);
});

// A letter with Cmd or Ctrl opens the command dialog that claims it.
document.addEventListener('keydown', (event) => {
  if (!(event.metaKey || event.ctrlKey) || event.altKey || event.key.length !== 1) return;
  const selector = `dialog[data-howdy-shortcut='${CSS.escape(event.key.toLowerCase())}']`;
  for (const root of roots()) {
    const dialog = root.querySelector(selector);
    if (!dialog) continue;
    event.preventDefault();
    if (dialog.open) dialog.close();
    else dialog.showModal();
    return;
  }
});

// A sidebar opened over a narrow screen closes when the screen widens.
wide.addEventListener('change', () => {
  if (!wide.matches) return;
  for (const root of roots()) {
    for (const sidebar of root.querySelectorAll('[data-howdy-sidebar-layout] > aside:popover-open')) sidebar.hidePopover();
  }
});

// Move a resizable handle by `delta`, in the same shares as the panels'
// sizes. No panel goes below a tenth of the group.
const shares = (group) =>
  [...group.children]
    .filter((el) => el.getAttribute('role') !== 'separator')
    .reduce((sum, el) => sum + (parseFloat(el.style.flexGrow) || 1), 0);
const resizeBy = (handle, delta) => {
  const before = handle.previousElementSibling;
  const after = handle.nextElementSibling;
  if (!before || !after) return;
  const a = parseFloat(before.style.flexGrow) || 1;
  const b = parseFloat(after.style.flexGrow) || 1;
  const all = shares(handle.parentElement);
  const min = all / 10;
  const next = Math.min(Math.max(a + delta, min), a + b - min);
  before.style.flexGrow = String(next);
  after.style.flexGrow = String(a + b - next);
  handle.setAttribute('aria-valuenow', String(Math.round((next / all) * 100)));
};

document.addEventListener('pointerdown', (event) => {
  const handle = inPath(event, '[data-howdy-resizable] > [role=separator]');
  if (!handle || event.button !== 0) return;
  event.preventDefault();
  handle.focus();
  const group = handle.parentElement;
  const vertical = group.dataset.howdyResizable === 'vertical';
  const size = vertical ? group.clientHeight : group.clientWidth;
  const all = shares(group);
  let last = vertical ? event.clientY : event.clientX;
  // Keep receiving moves when the pointer leaves the thin handle.
  try {
    handle.setPointerCapture(event.pointerId);
  } catch {}
  const move = (moved) => {
    const now = vertical ? moved.clientY : moved.clientX;
    resizeBy(handle, ((now - last) / size) * all);
    last = now;
  };
  const stop = () => {
    handle.removeEventListener('pointermove', move);
    handle.removeEventListener('pointerup', stop);
    handle.removeEventListener('pointercancel', stop);
  };
  handle.addEventListener('pointermove', move);
  handle.addEventListener('pointerup', stop);
  handle.addEventListener('pointercancel', stop);
});

// A right click, or the context menu key, in an area opens its menu there.
document.addEventListener('contextmenu', (event) => {
  const area = inPath(event, '[data-howdy-context-menu]');
  if (!area) return;
  const popup = byId(area, area.dataset.howdyContextMenu);
  if (!popup) return;
  event.preventDefault();
  const focused = deepFocus();
  openers.set(popup, focused && area.contains(focused) ? focused : null);
  watch(popup);
  if (isOpen(popup)) popup.hidePopover();
  let x = event.clientX;
  let y = event.clientY;
  if (!x && !y) {
    const r = (focused && area.contains(focused) ? focused : area).getBoundingClientRect();
    x = r.left;
    y = r.bottom;
  }
  Object.assign(popup.style, { inset: 'auto', margin: '0', left: x + 'px', top: y + 'px' });
  popup.showPopover();
  const r = popup.getBoundingClientRect();
  if (r.right > innerWidth) popup.style.left = Math.max(4, innerWidth - r.width - 4) + 'px';
  if (r.bottom > innerHeight) popup.style.top = Math.max(4, y - r.height) + 'px';
});

// Once a menubar menu is open, pointing at another button opens its menu.
document.addEventListener('pointerover', (event) => {
  const button = inPath(event, '[role=menubar] > [data-howdy-menu-trigger]');
  if (!button) return;
  const buttons = [...button.parentElement.querySelectorAll(':scope > [data-howdy-menu-trigger]')];
  const openOne = buttons.find((other) => other !== button && isOpen(byId(other, other.getAttribute('popovertarget'))));
  if (!openOne) return;
  const popover = byId(button, button.getAttribute('popovertarget'));
  if (!popover) return;
  handingOver.add(byId(openOne, openOne.getAttribute('popovertarget')));
  for (const other of buttons) other.tabIndex = other === button ? 0 : -1;
  open(popover, button);
});

// A menubar is one stop in the tab order: the button last focused.
document.addEventListener('focusin', (event) => {
  const button = event.composedPath()[0];
  if (!(button instanceof Element) || !button.matches('[role=menubar] > [data-howdy-menu-trigger]')) return;
  for (const other of button.parentElement.querySelectorAll(':scope > [data-howdy-menu-trigger]')) {
    other.tabIndex = other === button ? 0 : -1;
  }
});

// A resizable handle announces the size of the panel before it.
document.addEventListener('focusin', (event) => {
  const handle = event.composedPath()[0];
  if (handle instanceof Element && handle.matches('[data-howdy-resizable] > [role=separator]')) resizeBy(handle, 0);
});

// Capture, so popovers are watched before the browser opens them.
document.addEventListener('click', (event) => {
  const invoker = inPath(event, '[popovertarget], [commandfor]');
  if (!invoker) return;
  const target = byId(invoker, invoker.getAttribute('popovertarget') || invoker.getAttribute('commandfor'));
  if (!target) return;
  if (target.hasAttribute('popover')) {
    openers.set(target, invoker);
    watch(target);
  }
  if (!hasCommands && invoker.hasAttribute('commandfor')) {
    const command = invoker.getAttribute('command');
    if (command === 'show-modal' && !target.open) target.showModal();
    if (command === 'close' && target.open) target.close();
  }
}, true);

document.addEventListener('click', (event) => {
  const first = event.composedPath()[0];
  if (!hasClosedBy && first instanceof HTMLDialogElement && first.open && first.getAttribute('closedby') === 'any') {
    const r = first.getBoundingClientRect();
    const outside = event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom;
    if (outside) first.close();
  }
  const tab = inPath(event, '[data-howdy-tabs] [role=tab]');
  if (tab) selectTab(tab);
  const option = inPath(event, '[data-howdy-select] [role=option]');
  if (option) choose(option);
  const item = inPath(event, '[role=menu] [role^=menuitem]');
  if (item && !item.matches('[aria-disabled=true]')) close(item.closest('[popover]'));
  const day = inPath(event, '[data-howdy-calendar] [data-date]');
  if (day) pickDay(day);
  const command = inPath(event, 'dialog [data-howdy-command] [role=option]');
  if (command && !command.matches('[aria-disabled=true]')) command.closest('dialog').close();
  const toggle = inPath(event, '[data-howdy-toggle]');
  if (toggle && !toggle.disabled) {
    const pressed = toggle.getAttribute('aria-pressed') !== 'true';
    const group = toggle.closest('[data-howdy-toggle-group=single]');
    if (group && pressed) {
      for (const other of group.querySelectorAll('[data-howdy-toggle]')) other.setAttribute('aria-pressed', 'false');
    }
    toggle.setAttribute('aria-pressed', String(pressed));
  }
  const slideButton = inPath(event, '[data-howdy-carousel-previous], [data-howdy-carousel-next]');
  if (slideButton) {
    const viewport = byId(slideButton, slideButton.getAttribute('aria-controls'));
    const forward = slideButton.hasAttribute('data-howdy-carousel-next');
    const rtl = viewport && getComputedStyle(viewport).direction === 'rtl';
    const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
    viewport?.scrollBy({ left: (forward !== rtl ? 1 : -1) * viewport.clientWidth, behavior: still ? 'instant' : 'smooth' });
  }
  const toast = inPath(event, '[data-howdy-toast-close]');
  if (toast) toast.closest('[data-howdy-toast]').hidden = true;
  // On a wide screen the sidebar trigger collapses the sidebar instead of
  // opening it over the page, and the choice is kept for the next page.
  const sidebarTrigger = inPath(event, '[data-howdy-sidebar-trigger]');
  if (sidebarTrigger && wide.matches) {
    event.preventDefault();
    const layout = byId(sidebarTrigger, sidebarTrigger.getAttribute('popovertarget'))?.closest('[data-howdy-sidebar-layout]');
    if (layout) {
      layout.dataset.state = layout.dataset.state === 'collapsed' ? 'expanded' : 'collapsed';
      document.cookie = 'sidebar=' + layout.dataset.state + ';path=/;max-age=31536000;samesite=lax';
    }
  }
});

document.addEventListener('keydown', (event) => {
  const { key } = event;
  const target = event.composedPath()[0];
  if (!(target instanceof Element)) return;
  const arrows = ['ArrowDown', 'ArrowUp', 'Home', 'End'];

  const popup = target.closest('[role=menu][popover], [role=listbox][popover]');
  if (popup) {
    const items = enabled(popup, '[role^=menuitem], [role=option]');
    // In a menubar, left and right go to the neighbouring menu.
    const opener = openers.get(popup);
    const bar = opener?.closest('[role=menubar]');
    if (bar && (key === 'ArrowLeft' || key === 'ArrowRight')) {
      event.preventDefault();
      const buttons = enabled(bar, ':scope > [data-howdy-menu-trigger]');
      const next = step(buttons, opener, key);
      const menu = byId(next, next.getAttribute('popovertarget'));
      handingOver.add(popup);
      popup.hidePopover();
      for (const button of buttons) button.tabIndex = button === next ? 0 : -1;
      if (menu) open(menu, next);
      return;
    }
    if (arrows.includes(key)) {
      event.preventDefault();
      step(items, target, key)?.focus();
    } else if (key === 'Tab') {
      popup.hidePopover();
    } else if ((key === 'Enter' || key === ' ') && target.matches('[role=option]')) {
      event.preventDefault();
      choose(target);
    } else if (key.length === 1 && key !== ' ' && !event.ctrlKey && !event.metaKey && !event.altKey) {
      typeahead(items, target, key)?.focus();
    }
    return;
  }

  const command = target.matches('[data-howdy-command] > input') ? target.parentElement : null;
  if (command) {
    const items = commandItems(command);
    const current = command.querySelector('[data-active]');
    if (key === 'ArrowDown' || key === 'ArrowUp') {
      event.preventDefault();
      activate(command, current && items.includes(current) ? step(items, current, key) : items[0]);
    } else if (key === 'Enter' && current) {
      event.preventDefault();
      current.click();
    }
    return;
  }

  const handle = target.closest('[data-howdy-resizable] > [role=separator]');
  if (handle) {
    const all = shares(handle.parentElement);
    const before = parseFloat(handle.previousElementSibling?.style.flexGrow) || 1;
    const after = parseFloat(handle.nextElementSibling?.style.flexGrow) || 1;
    const moves = {
      ArrowLeft: -all / 20,
      ArrowUp: -all / 20,
      ArrowRight: all / 20,
      ArrowDown: all / 20,
      Home: all / 10 - before,
      End: before + after - all / 10 - before,
    };
    if (Object.hasOwn(moves, key)) {
      event.preventDefault();
      resizeBy(handle, moves[key]);
    }
    return;
  }

  const barButton = target.closest('[role=menubar] > [data-howdy-menu-trigger]');
  if (barButton && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(key)) {
    event.preventDefault();
    const next = step(enabled(barButton.parentElement, ':scope > [data-howdy-menu-trigger]'), barButton, key);
    next.focus();
    return;
  }

  const day = target.closest('[data-howdy-calendar] [data-date]');
  if (day) {
    const moves = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 };
    let next = null;
    if (Object.hasOwn(moves, key)) {
      next = moveDay(day, moves[key]);
    } else if (key === 'Home' || key === 'End') {
      const week = enabled(day.closest('tr'), '[data-date]');
      next = key === 'Home' ? week[0] : week[week.length - 1];
    } else if (key === 'PageUp' || key === 'PageDown') {
      event.preventDefault();
      const which = key === 'PageUp' ? 'previous' : 'next';
      day.closest('[data-howdy-calendar]').querySelector(`[data-howdy-calendar-${which}]`)?.click();
      return;
    }
    if (next) {
      event.preventDefault();
      for (const other of day.closest('[data-howdy-calendar]').querySelectorAll('[data-date]')) {
        other.tabIndex = other === next ? 0 : -1;
      }
      next.focus();
    }
    return;
  }

  const trigger = target.closest('[data-howdy-menu-trigger], [data-howdy-select] > button');
  if (trigger && (key === 'ArrowDown' || key === 'ArrowUp')) {
    const popover = byId(trigger, trigger.getAttribute('popovertarget'));
    if (popover) {
      event.preventDefault();
      open(popover, trigger);
    }
    return;
  }

  const tab = target.closest('[data-howdy-tabs] [role=tab]');
  if (tab && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(key)) {
    event.preventDefault();
    const next = step(enabled(tab.closest('[role=tablist]'), '[role=tab]'), tab, key);
    next.focus();
    selectTab(next);
  }
});
}
"

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
//// - arrow keys, Home, End and typeahead in menus and selects, and arrow
////   keys between tabs;
//// - choosing a select option, and switching tab panels;
//// - showing a tooltip on hover and focus;
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
//// popover or `<details>`, `change` on a select's hidden input, or `click`
//// on a tab or menu item.

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

const byId = (node, id) => (id ? node.getRootNode().getElementById(id) : null);
const inPath = (event, selector) =>
  event.composedPath().find((node) => node instanceof Element && node.matches(selector));
const enabled = (container, selector) =>
  [...container.querySelectorAll(selector)].filter((el) => !el.matches(':disabled, [aria-disabled=true]'));
const isOpen = (popover) => popover.matches(':popover-open');
const deepFocus = () => {
  let focused = document.activeElement;
  while (focused?.shadowRoot?.activeElement) focused = focused.shadowRoot.activeElement;
  return focused;
};

// Without anchor positioning, put a floating element beside its anchor.
const place = (floating, anchor) => {
  if (hasAnchors) return;
  floating.style.visibility = '';
  if (!anchor) return;
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
    // Browsers put focus back on the shadow host, not the trigger, when a
    // popover in a live view closes, so put it back ourselves.
    if (event.newState === 'closed') {
      const focused = deepFocus();
      if (hadFocus && (!focused || focused === document.body || focused === popover.getRootNode().host || popover.contains(focused))) openers.get(popover)?.focus();
      return;
    }
    place(popover, openers.get(popover));
    if (popover.matches('[role=menu], [role=listbox]')) {
      const items = enabled(popover, '[role^=menuitem], [role=option]');
      (items.find((el) => el.getAttribute('aria-selected') === 'true') || items[0])?.focus();
    }
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

const choose = (option) => {
  if (option.matches('[aria-disabled=true]')) return;
  const root = option.closest('[data-howdy-select]');
  const input = root.querySelector('input');
  const value = root.querySelector('[data-howdy-select-value]');
  for (const other of root.querySelectorAll('[role=option]')) {
    other.setAttribute('aria-selected', String(other === option));
  }
  // Change the text node in place: live views patch the node they rendered.
  const label = option.textContent.trim();
  if (value.firstChild?.nodeType === Node.TEXT_NODE) value.firstChild.data = label;
  else value.textContent = label;
  root.querySelector('button').removeAttribute('data-placeholder');
  close(option.closest('[popover]'));
  if (input.value !== option.dataset.value) {
    input.value = option.dataset.value;
    input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
  }
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

const tooltip = (trigger) => {
  if (tooltips.has(trigger)) return tooltips.get(trigger);
  const tip = byId(trigger, trigger.dataset.howdyTooltip);
  if (!tip) return null;
  let timer;
  const show = () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (isOpen(tip)) return;
      if (!hasAnchors) tip.style.visibility = 'hidden';
      tip.showPopover();
      place(tip, trigger);
    }, 300);
  };
  const hide = () => {
    clearTimeout(timer);
    timer = setTimeout(() => isOpen(tip) && tip.hidePopover(), 100);
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
  tooltips.set(trigger, show);
  return show;
};

// The first hover or focus wires a tooltip up, then shows it.
const startTooltip = (event) => {
  const trigger = inPath(event, '[data-howdy-tooltip]');
  if (trigger && !tooltips.has(trigger)) tooltip(trigger)?.();
};
document.addEventListener('pointerover', startTooltip);
document.addEventListener('focusin', startTooltip);

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
});

document.addEventListener('keydown', (event) => {
  const { key } = event;
  const target = event.composedPath()[0];
  if (!(target instanceof Element)) return;
  const arrows = ['ArrowDown', 'ArrowUp', 'Home', 'End'];

  const popup = target.closest('[role=menu][popover], [role=listbox][popover]');
  if (popup) {
    const items = enabled(popup, '[role^=menuitem], [role=option]');
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

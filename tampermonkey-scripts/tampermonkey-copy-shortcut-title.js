// ==UserScript==
// @name         Shortcut — Copy 'Work on "<story>" [id]'
// @namespace    https://datacenters.com/
// @version      1.3.0
// @description  Adds a compact copy-to-clipboard icon next to the Shortcut story breadcrumbs that yields: Work on "{story_name}" [{story_id}]
// @author       Guillermo Siliceo
// @match        https://app.shortcut.com/datacenterscom/*
// @grant        GM_setClipboard
// @run-at       document-idle
// ==/UserScript==

(function () {
  'use strict';

  // Only ever one instance per document, even if the script is injected twice.
  if (window.__dcCopyWorkOnInstalled) return;
  window.__dcCopyWorkOnInstalled = true;

  // The story modal lives in #story-dialog-parent. #cid-breadcrumbs-story-dialog is
  // the React *mount host* (it carries no __reactFiber$ key); the <nav> inside it is
  // React-owned and gets reconciled. So the button is appended to the host, as a
  // sibling of <nav> — outside anything React reconciles. Appending inside <nav>
  // caused duplicates: a re-render detached our node while the observer added a new one.
  const BREADCRUMBS_ID = 'cid-breadcrumbs-story-dialog';
  const BUTTON_CLASS = 'dc-copy-work-on-btn';
  const STORY_URL_RE = /^\/datacenterscom\/story\/(\d+)/;

  const TITLE_IDLE = 'Copy Work on "{story name}" [{id}] to the clipboard';

  // clipboard-svgrepo-com.svg, base64-encoded. The stroke colour is baked in as
  // #68788e (the breadcrumb grey) because currentColor does not inherit into an
  // <img> data URI — it would resolve to black against the SVG's own document.
  const ICON = 'data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjQiIGhlaWdodD0iMjQiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48cGF0aCBkPSJNMTYgNC4wMDE5NUMxOC4xNzUgNC4wMTQwNiAxOS4zNTI5IDQuMTEwNTEgMjAuMTIxMyA0Ljg3ODg5QzIxIDUuNzU3NTcgMjEgNy4xNzE3OSAyMSAxMC4wMDAyVjE2LjAwMDJDMjEgMTguODI4NiAyMSAyMC4yNDI5IDIwLjEyMTMgMjEuMTIxNUMxOS4yNDI2IDIyLjAwMDIgMTcuODI4NCAyMi4wMDAyIDE1IDIyLjAwMDJIOUM2LjE3MTU3IDIyLjAwMDIgNC43NTczNiAyMi4wMDAyIDMuODc4NjggMjEuMTIxNUMzIDIwLjI0MjkgMyAxOC44Mjg2IDMgMTYuMDAwMlYxMC4wMDAyQzMgNy4xNzE3OSAzIDUuNzU3NTcgMy44Nzg2OCA0Ljg3ODg5QzQuNjQ3MDYgNC4xMTA1MSA1LjgyNDk3IDQuMDE0MDYgOCA0LjAwMTk1IiBzdHJva2U9IiM2ODc4OGUiIHN0cm9rZS13aWR0aD0iMS41Ii8+PHBhdGggZD0iTTggMTRIMTYiIHN0cm9rZT0iIzY4Nzg4ZSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik03IDEwLjVIMTciIHN0cm9rZT0iIzY4Nzg4ZSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik05IDE3LjVIMTUiIHN0cm9rZT0iIzY4Nzg4ZSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik04IDMuNUM4IDIuNjcxNTcgOC42NzE1NyAyIDkuNSAySDE0LjVDMTUuMzI4NCAyIDE2IDIuNjcxNTcgMTYgMy41VjQuNUMxNiA1LjMyODQzIDE1LjMyODQgNiAxNC41IDZIOS41QzguNjcxNTcgNiA4IDUuMzI4NDMgOCA0LjVWMy41WiIgc3Ryb2tlPSIjNjg3ODhlIiBzdHJva2Utd2lkdGg9IjEuNSIvPjwvc3ZnPg==';

  let button = null;
  let icon = null;
  let resetTimer = null;

  function isStoryOpen() {
    return STORY_URL_RE.test(location.pathname);
  }

  function getStoryId() {
    const fromUrl = location.pathname.match(STORY_URL_RE);
    if (fromUrl) return fromUrl[1];
    // Fallback: the dialog carries a `story-<id>` class.
    const dialog = document.querySelector('.story-dialog');
    const fromClass = dialog && dialog.className.match(/\bstory-(\d+)\b/);
    return fromClass ? fromClass[1] : null;
  }

  function getStoryName() {
    const el = document.querySelector('.story-dialog h2.story-name');
    return el ? el.textContent.trim() : null;
  }

  function buildString() {
    const id = getStoryId();
    const name = getStoryName();
    if (!id || !name) return null;
    return `Work on "${name}" [${id}]`;
  }

  function copy(text) {
    if (typeof GM_setClipboard === 'function') {
      GM_setClipboard(text, 'text');
      return Promise.resolve();
    }
    return navigator.clipboard.writeText(text);
  }

  // Icon-only, so feedback is conveyed by tinting the glyph and updating the
  // tooltip rather than swapping a text label.
  function flash(title, color) {
    button.title = title;
    icon.style.filter = color;
    clearTimeout(resetTimer);
    resetTimer = setTimeout(() => {
      button.title = TITLE_IDLE;
      icon.style.filter = 'none';
    }, 1200);
  }

  function makeButton() {
    const btn = document.createElement('button');
    btn.className = BUTTON_CLASS;
    btn.type = 'button';
    btn.title = TITLE_IDLE;
    btn.setAttribute('aria-label', 'Copy Work on "story" [id] to the clipboard');
    Object.assign(btn.style, {
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      flex: '0 0 auto',
      width: '22px',
      height: '22px',
      marginLeft: '6px',
      padding: '0',
      background: 'transparent',
      border: 'none',
      borderRadius: '4px',
      cursor: 'pointer',
      opacity: '0.75',
    });
    btn.addEventListener('mouseenter', () => {
      btn.style.opacity = '1';
      btn.style.background = 'rgba(104, 120, 142, 0.12)';
    });
    btn.addEventListener('mouseleave', () => {
      btn.style.opacity = '0.75';
      btn.style.background = 'transparent';
    });

    icon = document.createElement('img');
    icon.src = ICON;
    icon.alt = '';
    icon.setAttribute('aria-hidden', 'true');
    Object.assign(icon.style, {
      width: '15px',
      height: '15px',
      display: 'block',
      pointerEvents: 'none',
    });
    btn.appendChild(icon);

    btn.addEventListener('click', function (event) {
      event.preventDefault();
      event.stopPropagation();

      const text = buildString();
      if (!text) {
        flash('No story found', 'grayscale(1) opacity(0.5)');
        return;
      }

      Promise.resolve(copy(text))
        // Green tint on success, red on failure.
        .then(() => flash('Copied!', 'hue-rotate(60deg) saturate(6) brightness(0.9)'))
        .catch(() => flash('Copy failed', 'hue-rotate(-70deg) saturate(6)'));
    });

    return btn;
  }

  function inject() {
    const host = isStoryOpen() ? document.getElementById(BREADCRUMBS_ID) : null;

    if (!host) {
      // Story closed or breadcrumbs gone: drop any stray copies.
      for (const stray of document.querySelectorAll('.' + BUTTON_CLASS)) stray.remove();
      return;
    }

    if (!button) button = makeButton();

    // Hard singleton: remove every node that isn't the one instance we track.
    for (const stray of document.querySelectorAll('.' + BUTTON_CLASS)) {
      if (stray !== button) stray.remove();
    }

    // The host is a plain block whose <nav> nearly fills it, so an appended
    // inline button wraps to a second line. Flex the host to keep one row.
    // Safe to restyle: the host is React's mount point, not a rendered node.
    host.style.display = 'flex';
    host.style.alignItems = 'center';
    host.style.flexWrap = 'nowrap';

    if (button.parentElement !== host) host.appendChild(button);
  }

  // React re-renders can drop the node; re-check on any DOM change.
  let scheduled = false;
  const observer = new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      inject();
    });
  });
  observer.observe(document.body, { childList: true, subtree: true });

  // SPA navigation: Shortcut swaps stories without a full page load.
  for (const method of ['pushState', 'replaceState']) {
    const original = history[method];
    history[method] = function () {
      const result = original.apply(this, arguments);
      inject();
      return result;
    };
  }
  window.addEventListener('popstate', inject);

  inject();
})();

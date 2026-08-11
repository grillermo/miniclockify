// ==UserScript==
// @name         GitHub — Copy 'REVIEW - "<title>" - #<number>'
// @namespace    https://datacenters.com/
// @version      1.0.0
// @description  Adds a compact copy-to-clipboard icon next to the Edit button in a GitHub pull request header that yields: REVIEW - "{pr_title}" - #{pr_number}
// @author       Guillermo Siliceo
// @match        https://github.com/*/pull/*
// @grant        GM_setClipboard
// @run-at       document-idle
// ==/UserScript==

(function () {
  'use strict';

  // Only ever one instance per document, even if the script is injected twice.
  if (window.__dcCopyReviewInstalled) return;
  window.__dcCopyReviewInstalled = true;

  // GitHub's PR header is Primer React (PageHeader). Its class names are hashed
  // per build — `prc-PageHeader-TitleArea-2n2J0` will not survive the next deploy —
  // so every hook here is a `data-component` attribute or a semantic GitHub class,
  // both of which are stable across builds.
  const TITLE_SELECTOR = 'h1[data-component="PH_Title"]';
  const BUTTON_CLASS = 'dc-copy-review-btn';
  const PULL_URL_RE = /^\/[^/]+\/[^/]+\/pull\/(\d+)/;

  const TITLE_IDLE = 'Copy REVIEW - "{pr title}" - #{number} to the clipboard';

  // clipboard-svgrepo-com.svg, matching the Shortcut copy button. Inlined as SVG
  // rather than an <img> data URI (as in the Shortcut script) for two reasons:
  // GitHub's CSP is strict about image sources, and inline SVG lets the strokes
  // inherit currentColor so the glyph follows GitHub's own muted grey and both
  // themes, instead of a baked-in hex.
  const ICON = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" aria-hidden="true" focusable="false" style="display:block;pointer-events:none">'
    + '<path d="M16 4.00195C18.175 4.01406 19.3529 4.11051 20.1213 4.87889C21 5.75757 21 7.17179 21 10.0002V16.0002C21 18.8286 21 20.2429 20.1213 21.1215C19.2426 22.0002 17.8284 22.0002 15 22.0002H9C6.17157 22.0002 4.75736 22.0002 3.87868 21.1215C3 20.2429 3 18.8286 3 16.0002V10.0002C3 7.17179 3 5.75757 3.87868 4.87889C4.64706 4.11051 5.82497 4.01406 8 4.00195" stroke="currentColor" stroke-width="1.5"/>'
    + '<path d="M8 14H16" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>'
    + '<path d="M7 10.5H17" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>'
    + '<path d="M9 17.5H15" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>'
    + '<path d="M8 3.5C8 2.67157 8.67157 2 9.5 2H14.5C15.3284 2 16 2.67157 16 3.5V4.5C16 5.32843 15.3284 6 14.5 6H9.5C8.67157 6 8 5.32843 8 4.5V3.5Z" stroke="currentColor" stroke-width="1.5"/></svg>';

  let button = null;
  let resetTimer = null;

  function isPullOpen() {
    return PULL_URL_RE.test(location.pathname);
  }

  function getPullNumber() {
    const fromUrl = location.pathname.match(PULL_URL_RE);
    return fromUrl ? fromUrl[1] : null;
  }

  // The <h1> is not usable wholesale: alongside the title it carries a visible
  // `#3738` span and a `<span class="sr-only"> - #3738</span>`, so its textContent
  // reads "title - #3738". `.markdown-title` is the title on its own.
  function getPullTitle() {
    const el = document.querySelector(TITLE_SELECTOR + ' .markdown-title')
      // Non-React pages (and older cached views) still use the classic <bdi>.
      || document.querySelector('bdi.js-issue-title')
      || document.querySelector('.js-issue-title');
    const title = el && el.textContent.trim();
    return title || null;
  }

  function buildString() {
    const number = getPullNumber();
    const title = getPullTitle();
    if (!number || !title) return null;
    return `REVIEW - "${title}" - #${number}`;
  }

  function copy(text) {
    if (typeof GM_setClipboard === 'function') {
      GM_setClipboard(text, 'text');
      return Promise.resolve();
    }
    return navigator.clipboard.writeText(text);
  }

  // Icon-only, so feedback is conveyed by tinting the glyph and updating the
  // tooltip rather than swapping a text label. The tint rides on `color` because
  // the strokes are currentColor.
  function flash(title, color) {
    button.title = title;
    button.style.color = color;
    clearTimeout(resetTimer);
    resetTimer = setTimeout(() => {
      button.title = TITLE_IDLE;
      button.style.color = 'var(--fgColor-muted, #59636e)';
    }, 1200);
  }

  function makeButton() {
    const btn = document.createElement('button');
    btn.className = BUTTON_CLASS;
    btn.type = 'button';
    btn.title = TITLE_IDLE;
    btn.setAttribute('aria-label', 'Copy REVIEW - "pr title" - #number to the clipboard');
    btn.innerHTML = ICON;
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
      color: 'var(--fgColor-muted, #59636e)',
      opacity: '0.75',
      verticalAlign: 'middle',
    });
    btn.addEventListener('mouseenter', () => {
      btn.style.opacity = '1';
      btn.style.background = 'var(--bgColor-neutral-muted, rgba(129, 139, 152, 0.12))';
    });
    btn.addEventListener('mouseleave', () => {
      btn.style.opacity = '0.75';
      btn.style.background = 'transparent';
    });

    btn.addEventListener('click', function (event) {
      event.preventDefault();
      event.stopPropagation();

      const text = buildString();
      if (!text) {
        flash('No pull request found', 'var(--fgColor-muted, #59636e)');
        return;
      }

      Promise.resolve(copy(text))
        // Green on success, red on failure.
        .then(() => flash('Copied!', 'var(--fgColor-success, #1a7f37)'))
        .catch(() => flash('Copy failed', 'var(--fgColor-danger, #cf222e)'));
    });

    return btn;
  }

  // The Edit button only exists for people who can rename the PR, so it is an
  // anchor when present and never a requirement: without it the icon goes at the
  // end of the title row, which is where Edit would have been anyway.
  function findEditWrapper(row) {
    const edit = Array.from(row.querySelectorAll('button')).find((b) => {
      if (b.classList.contains(BUTTON_CLASS)) return false;
      const label = (b.getAttribute('aria-label') || b.textContent || '').trim();
      return /^edit\b/i.test(label);
    });
    if (!edit) return null;
    // Primer wraps the button (tooltip/anchor span); insert after the whole
    // wrapper so the tooltip does not end up containing our node.
    let node = edit;
    while (node.parentElement && node.parentElement !== row) node = node.parentElement;
    return node.parentElement === row ? node : edit;
  }

  function inject() {
    const title = isPullOpen() ? document.querySelector(TITLE_SELECTOR) : null;
    const row = title && title.parentElement;

    if (!row) {
      // Not a PR page (or header not rendered yet): drop any stray copies.
      for (const stray of document.querySelectorAll('.' + BUTTON_CLASS)) stray.remove();
      return;
    }

    if (!button) button = makeButton();

    // Hard singleton: remove every node that isn't the one instance we track.
    // React reconciliation can detach ours mid-flight, and the observer below
    // would then add a second one — the Shortcut script had exactly that bug.
    for (const stray of document.querySelectorAll('.' + BUTTON_CLASS)) {
      if (stray !== button) stray.remove();
    }

    const anchor = findEditWrapper(row);
    if (anchor) {
      if (anchor.nextElementSibling !== button) anchor.after(button);
    } else if (button.parentElement !== row) {
      row.appendChild(button);
    }
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

  // SPA navigation: GitHub swaps PRs and tabs (Conversation/Files) without a full
  // page load, via Turbo and React soft navigation.
  for (const method of ['pushState', 'replaceState']) {
    const original = history[method];
    history[method] = function () {
      const result = original.apply(this, arguments);
      inject();
      return result;
    };
  }
  window.addEventListener('popstate', inject);
  document.addEventListener('turbo:load', inject);
  document.addEventListener('pjax:end', inject);

  inject();
})();

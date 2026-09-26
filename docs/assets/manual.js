// Copyright (C) 2026 seijiro and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
/* No analytics, network requests, or external dependencies. */
(() => {
  'use strict';
  const input = document.querySelector('#manual-search');
  const results = document.querySelector('#search-results');
  const status = document.querySelector('#search-status');
  const root = document.body.dataset.root;
  const normalize = value => value.toLocaleLowerCase().normalize('NFKC');
  input.addEventListener('input', () => {
    const terms = normalize(input.value).trim().split(/\s+/).filter(Boolean);
    results.replaceChildren();
    results.hidden = !terms.length;
    if (!terms.length) { status.textContent = ''; return; }
    const found = (window.TATEGAKI_SEARCH || []).filter(entry =>
      terms.every(term => normalize(entry.title + ' ' + entry.text).includes(term)))
      .sort((a, b) => Number(terms.every(t => normalize(b.title).includes(t))) - Number(terms.every(t => normalize(a.title).includes(t))))
      .slice(0, 12);
    status.textContent = `${found.length}件の候補`;
    if (!found.length) {
      const message = document.createElement('p');
      message.textContent = '見つかりませんでした。短い用語でも検索できます。例：ルビ、余白、Docker';
      results.append(message);
    }
    for (const entry of found) {
      const link = document.createElement('a');
      link.href = root + entry.url;
      link.textContent = entry.title;
      results.append(link);
    }
  });
  input.addEventListener('keydown', event => {
    if (event.key === 'Escape') { results.hidden = true; }
    if (event.key === 'ArrowDown' && !results.hidden) {
      results.querySelector('a')?.focus(); event.preventDefault();
    }
    if (event.key === 'Enter' && !results.hidden) results.querySelector('a')?.click();
  });
  results.addEventListener('keydown', event => {
    if (event.key === 'Escape') { results.hidden = true; input.focus(); }
  });
  document.addEventListener('click', event => {
    if (!event.target.closest('.search')) results.hidden = true;
  });
  for (const block of document.querySelectorAll('pre')) {
    if (!block.querySelector('code')) continue;
    const button = document.createElement('button');
    button.type = 'button'; button.className = 'copy-button'; button.textContent = 'コピー';
    button.setAttribute('aria-label', 'このコードをコピー');
    button.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(block.querySelector('code').textContent);
        button.textContent = 'コピーしました';
      } catch (_) {
        const selection = window.getSelection(); const range = document.createRange();
        range.selectNodeContents(block.querySelector('code'));
        selection.removeAllRanges(); selection.addRange(range);
        button.textContent = '選択しました：⌘C / Ctrl+C';
      }
      setTimeout(() => { button.textContent = 'コピー'; }, 2500);
    });
    block.append(button);
  }
  for (const table of document.querySelectorAll('article table')) {
    if (table.parentElement.classList.contains('table-scroll')) continue;
    const scroll = document.createElement('div'); scroll.className = 'table-scroll';
    scroll.tabIndex = 0; scroll.setAttribute('role', 'region');
    scroll.setAttribute('aria-label', '表（横にスクロールできます）');
    table.replaceWith(scroll); scroll.append(table);
  }
  const filter = document.querySelector('#reference-filter');
  filter?.addEventListener('input', () => {
    const query = normalize(filter.value);
    let count = 0;
    document.querySelectorAll('.ref-entry').forEach(entry => {
      entry.hidden = !normalize(entry.textContent).includes(query);
      if (!entry.hidden) count++;
    });
    document.querySelector('#reference-count').textContent = `${count}項目を表示`;
  });
})();

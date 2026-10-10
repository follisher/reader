/// Runs inside the active Readium document. DOM Range supplies document order
/// across tags/paragraphs; quote text alone cannot establish range identity.
const epubSelectionScript = r'''
(input) => {
  const body = document.body;
  const point = (p) => {
    const element = document.querySelector(p.cssSelector);
    if (!element) throw new Error('Missing selection element');
    if (p.charOffset == null) return [element, p.textNodeIndex];
    const nodes = Array.from(element.childNodes).filter(n => n.nodeType === 3);
    const node = nodes[p.textNodeIndex];
    if (!node || p.charOffset > node.length) throw new Error('Invalid text point');
    return [node, p.charOffset];
  };
  const atOffset = (root, offset) => {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      if (offset <= node.length) return [node, offset];
      offset -= node.length;
    }
    throw new Error('Text offset outside document');
  };
  const normalizedText = text => text.replace(/[\s\u3000]+/gu, '');
  const resolve = (locator) => {
    const dom = locator.locations?.domRange;
    if (dom?.end) {
      try {
        const range = document.createRange();
        range.setStart(...point(dom.start));
        range.setEnd(...point(dom.end));
        if (!range.collapsed && (!locator.text?.highlight ||
            normalizedText(range.toString()) === normalizedText(locator.text.highlight))) return range;
      } catch (_) { /* Older locators may only resolve through their quote. */ }
    }
    const selector = locator.locations?.cssSelector;
    const root = selector ? document.querySelector(selector) : body;
    const quote = locator.text?.highlight;
    if (!root || !quote) return null;
    const text = root.textContent;
    const before = locator.text.before || '';
    const after = locator.text.after || '';
    const matches = [];
    for (let index = text.indexOf(quote); index >= 0;
         index = text.indexOf(quote, index + 1)) {
      const prefix = text.slice(0, index);
      const suffix = text.slice(index + quote.length);
      // Context may have been captured outside the selector's subtree.
      const left = before.slice(-Math.min(before.length, prefix.length));
      const right = after.slice(0, Math.min(after.length, suffix.length));
      if (prefix.endsWith(left) && suffix.startsWith(right)) matches.push(index);
    }
    // Never guess which repeated occurrence should be removed/merged.
    if (matches.length !== 1) return null;
    const range = document.createRange();
    range.setStart(...atOffset(root, matches[0]));
    range.setEnd(...atOffset(root, matches[0] + quote.length));
    return range;
  };
  const selector = (element) => {
    const parts = [];
    for (let el = element; el; el = el.parentElement) {
      if (el.id) {
        const id = '#' + CSS.escape(el.id);
        if (document.querySelectorAll(id).length === 1) {
          parts.unshift(id);
          break;
        }
      }
      let index = 1;
      for (let prev = el.previousElementSibling; prev; prev = prev.previousElementSibling) {
        if (prev.localName === el.localName) index++;
      }
      parts.unshift(CSS.escape(el.localName) + ':nth-of-type(' + index + ')');
    }
    return parts.join(' > ');
  };
  const serializePoint = (node, offset) => {
    if (node.nodeType !== 3) return {cssSelector: selector(node), textNodeIndex: offset};
    return {
      cssSelector: selector(node.parentElement),
      textNodeIndex: Array.from(node.parentNode.childNodes).filter(n => n.nodeType === 3).indexOf(node),
      charOffset: offset,
    };
  };
  const serialize = (range, original) => {
    let root = range.commonAncestorContainer;
    if (root.nodeType !== 1) root = root.parentElement;
    const prefix = document.createRange();
    prefix.selectNodeContents(root);
    prefix.setEnd(range.startContainer, range.startOffset);
    const suffix = document.createRange();
    suffix.selectNodeContents(root);
    suffix.setStart(range.endContainer, range.endOffset);
    // Regenerate every anchor field. Keeping the old quote/CFI after expanding
    // a range makes Readium draw only the old text on platforms using quotes.
    return {
      href: original.href, type: original.type, title: original.title,
      locations: {
        cssSelector: selector(root),
        domRange: {
          start: serializePoint(range.startContainer, range.startOffset),
          end: serializePoint(range.endContainer, range.endOffset),
        },
      },
      text: {highlight: range.toString(), before: prefix.toString().slice(-200), after: suffix.toString().slice(0, 200)},
    };
  };
  const selection = window.getSelection();
  let selected = selection && selection.rangeCount && !selection.isCollapsed
      ? selection.getRangeAt(0).cloneRange() : resolve(input.selection);
  if (!selected || selected.collapsed) throw new Error('无法定位选中文字，请重新选择');
  const snapshot = serialize(selected, input.selection);
  const selectedOffsets = (range) => {
    const prefix = document.createRange();
    prefix.selectNodeContents(body);
    prefix.setEnd(range.startContainer, range.startOffset);
    const start = prefix.toString().length;
    prefix.setEnd(range.endContainer, range.endOffset);
    return [start, prefix.toString().length];
  };
  const rows = input.rows.map(row => ({...row, range: resolve(row.locator)}));
  const ids = new Set();
  let changed;
  do {
    changed = false;
    const [start, end] = selectedOffsets(selected);
    for (const row of rows) {
      if (!row.range || ids.has(row.id)) continue;
      const [a, b] = selectedOffsets(row.range);
      if (a >= end || b <= start) continue;
      ids.add(row.id);
      if (input.action === 'underline') {
        if (a < start) selected.setStart(row.range.startContainer, row.range.startOffset);
        if (b > end) selected.setEnd(row.range.endContainer, row.range.endOffset);
        changed = true;
        break; // Recompute the union before comparing another saved range.
      }
    }
  } while (changed);
  return JSON.stringify({
    selection: snapshot,
    locator: serialize(selected, input.selection),
    ids: Array.from(ids),
  });
}
''';

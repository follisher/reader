// Readium 3.3 removes rectangles contained by another rectangle. A Range
// spanning paragraphs includes both block boxes and text line boxes, so the
// block boxes swallow every intermediate line. Supply text-only geometry
// during decoration layout, including when fonts/viewport sizes change.
(function () {
  'use strict';
  function install() {
    const readium = window.readium;
    if (!readium || !readium.getDecorations || readium.__textRectsInstalled) return;
    readium.__textRectsInstalled = true;
    const nativeRects = Range.prototype.getClientRects;
    function nativeDecoration(decoration) {
      const locator = decoration && decoration.locator;
      const dom = locator && locator.locations && locator.locations.domRange;
      if (!dom || !dom.end) return decoration;
      try {
        const point = p => {
          const element = document.querySelector(p.cssSelector);
          if (!element) throw new Error('Missing range element');
          if (p.charOffset == null) return [element, p.textNodeIndex];
          return [Array.from(element.childNodes).filter(n => n.nodeType === Node.TEXT_NODE)[p.textNodeIndex], p.charOffset];
        };
        const range = document.createRange();
        range.setStart(...point(dom.start));
        range.setEnd(...point(dom.end));
        const normalize = text => text.replace(/[\s\u3000]+/gu, '');
        if (range.collapsed || (locator.text?.highlight &&
            normalize(range.toString()) !== normalize(locator.text.highlight))) return decoration;
        // Readium 3.3's quote resolver ignores domRange. Generate an exact
        // quote and full context from the live DOM, preserving paragraph gaps.
        const prefix = document.createRange();
        prefix.selectNodeContents(document.body);
        prefix.setEnd(range.startContainer, range.startOffset);
        const suffix = document.createRange();
        suffix.selectNodeContents(document.body);
        suffix.setStart(range.endContainer, range.endOffset);
        return { ...decoration, locator: { ...locator,
          locations: { ...locator.locations, cssSelector: 'body' },
          text: { highlight: range.toString(), before: prefix.toString(), after: suffix.toString() },
        } };
      } catch (_) {
        return decoration; // Keep legacy quote-only and stale anchors usable.
      }
    }
    function textRects() {
      const root = this.commonAncestorContainer;
      if (root.nodeType === Node.TEXT_NODE || this.collapsed) {
        return nativeRects.call(this);
      }
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      const rects = [];
      let node;
      while ((node = walker.nextNode())) {
        if (!this.intersectsNode(node) || !node.length) continue;
        const part = document.createRange();
        part.selectNodeContents(node);
        if (part.compareBoundaryPoints(Range.START_TO_START, this) < 0) {
          part.setStart(this.startContainer, this.startOffset);
        }
        if (part.compareBoundaryPoints(Range.END_TO_END, this) > 0) {
          part.setEnd(this.endContainer, this.endOffset);
        }
        if (!part.collapsed) rects.push(...nativeRects.call(part));
      }
      // Keep image-only decorations (for example comic spotlights) working.
      return rects.length ? rects : nativeRects.call(this);
    }
    const getDecorations = readium.getDecorations;
    readium.getDecorations = function (...args) {
      const group = getDecorations.apply(this, args);
      if (group.__textRectsInstalled) return group;
      group.__textRectsInstalled = true;
      for (const name of ['add', 'update', 'requestLayout']) {
        const layout = group[name];
        group[name] = function (...layoutArgs) {
          if (name === 'add' || name === 'update') {
            layoutArgs[0] = nativeDecoration(layoutArgs[0]);
          }
          const previous = Range.prototype.getClientRects;
          Range.prototype.getClientRects = textRects;
          try {
            return layout.apply(this, layoutArgs);
          } finally {
            Range.prototype.getClientRects = previous;
          }
        };
      }
      return group;
    };
  }
  install();
  document.addEventListener('DOMContentLoaded', install);
  window.addEventListener('load', install);
})();

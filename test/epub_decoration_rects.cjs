// Run with NODE_PATH pointing to a Playwright installation.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const path = require('node:path');
(async () => {
  const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  try {
    const page = await browser.newPage();
    await page.setContent(`<style>body{width:260px;font:20px/1.6 sans-serif}p{margin:12px 0}</style>
      <p>${'开始文字'.repeat(20)}</p><p>${'中间段落文字'.repeat(30)}</p>
      <p>${'另一段文字'.repeat(20)}<em>${'嵌套文字'.repeat(10)}</em></p><p>${'结束文字'.repeat(20)}</p>`);
    await page.evaluate(() => {
      window.originalRects = Range.prototype.getClientRects;
      const paragraphs = document.querySelectorAll('p');
      window.selected = document.createRange();
      selected.setStart(paragraphs[0].firstChild, 10);
      selected.setEnd(paragraphs[3].firstChild, 12);
      window.expected = () => {
        const result = [];
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          for (let i = 0; i < node.length; i++) {
            if (selected.comparePoint(node, i) < 0 || selected.comparePoint(node, i + 1) > 0) continue;
            const r = document.createRange(); r.setStart(node, i); r.setEnd(node, i + 1);
            result.push(...r.getClientRects());
          }
        }
        return result.filter(r => r.width > 0 && r.height > 0);
      };
      // Readium's BOXES layout removes contained rectangles before painting.
      window.group = { add(value) {
        window.receivedDecoration = value;
        const rects = Array.from(selected.getClientRects());
        return rects.filter(r => !rects.some(other => other !== r && other.top <= r.top && other.bottom >= r.bottom && other.left <= r.left && other.right >= r.right && other.height > r.height));
      }, update(value) { return this.add(value); }, requestLayout() { return this.add(); } };
      window.readium = { getDecorations: () => group };
    });
    const lines = () => page.evaluate(() => {
      const key = r => `${Math.round(r.bottom)}:${Math.floor(r.left / 320)}`;
      return {
        expected: [...new Set(expected().map(key))].sort(),
        actual: [...new Set(readium.getDecorations().requestLayout().filter(r => r.width > 0).map(key))].sort(),
        restored: Range.prototype.getClientRects === originalRects,
      };
    });
    const before = await lines();
    assert.notDeepEqual(before.actual, before.expected, 'fixture must reproduce missing intermediate lines');
    await page.addScriptTag({ path: path.resolve(__dirname, '../third_party/flutter_readium/assets/helpers/decorationTextRects.js') });
    for (const method of ['add', 'update']) {
      const anchor = await page.evaluate(method => {
        const locator = {
          locations: { cssSelector: 'p:first-of-type', domRange: {
            start: { cssSelector: 'p:first-of-type', textNodeIndex: 0, charOffset: 10 },
            end: { cssSelector: 'p:nth-of-type(4)', textNodeIndex: 0, charOffset: 12 },
          } },
          text: { highlight: selected.toString().replace(/\s/gu, '') },
        };
        readium.getDecorations()[method]({ id: 'saved-scroll-note', locator });
        return { result: receivedDecoration.locator, exact: selected.toString(), original: locator };
      }, method);
      assert.equal(anchor.result.locations.cssSelector, 'body');
      assert.equal(anchor.result.text.highlight, anchor.exact);
      assert.equal(anchor.original.locations.cssSelector, 'p:first-of-type', 'saved locator is not mutated');
    }
    for (const style of ['', 'font-size:26px;width:220px', 'width:280px;height:400px;column-width:280px;column-gap:40px']) {
      await page.evaluate(style => { document.body.style.cssText = style; }, style);
      const result = await lines();
      assert.deepEqual(result.actual, result.expected, `all selected lines after reflow: ${style}`);
      assert.ok(result.restored, 'native Range geometry must be restored');
    }
    console.log('PASS: reproduced missing lines; every selected line restored across paragraphs, inline tags, font changes and columns.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });

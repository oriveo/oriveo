import { describe, expect, it } from 'vitest';
import { captureRangeQuoteSelection } from './useTextSelectionAnchor';

function messageWith(html: string): HTMLElement {
  const message = document.createElement('div');
  message.dataset.messageId = 'message-1';
  message.innerHTML = html;
  document.body.appendChild(message);
  return message;
}

function selectText(node: Text, start: number, end: number): Range {
  const range = document.createRange();
  range.setStart(node, start);
  range.setEnd(node, end);
  return range;
}

describe('captureRangeQuoteSelection', () => {
  it('captures prose current block plus one non-empty adjacent block on each side', () => {
    const message = messageWith(`
      <p data-quote-block="prose">previous block</p>
      <p data-quote-block="prose">current selected tail</p>
      <p data-quote-block="prose">next block</p>
    `);
    const current = message.children[1].firstChild as Text;
    const snapshot = captureRangeQuoteSelection(selectText(current, 8, 16), message);
    expect(snapshot).toMatchObject({ selectedText: 'selected', contentKind: 'prose', contextReliable: true });
    expect(snapshot.leadingText).toBe('previous block\n\ncurrent ');
    expect(snapshot.trailingText).toBe(' tail\n\nnext block');
    message.remove();
  });

  it('keeps full code block as context without borrowing adjacent prose', () => {
    const message = messageWith(`
      <p data-quote-block="prose">outside</p>
      <pre data-quote-block="code"><code>const value = 42;</code></pre>
    `);
    const code = message.querySelector('code')!.firstChild as Text;
    const snapshot = captureRangeQuoteSelection(selectText(code, 6, 11), message);
    expect(snapshot).toMatchObject({ selectedText: 'value', contentKind: 'code', contextReliable: true });
    expect(snapshot.leadingText).toBe('const ');
    expect(snapshot.trailingText).toBe(' = 42;');
    message.remove();
  });

  it('uses the current table row as the table context', () => {
    const message = messageWith(`
      <table><tbody>
        <tr data-quote-block="table"><td>alpha</td><td>beta</td></tr>
        <tr data-quote-block="table"><td>gamma</td><td>delta</td></tr>
      </tbody></table>
    `);
    const cell = message.querySelector('tr')!.children[1].firstChild as Text;
    const snapshot = captureRangeQuoteSelection(selectText(cell, 0, 4), message);
    expect(snapshot.contentKind).toBe('table');
    expect(snapshot.selectedText).toBe('beta');
    expect(snapshot.leadingText).toContain('alpha');
    expect(snapshot.trailingText).not.toContain('gamma');
    message.remove();
  });

  it('preserves raw TeX when a rendered formula is selected', () => {
    const message = messageWith(`
      <p data-quote-block="prose"><span class="katex">
        <span class="katex-mathml"><math><semantics><annotation encoding="application/x-tex">x^2</annotation></semantics></math></span>
        <span class="katex-html">x2</span>
      </span></p>
    `);
    const katex = message.querySelector('.katex')!;
    const range = document.createRange();
    range.selectNodeContents(katex);
    const snapshot = captureRangeQuoteSelection(range, message);
    expect(snapshot.selectedText).toBe('$x^2$');
    message.remove();
  });

  it('falls back to selected-only when semantic DOM mapping is unavailable', () => {
    const message = messageWith('<span>unsafe to infer context here</span>');
    const text = message.firstChild!.firstChild as Text;
    const snapshot = captureRangeQuoteSelection(selectText(text, 0, 6), message);
    expect(snapshot).toEqual({
      selectedText: 'unsafe',
      contentKind: 'prose',
      leadingText: '',
      trailingText: '',
      contextReliable: false,
    });
    message.remove();
  });
});

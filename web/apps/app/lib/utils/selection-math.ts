/**
 * Serialize a text selection, restoring formula source.
 *
 * `window.getSelection().toString()` returns only the rendered visible text for a KaTeX formula:
 * the `$..$` / `$$..$$` delimiters are gone, and .katex-mathml plus .katex-html duplicate the
 * text. That is the root cause of formulas failing to render after a selection is saved as a
 * note. KaTeX embeds `annotation[encoding="application/x-tex"]` with the original TeX in the
 * DOM, so the source can be restored exactly:
 * - inline formula `.katex` -> `$tex$`
 * - display formula `.katex-display` -> `$$tex$$` on its own line
 * Other nodes are serialized as visible text, adding a newline after block elements and a tab
 * between table cells, which approximates toString behavior.
 */

const BLOCK_TAGS = new Set([
  'P', 'DIV', 'LI', 'UL', 'OL', 'TABLE', 'THEAD', 'TBODY', 'TR',
  'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'PRE', 'BLOCKQUOTE', 'SECTION', 'ARTICLE',
]);

function katexTex(element: Element): string | null {
  const annotation = element.querySelector('annotation[encoding="application/x-tex"]');
  const tex = annotation?.textContent?.trim();
  return tex || null;
}

function serializeNode(node: Node, out: string[]): void {
  if (node.nodeType === Node.TEXT_NODE) {
    out.push(node.nodeValue ?? '');
    return;
  }
  if (node.nodeType === Node.DOCUMENT_FRAGMENT_NODE) {
    for (const child of Array.from(node.childNodes)) serializeNode(child, out);
    return;
  }
  if (!(node instanceof Element)) return;

  if (node.classList.contains('katex-display')) {
    const katex = node.querySelector('.katex');
    const tex = katex ? katexTex(katex) : katexTex(node);
    if (tex) {
      out.push(`\n$$${tex}$$\n`);
      return;
    }
    // A partial selection cut the annotation off: fall back to visible text through the generic branch below.
  } else if (node.classList.contains('katex')) {
    const tex = katexTex(node);
    if (tex) {
      out.push(`$${tex}$`);
      return;
    }
    // No annotation: take the visible text of .katex-html only, to avoid duplicating the MathML text.
    const html = node.querySelector('.katex-html');
    if (html) {
      out.push(html.textContent ?? '');
      return;
    }
  } else if (node.classList.contains('katex-mathml')) {
    // Duplicates the .katex-html content, which is where toString's doubled text comes from, so skip it.
    return;
  }

  if (node.tagName === 'BR') {
    out.push('\n');
    return;
  }
  for (const child of Array.from(node.childNodes)) serializeNode(child, out);
  if (node.tagName === 'TD' || node.tagName === 'TH') {
    out.push('\t');
  } else if (BLOCK_TAGS.has(node.tagName)) {
    out.push('\n');
  }
}

/** Serialize a selection into text where formulas carry their source delimiters; an empty selection returns an empty string. */
export function selectionTextWithMathSource(selection: Selection): string {
  const parts: string[] = [];
  for (let i = 0; i < selection.rangeCount; i += 1) {
    parts.push(rangeTextWithMathSource(selection.getRangeAt(i)));
  }
  return parts.join('').replace(/\n{3,}/g, '\n\n');
}

/** Serialize a single Range, so a selection and the semantic blocks around it share one set of formula restoration rules. */
export function rangeTextWithMathSource(range: Range): string {
  const startElement = range.startContainer instanceof Element
    ? range.startContainer
    : range.startContainer.parentElement;
  const endElement = range.endContainer instanceof Element
    ? range.endContainer
    : range.endContainer.parentElement;
  const startKatex = startElement?.closest('.katex');
  const endKatex = endElement?.closest('.katex');
  // Range.selectNodeContents(.katex) leaves only child nodes after cloning, losing the parent
  // .katex marker, so detect "the selection lies entirely inside one formula" before cloning and
  // use the annotation's original TeX directly.
  if (startKatex && startKatex === endKatex) {
    const tex = katexTex(startKatex);
    if (tex) {
      return startKatex.closest('.katex-display') ? `\n$$${tex}$$\n` : `$${tex}$`;
    }
  }
  const parts: string[] = [];
  serializeNode(range.cloneContents(), parts);
  return parts.join('').replace(/\n{3,}/g, '\n\n');
}

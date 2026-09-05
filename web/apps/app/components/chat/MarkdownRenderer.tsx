'use client';

import { memo, useMemo, type ReactNode, isValidElement, Children } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import remarkMath from 'remark-math';
import rehypeKatex from 'rehype-katex';
import remarkCjkFriendly from 'remark-cjk-friendly';
import remarkCjkFriendlyGfmStrikethrough from 'remark-cjk-friendly-gfm-strikethrough';
import type { Components } from 'react-markdown';
import { normalizeLatexDelimiters, splitClosedAndOpenLatex } from '../../lib/utils/latex-normalizer';
import { highlightCode } from '../../lib/markdown/highlight-setup';
import { extractText } from '../../lib/markdown/extract-text';
import { CodeBlock } from './CodeBlock';
import styles from './MarkdownRenderer.module.css';
import './highlight-theme.css';

interface MarkdownRendererProps {
  content: string;
  isStreaming?: boolean;
  onSaveCodeBlock?: (markdown: string) => void;
  /**
   * Whether to attach the per-character fade plugin (on by default). It emits one `<span>` per
   * character, so the DOM node count is O(characters). Body text is fine up to a measured 2400
   * characters, but a reasoning stream can reach tens of thousands - pass false there, or every
   * frame rebuilds a hast tree of tens of thousands of nodes and reconciles it. The reasoning
   * block does not need the effect anyway; it has its own marquee semantics.
   */
  enableCharFade?: boolean;
}

/* Streaming per-character fade: split the text nodes of the rendered markdown into one
 * <span class="o-fadeChar"> per character.
 * Text is only appended, so the spans for existing characters keep their position (React reuses
 * them, no remount, no replayed animation); only newly arrived spans mount and each plays
 * opacity 0->1 once, and the arrival rhythm gives a natural per-character stagger.
 * code/pre/katex subtrees are skipped: code and formulas are not faded per character, and it
 * would break the KaTeX structure. */
const FADE_SKIP_TAGS = new Set(['code', 'pre', 'script', 'style']);
/**
 * Maximum content length, in characters, for the per-character fade.
 *
 * The plugin emits one `<span>` per character, and react-markdown's synchronous entry point
 * builds a fresh processor and reparses everything on each render with no internal caching.
 * While streaming both costs are paid per frame, which is O(characters) per frame and O(n^2)
 * cumulative. The measured baseline is fine at 2400 characters of body text, but reasoning
 * model answers are routinely 5k-15k characters, where every frame would rebuild tens of
 * thousands of nodes.
 *
 * Only the characters that just arrived are visibly fading, so the spans for the first few
 * thousand characters are built for nothing. Above the threshold the plugin is simply not
 * attached: what is saved is pure waste, and visually the tail of a long answer stops fading.
 * The animation uses `both` fill with a final opacity:1, so dropping the spans causes no flash,
 * and the spans carry no layout styles, so nothing reflows.
 */
const CHAR_FADE_MAX_CHARS = 3000;
// Table structure containers: their direct text children are only layout whitespace, since GFM
// puts no real text at this level. They must never be wrapped in <span>, which would violate
// HTML table nesting (<span> cannot be a child of table/thead/tbody/tr) and trigger a hydration
// error. Recursion still enters td/th, so text inside cells fades per character as usual.
const TABLE_STRUCTURE_TAGS = new Set(['table', 'thead', 'tbody', 'tfoot', 'tr', 'colgroup']);

function hasKatexClass(node: { properties?: { className?: unknown } }): boolean {
  const cls = node.properties?.className;
  const arr = Array.isArray(cls) ? cls : typeof cls === 'string' ? cls.split(' ') : [];
  return arr.some((c) => typeof c === 'string' && c.startsWith('katex'));
}

function rehypeStreamingCharFade() {
  return (tree: any) => {
    const wrap = (parent: any) => {
      const children = parent.children;
      if (!Array.isArray(children)) return;
      // Whitespace text at the table structure level is not wrapped per character (see TABLE_STRUCTURE_TAGS).
      const skipTextWrap = TABLE_STRUCTURE_TAGS.has(parent.tagName);
      // Iterate backwards: splicing a text node into several spans does not shift the lower indices still to be processed.
      for (let i = children.length - 1; i >= 0; i -= 1) {
        const child = children[i];
        if (child.type === 'text') {
          if (skipTextWrap) continue;
          const chars = Array.from(child.value as string);
          if (chars.length === 0) continue;
          const spans = chars.map((ch) => ({
            type: 'element',
            tagName: 'span',
            properties: { className: ['o-fadeChar'] },
            children: [{ type: 'text', value: ch }],
          }));
          children.splice(i, 1, ...spans);
        } else if (child.type === 'element') {
          if (FADE_SKIP_TAGS.has(child.tagName) || hasKatexClass(child)) continue;
          wrap(child);
        }
      }
    };
    wrap(tree);
  };
}

interface StreamingMarkdownParts {
  renderedContent: string;
  tail: string;
}

function isEscaped(value: string, index: number): boolean {
  let slashCount = 0;
  for (let i = index - 1; i >= 0 && value[i] === '\\'; i -= 1) {
    slashCount += 1;
  }
  return slashCount % 2 === 1;
}

function findLastUnclosedDelimiter(value: string, delimiter: string): number {
  const indexes: number[] = [];
  let index = 0;

  while (index < value.length) {
    const found = value.indexOf(delimiter, index);
    if (found === -1) break;

    if (!isEscaped(value, found)) {
      indexes.push(found);
    }
    index = found + delimiter.length;
  }

  return indexes.length % 2 === 1 ? indexes[indexes.length - 1] : -1;
}

function findLastUnclosedInlineCode(value: string): number {
  const indexes: number[] = [];

  for (let i = 0; i < value.length; i += 1) {
    if (value[i] !== '`' || isEscaped(value, i)) continue;
    if (value.slice(i, i + 3) === '```') {
      i += 2;
      continue;
    }
    indexes.push(i);
  }

  return indexes.length % 2 === 1 ? indexes[indexes.length - 1] : -1;
}

function findLastUnclosedFence(value: string): number {
  const indexes: number[] = [];
  const fencePattern = /(^|\n)(```|~~~)/g;
  let match: RegExpExecArray | null;

  while ((match = fencePattern.exec(value)) !== null) {
    const fenceIndex = match.index + (match[1] ? match[1].length : 0);
    if (!isEscaped(value, fenceIndex)) {
      indexes.push(fenceIndex);
    }
  }

  return indexes.length % 2 === 1 ? indexes[indexes.length - 1] : -1;
}

function maskRange(value: string, start: number, end: number): string {
  return `${value.slice(0, start)}${' '.repeat(Math.max(0, end - start))}${value.slice(end)}`;
}

function maskClosedFences(value: string): string {
  let masked = value;
  const fencePattern = /(^|\n)(```|~~~)/g;
  let open: { index: number; marker: string } | null = null;
  let match: RegExpExecArray | null;

  while ((match = fencePattern.exec(value)) !== null) {
    const fenceIndex = match.index + (match[1] ? match[1].length : 0);
    const marker = match[2];
    if (isEscaped(value, fenceIndex)) continue;

    if (!open) {
      open = { index: fenceIndex, marker };
      continue;
    }

    if (open.marker === marker) {
      masked = maskRange(masked, open.index, fenceIndex + marker.length);
      open = null;
    }
  }

  return masked;
}

function maskClosedInlineCode(value: string): string {
  let masked = value;
  let openIndex = -1;

  for (let i = 0; i < value.length; i += 1) {
    if (value[i] !== '`' || isEscaped(value, i)) continue;
    if (value.slice(i, i + 3) === '```') {
      i += 2;
      continue;
    }

    if (openIndex === -1) {
      openIndex = i;
    } else {
      masked = maskRange(masked, openIndex, i + 1);
      openIndex = -1;
    }
  }

  return masked;
}

function stripStreamingMarkdownMarkers(value: string): string {
  return value
    .replace(/^(```|~~~)[^\n]*\n?/, '')
    .replace(/^(\*\*|__|~~|`)/, '')
    .replace(/^\[([^\]]*)\]\($/, '$1 ')
    .replace(/^\[/, '')
    .replace(/\]\($/, ' ')
    .replace(/^\(/, '');
}

function splitClosedAndOpenMarkdown(content: string): StreamingMarkdownParts {
  const openFenceIndex = findLastUnclosedFence(content);
  let fenceMaskedContent = maskClosedFences(content);
  // An unclosed code fence (still streaming) is handed to react-markdown as a whole and rendered
  // as a CodeBlock card, so the card appears first and code streams into it, instead of showing
  // raw text that only becomes a card once the fence closes. The fence start is therefore not a
  // split point (it never enters candidates) and the whole block goes into renderedContent.
  // Inside the fence the content is literal text and has to be masked to equal-length spaces
  // before computing inline candidates: otherwise [ / ` / ** / __ inside the code look like
  // unclosed inline markers, pulling a split point into the code block, truncating the card and
  // making it jitter as markers happen to balance. After masking the fence produces no
  // candidates and the card content grows steadily.
  if (openFenceIndex >= 0) {
    fenceMaskedContent = maskRange(fenceMaskedContent, openFenceIndex, content.length);
  }
  const markdownMaskedContent = maskClosedInlineCode(fenceMaskedContent);
  const candidates = [
    findLastUnclosedDelimiter(markdownMaskedContent, '**'),
    findLastUnclosedDelimiter(markdownMaskedContent, '__'),
    findLastUnclosedDelimiter(markdownMaskedContent, '~~'),
    findLastUnclosedInlineCode(fenceMaskedContent),
  ].filter((index) => index >= 0);

  const linkTextIndex = markdownMaskedContent.lastIndexOf('[');
  if (linkTextIndex >= 0 && !isEscaped(content, linkTextIndex)) {
    const afterLinkText = markdownMaskedContent.slice(linkTextIndex);
    if (!afterLinkText.includes(']')) {
      candidates.push(linkTextIndex);
    }
  }

  const linkHrefIndex = markdownMaskedContent.lastIndexOf('](');
  if (linkHrefIndex >= 0 && !isEscaped(content, linkHrefIndex)) {
    const href = markdownMaskedContent.slice(linkHrefIndex + 2);
    if (!href.includes(')')) {
      const linkStart = markdownMaskedContent.lastIndexOf('[', linkHrefIndex);
      candidates.push(linkStart >= 0 ? linkStart : linkHrefIndex);
    }
  }

  if (candidates.length === 0) {
    return { renderedContent: content, tail: '' };
  }

  const splitIndex = Math.max(...candidates);
  return {
    renderedContent: content.slice(0, splitIndex),
    tail: stripStreamingMarkdownMarkers(content.slice(splitIndex)),
  };
}

function prepareStreamingMarkdown(content: string): StreamingMarkdownParts {
  const { closed, tail: latexTail } = splitClosedAndOpenLatex(content);
  const markdownParts = splitClosedAndOpenMarkdown(closed);

  return {
    renderedContent: normalizeLatexDelimiters(markdownParts.renderedContent),
    tail: `${markdownParts.tail}${stripStreamingMarkdownMarkers(latexTail)}`,
  };
}

function safeExternalURL(raw: string | undefined): string | null {
  if (!raw) return null;
  try {
    const url = new URL(raw);
    return url.protocol === 'https:' ? url.toString() : null;
  } catch {
    return null;
  }
}

/* Static component overrides that do not depend on isStreaming, hoisted to module scope so they are not rebuilt on every render. */
const STATIC_COMPONENTS: Components = {
  p({ children }) {
    return <p data-quote-block="prose">{children}</p>;
  },
  h1({ children }) { return <h1 data-quote-block="prose">{children}</h1>; },
  h2({ children }) { return <h2 data-quote-block="prose">{children}</h2>; },
  h3({ children }) { return <h3 data-quote-block="prose">{children}</h3>; },
  h4({ children }) { return <h4 data-quote-block="prose">{children}</h4>; },
  h5({ children }) { return <h5 data-quote-block="prose">{children}</h5>; },
  h6({ children }) { return <h6 data-quote-block="prose">{children}</h6>; },
  /* Inline <code> only - fenced blocks are handled by pre above */
  code({ className, children, ...props }) {
    if (className && className.includes('language-')) {
      return <code className={className} {...props}>{children}</code>;
    }
    return (
      <code className={styles.inlineCode} {...props}>
        {children}
      </code>
    );
  },
  a({ href, children }) {
    const safeHref = safeExternalURL(href);
    if (!safeHref) return <span>{children}</span>;
    return (
      <a href={safeHref} target="_blank" rel="noopener noreferrer" className={styles.link}>
        {children}
      </a>
    );
  },
  img({ alt }) {
    // Model output and Library documents are untrusted. Loading a remote image can
    // exfiltrate prompt content through a crafted URL, so render only its label.
    return alt ? <span>{alt}</span> : null;
  },
  table({ children }) {
    return (
      <div className={styles.tableWrap}>
        <table className={styles.table}>{children}</table>
      </div>
    );
  },
  blockquote({ children }) {
    return <blockquote className={styles.blockquote}>{children}</blockquote>;
  },
  ul({ children }) {
    return <ul className={styles.ul}>{children}</ul>;
  },
  ol({ children }) {
    return <ol className={styles.ol}>{children}</ol>;
  },
  li({ children }) {
    return <li className={styles.li} data-quote-block="prose">{children}</li>;
  },
  tr({ children }) {
    return <tr data-quote-block="table">{children}</tr>;
  },
  hr() {
    return <hr className={styles.hr} />;
  },
};

export const MarkdownRenderer = memo(function MarkdownRenderer({ content, isStreaming, onSaveCodeBlock, enableCharFade = true }: MarkdownRendererProps) {
  // Formula and marker preprocessing: while streaming, everything after an unclosed delimiter
  // ($ \( ** ` ``` links and so on) is peeled off as a plain tail so half-written markers do not
  // twitch; the closed part is normalized \(...\)/\[...\] -> $/$$ for remark-math to pick up.
  // Fading is done by the CSS bottom mask (data-streaming), so nothing is split into increments
  // and no DOM is added or removed here.
  const { renderedContent, tail } = useMemo(() => {
    if (isStreaming) {
      return prepareStreamingMarkdown(content);
    }
    return { renderedContent: normalizeLatexDelimiters(content), tail: '' };
  }, [content, isStreaming]);

  const components: Components = useMemo(
    () => ({
      ...STATIC_COMPONENTS,
      /* Intercept <pre> to wrap fenced code blocks in CodeBlock.
         react-markdown renders: <pre><code className="language-X">...</code></pre>
         We extract plain text, highlight with hljs, and render via CodeBlock. */
      pre({ children }) {
        const child = Children.toArray(children)[0];

        if (isValidElement(child)) {
          const childProps = child.props as {
            className?: string;
            children?: ReactNode;
          };
          const cls = childProps.className || '';
          const match = /language-(\w+)/.exec(cls);
          const lang = match?.[1];
          const plainText = extractText(childProps.children).replace(/\n$/, '');

          if (match || cls.includes('language-')) {
            // With an explicit language, highlight while streaming too: hljs.highlight is
            // single-language, synchronous and fast, and ignoreIllegals tolerates a half-written
            // token, so highlighting the whole block per chunk stays affordable. Without an
            // explicit language, skip it while streaming - highlightAuto scans 20+ registered
            // languages per chunk, which is too expensive; auto detection waits for the final state.
            const highlighted = lang
              ? highlightCode(plainText, lang)
              : isStreaming
                ? undefined
                : highlightCode(plainText);
            return (
              <CodeBlock language={lang} plainText={plainText} highlightedHtml={highlighted} onSaveNote={onSaveCodeBlock} />
            );
          }

          // Fenced code block without a language - still rendered as CodeBlock.
          // No auto-detect while streaming, since it is expensive; highlight the whole block once complete.
          if (plainText) {
            const highlighted = isStreaming ? undefined : highlightCode(plainText);
            return (
              <CodeBlock plainText={plainText} highlightedHtml={highlighted} onSaveNote={onSaveCodeBlock} />
            );
          }
        }

        return <pre data-quote-block="code">{children}</pre>;
      },
    }),
    [isStreaming, onSaveCodeBlock],
  );

  // Attach the per-character fade while streaming only; history and final states skip it to
  // avoid re-rendering and animating the whole text for nothing. Callers passing
  // enableCharFade=false (the reasoning block) skip it even while streaming - see the DOM size
  // reasoning in the props comment.
  const fadeChars = isStreaming && enableCharFade && content.length <= CHAR_FADE_MAX_CHARS;
  const rehypePlugins = useMemo(
    () => (fadeChars ? [rehypeKatex, rehypeStreamingCharFade] : [rehypeKatex]),
    [fadeChars],
  );

  return (
    <div className={styles.markdown} data-streaming={isStreaming ? 'true' : undefined}>
      <ReactMarkdown
        remarkPlugins={[remarkCjkFriendly, remarkGfm, remarkCjkFriendlyGfmStrikethrough, remarkMath]}
        rehypePlugins={rehypePlugins}
        components={components}
      >
        {renderedContent}
      </ReactMarkdown>
      {tail ? (
        <span className={`${styles.streamingTail}${fadeChars ? ' o-fadeChar' : ''}`}>{tail}</span>
      ) : null}
    </div>
  );
});

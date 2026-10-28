/**
 * Splits a Markdown document (already LaTeX-delimiter normalized) at top-level block boundaries into sections
 * that can be mounted progressively for long bodies.
 *
 * Cut points are only places that necessarily start a new top-level block: the previous line is blank, the
 * line is flush-left (not indented), it is not a list marker or a `>` quote, and it is not inside fenced code,
 * a `$$` math block, an HTML comment, or a verbatim block such as <pre>/<script>. A flush-left line after a
 * blank line cannot continue a list item, quote or paragraph, so parsing each section alone yields the same
 * top-level blocks as parsing the whole document.
 *
 * Link reference definitions (`[x]: url`) and footnotes (`[^x]`) are document-scoped and would break if split,
 * so no cut is made when they appear. When the state is unclear it cuts less rather than wrongly: the worst
 * case degrades to one section for the whole document, same as the original rendering.
 */

const LIST_MARKER = /^([-*+]|\d{1,9}[.)])(\s|$)/;
const FENCE_OPEN = /^ {0,3}(`{3,}|~{3,})(.*)$/;
const MATH_OPEN = /^ {0,3}(\${2,})([^$]*)$/;
const RAW_HTML_OPEN = /^ {0,3}<(pre|script|style|textarea)(\s|>|$)/i;
const GLOBAL_SCOPE = /^ {0,3}\[[^\]\n]+\]:|\[\^/m;

export function splitMarkdownSections(markdown: string, targetChars: number): string[] {
  if (markdown.length <= targetChars || GLOBAL_SCOPE.test(markdown)) return [markdown];

  const lines = markdown.split('\n');
  const sections: string[] = [];
  let sectionStart = 0; // index of the first line of the current section
  let sectionChars = 0;
  let fence: { char: string; len: number } | null = null;
  let mathLen = 0;
  let rawHtmlTag: string | null = null;
  let inComment = false;
  let prevBlank = false;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const outside = !fence && mathLen === 0 && !rawHtmlTag && !inComment;

    if (
      outside &&
      prevBlank &&
      sectionChars >= targetChars &&
      line.length > 0 &&
      line[0] !== ' ' &&
      line[0] !== '\t' &&
      line[0] !== '>' &&
      !LIST_MARKER.test(line)
    ) {
      // A section carries no trailing newline; the renderer restores the '\n' between sections so the DOM matches whole-document rendering
      sections.push(lines.slice(sectionStart, i).join('\n').replace(/\n+$/, ''));
      sectionStart = i;
      sectionChars = 0;
    }
    sectionChars += line.length + 1;

    if (fence) {
      const close = new RegExp(`^ {0,3}\\${fence.char}{${fence.len},}\\s*$`);
      if (close.test(line)) fence = null;
    } else if (mathLen > 0) {
      const close = line.match(/^ {0,3}(\${2,})\s*$/);
      if (close && close[1].length >= mathLen) mathLen = 0;
    } else if (rawHtmlTag) {
      if (line.toLowerCase().includes(`</${rawHtmlTag}>`)) rawHtmlTag = null;
    } else if (inComment) {
      if (line.includes('-->')) inComment = false;
    } else {
      const fenceMatch = line.match(FENCE_OPEN);
      const mathMatch = fenceMatch ? null : line.match(MATH_OPEN);
      const htmlMatch = line.match(RAW_HTML_OPEN);
      if (fenceMatch && !(fenceMatch[1][0] === '`' && fenceMatch[2].includes('`'))) {
        fence = { char: fenceMatch[1][0], len: fenceMatch[1].length };
      } else if (mathMatch) {
        mathLen = mathMatch[1].length;
      } else if (htmlMatch && !line.toLowerCase().includes(`</${htmlMatch[1].toLowerCase()}>`)) {
        rawHtmlTag = htmlMatch[1].toLowerCase();
      } else {
        const open = line.lastIndexOf('<!--');
        if (open >= 0 && !line.includes('-->', open + 4)) inComment = true;
      }
    }
    prevBlank = line.trim() === '';
  }

  sections.push(lines.slice(sectionStart).join('\n'));
  return sections;
}

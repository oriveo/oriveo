/**
 * Incremental splitter that cuts an expanded reasoning stream into stable blocks.
 *
 * The problem it solves: react-markdown's synchronous entry point builds a new processor and
 * parses the whole input on every render (node_modules/react-markdown/lib/index.js), with no
 * cache inside. Reasoning text can run to tens of thousands of characters, and reparsing the
 * whole thing every frame is O(n) per frame and O(n squared) overall, which is exactly the cost
 * `ReasoningBlock` avoided by falling back to bare text in a `<pre>`.
 *
 * The approach: cut sealed paragraphs into immutable blocks and hand each to a memoized render
 * component. Once a block's content is fixed it never changes, React.memo skips the rerender, and
 * each block is parsed exactly once in its life. Only the trailing active paragraph is really
 * reparsed each frame, which makes the total cost O(total input).
 *
 * Two hard constraints:
 *
 * 1. Incremental scanning: `advance` scans only `[scanned, text.length)` and never rescans
 *    history, otherwise the splitting itself becomes O(n) per frame and gains nothing.
 * 2. Block boundaries must not cut into a code fence: blank lines are allowed inside a fence, and
 *    splitting blindly on `\n\n` would cut a code block in half, leaving both sides to parse into
 *    broken results (and to be reassembled once it closes, which flickers). Fence parity is
 *    therefore tracked line by line, and blocks are only sealed outside a fence.
 */

export interface ReasoningBlockSplit {
  /** Sealed blocks whose content is final (each keeps its own trailing newline and renders independently). */
  blocks: string[];
  /** The trailing active paragraph, which may grow every frame. */
  tail: string;
}

  /** Whether a line is a ``` or ~~~ fence line. */
function isFenceLine(line: string): boolean {
  const trimmed = line.trim();
  return trimmed.startsWith('```') || trimmed.startsWith('~~~');
}

/**
 * Stateful incremental splitter. The caller (React) holds the instance in a `useRef` and calls
 * `advance` with each new text.
 *
 * text has to be an extension of the previous input (an append-only stream). When it is not
 * (switching messages, replaying), the splitter rebuilds from scratch, which is a rare path where
 * O(n) is acceptable.
 */
export class ReasoningBlockSplitter {
  private blocks: string[] = [];
  /** Start of the current active block within text. */
  private blockStart = 0;
  /** How far the input has been consumed. */
  private scanned = 0;
  /** Start of the current line, used to detect fences line by line. */
  private lineStart = 0;
  /** Whether the scan is inside an unclosed fence. */
  private insideFence = false;
  /** Previous input, used for the append-only check (length and a prefix sentinel only, never a full comparison). */
  private lastText = '';

  advance(text: string): ReasoningBlockSplit {
    if (!text.startsWith(this.lastText)) this.reset();
    this.lastText = text;

    let cursor = this.scanned;
    while (cursor < text.length) {
      const nl = text.indexOf('\n', cursor);
      if (nl < 0) break; // The last line is incomplete, leave it for next time

      const line = text.slice(this.lineStart, nl);
      if (isFenceLine(line)) {
        this.insideFence = !this.insideFence;
      } else if (!this.insideFence && line.trim() === '' && nl + 1 > this.blockStart) {
        // A blank line is a paragraph boundary. Only seal outside a fence, and only when the block is non-empty.
        const block = text.slice(this.blockStart, nl + 1);
        if (block.trim() !== '') {
          this.blocks.push(block);
          this.blockStart = nl + 1;
        } else {
        // A purely blank block (consecutive blank lines) does not become a block of its own; just advance the start, to avoid emitting many empty components
          this.blockStart = nl + 1;
        }
      }

      this.lineStart = nl + 1;
      cursor = nl + 1;
    }
    this.scanned = cursor;

    return { blocks: this.blocks, tail: text.slice(this.blockStart) };
  }

  reset(): void {
    this.blocks = [];
    this.blockStart = 0;
    this.scanned = 0;
    this.lineStart = 0;
    this.insideFence = false;
    this.lastText = '';
  }
}

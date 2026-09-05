'use client';

/**
 * Reasoning / thinking display.
 *
 * Visuals:
 *   - Streaming: decoration bar at 30% primary alpha, pulsing dot, chevron, "Thinking"
 *   - Finished: decoration bar at 20% textTertiary alpha, chevron, "Thought for {duration}"
 *   - Collapsed by default: one line of reasoningTail (last line, markdown markers stripped,
 *     final 40 characters prefixed with an ellipsis), refreshed as new chunks arrive
 *   - Expands only on a click on the header; the state then sticks (userExpanded ?? false)
 *   - Switching messageId resets the user state
 *
 * Expanded rendering:
 *   - Streaming: incremental markdown split into stable blocks, see StreamingReasoningMarkdown
 *   - Finished: full markdown
 *
 * Accessibility:
 *   - The header is a button with aria-expanded / aria-controls bound
 *   - prefers-reduced-motion turns off the pulse and the chevron transition
 *   - RTL mirrors the chevron (handled in CSS)
 */

import { memo, useEffect, useRef, useState, useMemo } from 'react';
import { useTranslations } from 'next-intl';
import { reasoningTail } from '../../lib/utils/reasoning-preview';
import { ReasoningBlockSplitter } from '../../lib/utils/reasoning-stream-blocks';
import { MarkdownRenderer } from './MarkdownRenderer';
import styles from './ReasoningBlock.module.css';

interface ReasoningBlockProps {
  reasoningText: string;
  isStreaming: boolean;
  durationMs?: number;
  messageId: string;
}

/**
 * Duration formatting:
 *   - < 1s → "<1s"
 *   - 1-59s → "{n}s"
 *   - ≥ 60s → "{m}m {s}s"
 */
function formatDuration(ms: number): string {
  if (ms < 1000) return '<1s';
  const totalSec = Math.round(ms / 1000);
  if (totalSec < 60) return `${totalSec}s`;
  const m = Math.floor(totalSec / 60);
  const s = totalSec % 60;
  return `${m}m ${s}s`;
}

/**
 * Markdown rendering for streaming reasoning while the block is expanded.
 *
 * Handing the whole text to `<MarkdownRenderer isStreaming>` does not work here: the synchronous
 * react-markdown entry point builds a new processor and reparses everything on each render with
 * no internal caching, and reasoning text can run to tens of thousands of characters, so the cost
 * is O(n) per frame and O(n^2) overall. That is the pressure that makes this kind of view fall
 * back to a bare `<pre>`, at the price of showing the user raw `**`.
 *
 * The answer is to amortize the cost rather than avoid markdown:
 * - Sealed paragraphs (cut incrementally by `ReasoningBlockSplitter`, never rescanned and never
 *   split inside a code fence) each go to a memoized `StableBlock`. Once a block is final it stops
 *   changing, React.memo skips it, and every block is parsed exactly once in its life.
 * - The active tail goes through `isStreaming`, where `prepareStreamingMarkdown` turns unclosed
 *   `**`, backticks, links and LaTeX into a plain-text tail, so unclosed syntax never reaches the
 *   screen as a raw marker. The tail reparses every frame, but it is only one paragraph.
 *
 * Total cost is O(total input). Per-character fade-in stays off: it costs one `<span>` per
 * character, which a reasoning stream cannot carry.
 */
const StableBlock = memo(function StableBlock({ content }: { content: string }) {
  return <MarkdownRenderer content={content} isStreaming={false} enableCharFade={false} />;
});

function StreamingReasoningMarkdown({ text, messageId }: { text: string; messageId: string }) {
  const splitterRef = useRef<ReasoningBlockSplitter | null>(null);
  const splitterMessageIdRef = useRef(messageId);
  if (splitterRef.current === null) splitterRef.current = new ReasoningBlockSplitter();
  if (splitterMessageIdRef.current !== messageId) {
    // The component instance is reused for another message: blocks from the previous one must not leak in
    splitterMessageIdRef.current = messageId;
    splitterRef.current.reset();
  }
  // Stateful but idempotent: advancing on the same text has no side effect (it only moves
  // forward), and input that is not an extension of the last one rebuilds the splitter, so
  // StrictMode double invocation and concurrent rendering are both safe.
  const { blocks, tail } = splitterRef.current.advance(text);

  return (
    <>
      {blocks.map((block, index) => (
        // Index keys are safe: the block list only appends, existing blocks are never reordered or rewritten
        <StableBlock key={index} content={block} />
      ))}
      {tail ? <MarkdownRenderer content={tail} isStreaming enableCharFade={false} /> : null}
    </>
  );
}

function ChevronIcon({ expanded }: { expanded: boolean }) {
  return (
    <svg
      className={`${styles.chevron} ${expanded ? styles.chevronOpen : ''}`}
      width="12"
      height="12"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <polyline points="9 6 15 12 9 18" />
    </svg>
  );
}

function StreamingDot() {
  return <span className={styles.streamingDot} aria-hidden="true" />;
}

export const ReasoningBlock = memo(function ReasoningBlock({
  reasoningText,
  isStreaming,
  durationMs,
  messageId,
}: ReasoningBlockProps) {
  const t = useTranslations('pages.chat.thinkingBlock');

  // userExpanded: undefined = not interacted with (collapsed by default); true/false = explicit user toggle
  const [userExpanded, setUserExpanded] = useState<boolean | undefined>(undefined);

  // Reset when messageId changes (switching conversations, or state reused across messages)
  useEffect(() => {
    setUserExpanded(undefined);
  }, [messageId]);

  // Never auto-expands; the block opens only when the user clicks
  const effectiveExpanded = userExpanded ?? false;

  // reasoningTail returning an empty string means this frame's last line holds only markdown
  // skeleton (`**`, `###`, `|---|`) or whitespace, with nothing readable in it. Keep the previous
  // frame instead of rendering the empty string: otherwise the preview line flashes blank in the
  // instant where the model emits markers on a new line and the body only in the next chunk.
  // Writing the ref is idempotent (same input, same result), so StrictMode double invocation is safe.
  const rawTail = useMemo(() => reasoningTail(reasoningText), [reasoningText]);
  const lastTailRef = useRef('');
  const lastTailMessageIdRef = useRef(messageId);
  if (lastTailMessageIdRef.current !== messageId) {
    // The component instance is reused for another message: the previous preview must not leak into the first frame of the new one
    lastTailMessageIdRef.current = messageId;
    lastTailRef.current = '';
  }
  if (rawTail) lastTailRef.current = rawTail;
  const tail = rawTail || lastTailRef.current;

  // Header copy:
  //   Streaming -> "Thinking"
  //   Finished with a duration -> "Thought for {duration}"
  //   Finished without a duration (older messages) -> "Show thinking" collapsed, "Hide thinking" expanded
  const headerLabel = useMemo(() => {
    if (isStreaming) return t('thinking');
    if (durationMs !== undefined) return t('thoughtFor', { duration: formatDuration(durationMs) });
    return effectiveExpanded ? t('hide') : t('show');
  }, [isStreaming, durationMs, effectiveExpanded, t]);

  const ariaLabel = effectiveExpanded ? t('hide') : t('show');

  const contentId = `reasoning-${messageId}`;
  const containerClass = `${styles.container} ${isStreaming ? styles.streaming : styles.done}`;

  return (
    <section className={containerClass} aria-label={ariaLabel}>
      <button
        type="button"
        className={styles.headerBtn}
        onClick={() => setUserExpanded(!effectiveExpanded)}
        aria-expanded={effectiveExpanded}
        aria-controls={contentId}
        aria-label={ariaLabel}
      >
        {isStreaming && <StreamingDot />}
        <ChevronIcon expanded={effectiveExpanded} />
        <span className={styles.headerLabel}>{headerLabel}</span>
      </button>
      <div id={contentId} className={styles.contentWrap}>
        {effectiveExpanded ? (
          isStreaming ? (
            // Expanded and streaming: the same markdown rendering as the finished state, so the
            // user never sees a raw `**`. The stable-block splitting in StreamingReasoningMarkdown
            // keeps the cost at O(total input); see that component.
            <div className={styles.contentMarkdown}>
              <StreamingReasoningMarkdown text={reasoningText} messageId={messageId} />
            </div>
          ) : (
            // Expanded and finished: full markdown
            <div className={styles.contentMarkdown}>
              <MarkdownRenderer content={reasoningText} isStreaming={false} enableCharFade={false} />
            </div>
          )
        ) : (
          // Collapsed: a single line of reasoningTail, refreshed as new chunks arrive while streaming
          <div className={styles.contentTail} aria-hidden="true">
            {tail}
          </div>
        )}
      </div>
    </section>
  );
});

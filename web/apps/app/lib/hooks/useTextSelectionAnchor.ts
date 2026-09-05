'use client';

import { useEffect, useState } from 'react';
import type { QuoteContentKind } from '@oriveo/shared';
import { rangeTextWithMathSource, selectionTextWithMathSource } from '../utils/selection-math';

export interface TextSelectionAnchor {
  messageId: string;
  text: string;
  contentKind: QuoteContentKind;
  leadingText: string;
  trailingText: string;
  contextReliable: boolean;
  x: number;
  y: number;
}

function closestQuoteBlock(node: Node | null, message: HTMLElement): HTMLElement | null {
  const element = node instanceof Element ? node : node?.parentElement;
  const block = element?.closest<HTMLElement>('[data-quote-block]') ?? null;
  return block && message.contains(block) ? block : null;
}

function quoteBlockKind(block: HTMLElement): QuoteContentKind {
  return block.dataset.quoteBlock === 'code' || block.dataset.quoteBlock === 'table'
    ? block.dataset.quoteBlock
    : 'prose';
}

function leafQuoteBlocks(message: HTMLElement): HTMLElement[] {
  const all = Array.from(message.querySelectorAll<HTMLElement>('[data-quote-block]'));
  return all.filter((candidate) => !all.some(
    (other) => other !== candidate && candidate.contains(other),
  ));
}

function blockText(block: HTMLElement): string {
  const range = document.createRange();
  range.selectNodeContents(block);
  return rangeTextWithMathSource(range).trim();
}

export interface QuoteSelectionSnapshot {
  selectedText: string;
  contentKind: QuoteContentKind;
  leadingText: string;
  trailingText: string;
  contextReliable: boolean;
}

/** Returns selected-only when the DOM offers no reliable way to locate a semantic block; context is never guessed. */
export function captureRangeQuoteSelection(range: Range, message: HTMLElement): QuoteSelectionSnapshot {
  const selectedText = rangeTextWithMathSource(range).trim() || range.toString().trim();
  const startBlock = closestQuoteBlock(range.startContainer, message);
  const endBlock = closestQuoteBlock(range.endContainer, message);
  if (!selectedText || !startBlock || !endBlock) {
    return { selectedText, contentKind: 'prose', leadingText: '', trailingText: '', contextReliable: false };
  }

  const blocks = leafQuoteBlocks(message);
  const startIndex = blocks.indexOf(startBlock);
  const endIndex = blocks.indexOf(endBlock);
  if (startIndex < 0 || endIndex < startIndex) {
    return { selectedText, contentKind: 'prose', leadingText: '', trailingText: '', contextReliable: false };
  }

  const startPrefix = document.createRange();
  startPrefix.selectNodeContents(startBlock);
  try {
    startPrefix.setEnd(range.startContainer, range.startOffset);
  } catch {
    return { selectedText, contentKind: 'prose', leadingText: '', trailingText: '', contextReliable: false };
  }
  const endSuffix = document.createRange();
  endSuffix.selectNodeContents(endBlock);
  try {
    endSuffix.setStart(range.endContainer, range.endOffset);
  } catch {
    return { selectedText, contentKind: 'prose', leadingText: '', trailingText: '', contextReliable: false };
  }

  const kinds = new Set(blocks.slice(startIndex, endIndex + 1).map(quoteBlockKind));
  const contentKind: QuoteContentKind = kinds.size === 1 ? quoteBlockKind(startBlock) : 'prose';
  // Whitespace at the selection boundary is part of the snapshot structure and must not be
  // trimmed, or the preview and the provider-side reassembly glue `const ` + `value` into `constvalue`.
  let leadingText = rangeTextWithMathSource(startPrefix);
  let trailingText = rangeTextWithMathSource(endSuffix);

  // Prose additionally carries one non-empty adjacent semantic block on each side; empty separator elements have no data-quote-block and do not count against the budget.
  if (contentKind === 'prose') {
    const previous = blocks.slice(0, startIndex).reverse().map(blockText).find(Boolean);
    const next = blocks.slice(endIndex + 1).map(blockText).find(Boolean);
    if (previous) leadingText = leadingText ? `${previous}\n\n${leadingText}` : previous;
    if (next) trailingText = trailingText ? `${trailingText}\n\n${next}` : next;
  }

  return { selectedText, contentKind, leadingText, trailingText, contextReliable: true };
}

function closestMessageElement(node: Node | null): HTMLElement | null {
  const element = node instanceof Element ? node : node?.parentElement;
  return element?.closest<HTMLElement>('[data-message-id]') ?? null;
}

export function useTextSelectionAnchor(): TextSelectionAnchor | null {
  const [anchor, setAnchor] = useState<TextSelectionAnchor | null>(null);

  useEffect(() => {
    let timer: number | undefined;

    const update = () => {
      if (timer !== undefined) window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        const selection = window.getSelection();
        if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
          setAnchor(null);
          return;
        }
        // Serialization that keeps formula source (KaTeX annotations restored to $..$ / $$..$$); an empty result falls back to toString
        const text = (selectionTextWithMathSource(selection).trim() || selection.toString().trim());
        if (!text) {
          setAnchor(null);
          return;
        }
        const range = selection.getRangeAt(0);
        const startMessage = closestMessageElement(range.startContainer);
        const endMessage = closestMessageElement(range.endContainer);
        // A selection spanning messages is unreliable: do not offer Ask, and do not mistake the starting message for the whole source.
        const message = startMessage && endMessage && startMessage === endMessage ? startMessage : null;
        if (!message?.dataset.messageId) {
          setAnchor(null);
          return;
        }
        const rect = range.getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) {
          setAnchor(null);
          return;
        }
        const snapshot = captureRangeQuoteSelection(range, message);
        setAnchor({
          messageId: message.dataset.messageId,
          text: snapshot.selectedText || text,
          contentKind: snapshot.contentKind,
          leadingText: snapshot.leadingText,
          trailingText: snapshot.trailingText,
          contextReliable: snapshot.contextReliable,
          x: rect.left + rect.width / 2,
          y: Math.max(10, rect.top - 12),
        });
      }, 40);
    };

    const clear = () => setAnchor(null);
    document.addEventListener('selectionchange', update);
    document.addEventListener('mouseup', update);
    document.addEventListener('touchend', update);
    window.addEventListener('scroll', clear, true);
    return () => {
      if (timer !== undefined) window.clearTimeout(timer);
      document.removeEventListener('selectionchange', update);
      document.removeEventListener('mouseup', update);
      document.removeEventListener('touchend', update);
      window.removeEventListener('scroll', clear, true);
    };
  }, []);

  return anchor;
}

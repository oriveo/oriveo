import type { Note } from '@oriveo/shared';
import { copyToClipboard } from '../../utils/clipboard';

function noteTitle(note: Note, untitled: string): string {
  return note.title.trim() || untitled;
}

function noteDate(note: Note): string {
  const date = new Date(note.createdAt);
  if (Number.isNaN(date.getTime())) return '';
  return date.toISOString().slice(0, 10);
}

function sourceLine(note: Note): string | null {
  if (note.captureKind === 'blank') return null;
  const parts = [note.sourceModelName, note.sourceProviderName, noteDate(note)]
    .filter((part): part is string => typeof part === 'string' && part.length > 0);
  if (parts.length === 0) return null;
  return `Source: ${parts.join(' - ')}`;
}

export function buildNoteMarkdown(note: Note, untitled: string): string {
  const sections: string[] = [`# ${noteTitle(note, untitled)}`];

  if (note.userNote?.trim()) {
    sections.push(note.userNote.trim().split('\n').map((line) => `> ${line}`).join('\n'));
  }

  if (note.tags.length > 0) {
    sections.push(`Tags: ${note.tags.join(', ')}`);
  }

  if (note.body.trim()) {
    sections.push(note.body.trim());
  }

  const source = sourceLine(note);
  const sourceParts = [source, note.sourcePrompt ? `Prompt: ${note.sourcePrompt}` : null]
    .filter((part): part is string => Boolean(part));
  if (sourceParts.length > 0) {
    sections.push(sourceParts.join('\n'));
  }

  return `${sections.join('\n\n')}\n`;
}

export function sanitizeNoteFilenamePart(value: string): string {
  const cleaned = value
    .replace(/[\/\\:*?"<>|]+/g, '-')
    .replace(/[\r\n]+/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/-+/g, '-')
    .trim()
    .replace(/^-+|-+$/g, '');
  return cleaned.slice(0, 80);
}

export function buildNoteMarkdownFilename(note: Note, untitled: string): string {
  const title = sanitizeNoteFilenamePart(noteTitle(note, untitled)) || untitled;
  const date = noteDate(note);
  return `${title}${date ? `-${date}` : ''}.md`;
}

export function downloadMarkdown(markdown: string, filename: string): void {
  const blob = new Blob([markdown], { type: 'text/markdown;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = filename;
  document.body.appendChild(anchor);
  anchor.click();
  document.body.removeChild(anchor);
  URL.revokeObjectURL(url);
}

export function copyNoteMarkdown(note: Note, untitled: string): Promise<boolean> {
  return copyToClipboard(buildNoteMarkdown(note, untitled));
}

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fireEvent, render, screen, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Note } from '@oriveo/shared';
import { NoteCard } from './NoteCard';
import { NoteFolderList } from './NoteFolderList';
import { NoteSourceCard } from './NoteSourceCard';
import { NoteTagEditor } from './NoteTagEditor';
import { NoteTrashView } from './NoteTrashView';

const mocks = vi.hoisted(() => ({
  emptyTrash: vi.fn(),
  deleteNoteFolder: vi.fn(),
  renameNoteFolder: vi.fn(),
  updateNoteFolderColor: vi.fn(),
  restoreNote: vi.fn(),
  showToast: vi.fn(),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, params?: Record<string, unknown>) => {
    const messages: Record<string, string> = {
      'source.title': 'Source',
      'source.blank': 'This note was created manually.',
      'source.prompt': 'Prompt',
      'source.backToConversation': 'Back to conversation',
      'source.crosscheck': 'Cross-check',
      'folders.delete': 'Delete folder',
      'folders.deleteMessage': `Delete ${params?.name ?? 'folder'}?`,
      'folders.edit': 'Edit folder',
      'folders.name': 'Folder name',
      'folders.rename': 'Rename',
      'folders.uncategorized': 'Uncategorized',
      'actions.cancel': 'Cancel',
      'actions.save': 'Save',
      changeColor: 'Change color',
      'trash.emptyTitle': 'Trash is empty',
      'trash.emptyDescription': 'Deleted notes will appear here.',
      'trash.title': 'Trash',
      'trash.description': `${params?.count ?? 0} deleted notes`,
      'trash.empty': 'Empty trash',
      'trash.emptyConfirmTitle': 'Empty trash?',
      'trash.emptyConfirmMessage': 'Deleted notes will be permanently removed and cannot be restored.',
      'trash.restore': 'Restore',
      'toast.restored': 'Note restored',
      'toast.trashEmptied': 'Trash emptied',
      'untitled': 'Untitled note',
      'empty.body': 'Nothing written yet.',
      'labels.pinned': 'Pinned',
    };
    return messages[key] ?? key;
  },
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({
    children,
    onClick,
    disabled,
  }: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
  }) => (
    <button type="button" onClick={onClick} disabled={disabled}>
      {children}
    </button>
  ),
  EmptyState: ({
    title,
    description,
  }: {
    title: string;
    description: string;
  }) => (
    <div>
      <h2>{title}</h2>
      <p>{description}</p>
    </div>
  ),
  Dialog: ({ open, children }: { open: boolean; children: React.ReactNode }) => (
    open ? <div role="dialog">{children}</div> : null
  ),
}));

vi.mock('../ProviderIcon', () => ({
  ProviderIcon: ({ kind, providerName }: { kind: string; providerName?: string }) => (
    <span data-testid="provider-icon" data-kind={kind} data-provider-name={providerName ?? ''} />
  ),
}));

vi.mock('../../providers/StoreProvider', () => ({
  getVanillaStore: () => ({ id: 'store' }),
}));

vi.mock('../../lib/core/note-ops', () => ({
  deleteNoteFolder: (...args: unknown[]) => mocks.deleteNoteFolder(...args),
  emptyTrash: (...args: unknown[]) => mocks.emptyTrash(...args),
  renameNoteFolder: (...args: unknown[]) => mocks.renameNoteFolder(...args),
  updateNoteFolderColor: (...args: unknown[]) => mocks.updateNoteFolderColor(...args),
  restoreNote: (...args: unknown[]) => mocks.restoreNote(...args),
}));

vi.mock('../Toast', () => ({
  showToast: (...args: unknown[]) => mocks.showToast(...args),
}));

function makeNote(overrides: Partial<Note> = {}): Note {
  return {
    id: 'note-1',
    title: 'Vector recall',
    titleSource: 'manual',
    body: 'Use tags first.',
    tags: ['vector'],
    captureKind: 'fullAnswer',
    sourceConversationId: 'conv-1',
    sourceMessageId: 'msg-1',
    sourceModelName: 'GPT-5',
    sourceProviderKind: 'openAI',
    sourceProviderName: 'OpenAI',
    sourcePrompt: 'How should recall work?',
    createdAt: '2026-06-19T09:00:00.000Z',
    updatedAt: '2026-06-19T10:00:00.000Z',
    ...overrides,
  };
}

function readAppFile(relativePath: string): string {
  return readFileSync(join(process.cwd(), relativePath), 'utf8');
}

function cssClassBlock(source: string, className: string): string {
  const match = source.match(new RegExp(`\\.${className}\\s*\\{([\\s\\S]*?)\\n\\}`));
  if (!match) throw new Error(`Missing .${className}`);
  return match[1];
}

function mediaBlock(source: string, query: string): string {
  const marker = `@media ${query} {`;
  const start = source.indexOf(marker);
  expect(start).toBeGreaterThanOrEqual(0);
  return source.slice(start);
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe('Note source UI contract', () => {
  it('renders the list card source model badge from note snapshots and localizes empty titles at render time', () => {
    const onOpen = vi.fn();

    render(<NoteCard note={makeNote({ title: '' })} onOpen={onOpen} />);

    expect(screen.getByText('Untitled note')).toBeTruthy();
    expect(screen.getByText('GPT-5')).toBeTruthy();
    expect(screen.getByTestId('provider-icon').getAttribute('data-kind')).toBe('openAI');

    fireEvent.click(screen.getByRole('button', { name: /Untitled note/ }));
    expect(onOpen).toHaveBeenCalledWith('note-1');
  });

  it('does not open the note when deleting from the card with keyboard', () => {
    const onOpen = vi.fn();
    const onDelete = vi.fn();

    render(<NoteCard note={makeNote()} onOpen={onOpen} onDelete={onDelete} />);

    const deleteButton = screen.getByRole('button', { name: 'actions.delete' });
    fireEvent.keyDown(deleteButton, { key: 'Enter' });
    fireEvent.click(deleteButton);

    expect(onDelete).toHaveBeenCalledWith('note-1');
    expect(onOpen).not.toHaveBeenCalled();
  });

  it('renders cross-check notes without exposing the internal Original answer heading in card preview', () => {
    render(
      <NoteCard
        note={makeNote({
          title: 'Second opinion',
          body: '## Original answer\n\nInternal source answer\n\n## Cross-check (GPT-5)\n\nUse a smaller retry window.',
          bodySnapshot: 'Internal source answer',
        })}
        onOpen={vi.fn()}
      />,
    );

    expect(screen.getByText('Use a smaller retry window.')).toBeTruthy();
    expect(screen.queryByText(/Original answer/i)).toBeNull();
    expect(screen.queryByText(/Internal source answer/i)).toBeNull();
  });

  it('keeps the prompt and exposes one primary back-to-conversation action when the source exists', () => {
    const onJump = vi.fn();
    const onCrosscheck = vi.fn();

    render(
      <NoteSourceCard
        note={makeNote()}
        linkState={{ available: true, conversationId: 'conv-1' }}
        onJump={onJump}
        onCrosscheck={onCrosscheck}
      />,
    );

    // The source model byline lives in the detail masthead (detailSourceStrip in NoteDetail); the source card keeps only the original question and the actions.
    expect(screen.getByText('How should recall work?')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Jump to source/ })).toBeNull();
    expect(screen.queryByRole('button', { name: /Continue asking/ })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: /Back to conversation/ }));
    fireEvent.click(screen.getByRole('button', { name: /Cross-check/ }));

    expect(onJump).toHaveBeenCalledTimes(1);
    expect(onCrosscheck).toHaveBeenCalledTimes(1);
  });

  it('keeps the unified source action enabled when only the source anchor is available', () => {
    const onJump = vi.fn();

    render(
      <NoteSourceCard
        note={makeNote({
          captureKind: 'blank',
          sourceModelName: undefined,
          sourceProviderKind: undefined,
          sourceProviderName: undefined,
          sourcePrompt: undefined,
        })}
        linkState={{ available: true, conversationId: 'conv-1' }}
        onJump={onJump}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: /Back to conversation/ }));
    expect(screen.queryByRole('button', { name: /Continue asking/ })).toBeNull();
    expect(onJump).toHaveBeenCalledTimes(1);
  });

  it('does not render a return action when a legacy source snapshot has no conversation anchor', () => {
    render(
      <NoteSourceCard
        note={makeNote({ sourceConversationId: undefined })}
        linkState={{ available: false, reason: 'noSource' }}
        onJump={vi.fn()}
        onCrosscheck={vi.fn()}
      />,
    );

    expect(screen.getByText('How should recall work?')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Back to conversation/ })).toBeNull();
    expect(screen.queryByRole('button', { name: /Original conversation deleted/ })).toBeNull();
    expect(screen.getByRole('button', { name: /Cross-check/ })).toBeTruthy();
  });

  it('renders no source section for manually-created notes with no source', () => {
    const { container } = render(
      <NoteSourceCard
        note={makeNote({ captureKind: 'blank', sourceModelName: undefined, sourceProviderKind: undefined, sourceProviderName: undefined, sourcePrompt: undefined })}
        linkState={{ available: false, reason: 'noSource' }}
        onJump={vi.fn()}
      />,
    );

    // A blank note with no source renders no bare "source" block at all, and offers no link.
    expect(container.firstChild).toBeNull();
    expect(screen.queryByRole('button', { name: /Back to conversation/ })).toBeNull();
  });
});

describe('Note trash UI contract', () => {
  it('restores a trashed note and only empties trash after confirmation', () => {
    render(
      <NoteTrashView
        notes={[makeNote({ deletedAt: '2026-06-19T11:00:00.000Z' })]}
        onOpenNote={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Restore' }));
    expect(mocks.restoreNote).toHaveBeenCalledWith(expect.anything(), 'note-1');
    expect(mocks.showToast).toHaveBeenCalledWith('Note restored', 3000, undefined, 'success');

    fireEvent.click(screen.getByRole('button', { name: 'Empty trash' }));
    expect(mocks.emptyTrash).not.toHaveBeenCalled();
    expect(screen.getByRole('dialog')).toBeTruthy();
    expect(screen.getByText('Deleted notes will be permanently removed and cannot be restored.')).toBeTruthy();

    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Empty trash' }));
    expect(mocks.emptyTrash).toHaveBeenCalledWith(expect.anything());
    expect(mocks.showToast).toHaveBeenCalledWith('Trash emptied', 3000, undefined, 'success');
  });
});

describe('Note detail tag editor contract', () => {
  it('offers existing tags that are not already on the note and adds them with one click', () => {
    const onChange = vi.fn();

    render(
      <NoteTagEditor
        tags={['vector']}
        availableTags={['vector', 'llm', 'research']}
        onChange={onChange}
      />,
    );

    expect(screen.queryByRole('button', { name: '# vector' })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: '# llm' }));
    expect(onChange).toHaveBeenCalledWith(['vector', 'llm']);
  });

  it('keeps tags above the body panel in the detail page source order', () => {
    const source = readAppFile('components/notes/NoteDetail.tsx');
    const tagsIndex = source.indexOf('<section className={styles.inlineTagsSection}');
    const bodyIndex = source.indexOf('<section className={styles.detailPanel}>');

    expect(tagsIndex).toBeGreaterThan(0);
    expect(bodyIndex).toBeGreaterThan(0);
    expect(tagsIndex).toBeLessThan(bodyIndex);
  });
});

describe('Note folder management UI contract', () => {
  it('selects uncategorized notes as a real folder filter', () => {
    const onSelectFolder = vi.fn();

    render(
      <NoteFolderList
        folders={[]}
        notes={[
          makeNote({ id: 'uncategorized-1', noteFolderID: undefined }),
          makeNote({ id: 'foldered-1', noteFolderID: 'folder-1' }),
        ]}
        activeFolderId={null}
        onSelectFolder={onSelectFolder}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: /Uncategorized/ }));
    expect(onSelectFolder).toHaveBeenCalledWith('__uncategorized__');
  });

  it('keeps the uncategorized folder filter visible even when empty', () => {
    render(
      <NoteFolderList
        folders={[]}
        notes={[makeNote({ id: 'foldered-1', noteFolderID: 'folder-1' })]}
        activeFolderId={null}
        onSelectFolder={vi.fn()}
      />,
    );

    expect(screen.getByRole('button', { name: /Uncategorized/ })).toBeTruthy();
  });

  it('edits (rename + recolor) and deletes folders from the folder list', () => {
    render(
      <NoteFolderList
        folders={[{
          id: 'folder-1',
          name: 'Research',
          sortOrder: 1000,
          colorTag: 'blue',
          createdAt: '2026-06-19T00:00:00.000Z',
          updatedAt: '2026-06-19T00:00:00.000Z',
        }]}
        notes={[]}
        activeFolderId={null}
        onSelectFolder={vi.fn()}
      />,
    );

    // Rename and recolor share one Edit dialog: open the edit entry, change the name, pick a color, and one save applies both.
    fireEvent.click(screen.getByRole('button', { name: /Edit folder/ }));
    const input = screen.getByDisplayValue('Research') as HTMLInputElement;
    fireEvent.change(input, { target: { value: 'Reading' } });
    const dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: 'red' }));
    fireEvent.click(within(dialog).getByRole('button', { name: 'Save' }));
    expect(mocks.renameNoteFolder).toHaveBeenCalledWith(expect.anything(), 'folder-1', 'Reading');
    expect(mocks.updateNoteFolderColor).toHaveBeenCalledWith(expect.anything(), 'folder-1', 'red');

    fireEvent.click(screen.getByRole('button', { name: /Delete folder/ }));
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Delete folder' }));
    expect(mocks.deleteNoteFolder).toHaveBeenCalledWith(expect.anything(), 'folder-1');
  });
});

describe('Notes responsive and theme style contracts', () => {
  it('keeps the notes page status lightweight and source-led instead of nested admin cards', () => {
    const css = readAppFile('components/notes/Notes.module.css');

    expect(cssClassBlock(css, 'statusChip')).toContain('border-radius: 999px;');
    expect(cssClassBlock(css, 'statusChip')).toContain('max-width: 360px;');
    expect(cssClassBlock(css, 'notesGrid')).toContain('grid-template-columns: minmax(184px, 220px) minmax(0, 1fr);');
    expect(cssClassBlock(css, 'folderPane')).toContain('border: 0;');
    // Entries are document cover cards: no numbering and no left color bar, with the source color
    // used only as a faint ambience and a source token. Tags use their own --o-note-tag-* golden
    // brown tokens rather than borrowing the theme accent, so note tags have their own visual identity.
    expect(cssClassBlock(css, 'listStack')).not.toContain('counter-reset: noteidx;');
    expect(cssClassBlock(css, 'noteCard')).toContain('border-radius: 26px;');
    expect(cssClassBlock(css, 'noteCard')).toContain('padding: 18px;');
    const noteCardBefore = cssClassBlock(css, 'noteCard::before');
    expect(noteCardBefore).toContain("content: '';");
    // ::before is a 140px circular ambient glow (blur plus 13% of the source color) rather than a
    // 72px cover band at the top, so the pinned value changed with the semantics.
    expect(noteCardBefore).toContain('height: 140px;');
    expect(noteCardBefore).toContain('border-radius: 50%;');
    expect(noteCardBefore).toContain('filter: blur(28px);');
    // ::after is a 1px gradient stroke border, cut out with a mask, rather than a radial highlight.
    const noteCardAfter = cssClassBlock(css, 'noteCard::after');
    expect(noteCardAfter).toContain('linear-gradient(');
    expect(noteCardAfter).toContain('mask-composite: exclude;');
    expect(noteCardBefore).not.toContain('width: 3px');
    expect(noteCardBefore).not.toContain('counter(noteidx');
    expect(cssClassBlock(css, 'notePreview')).toContain('-webkit-line-clamp: 3;');
    expect(cssClassBlock(css, 'noteTagChip svg')).toContain('var(--o-note-tag-icon)');
    // The byline badge uses the brand source token instead of bare small-caps text.
    expect(cssClassBlock(css, 'sourceBadge')).toContain('border-radius: 12px;');
    expect(cssClassBlock(css, 'sourceBadge')).toContain('var(--note-source-color)');
  });

  it('shows the notes page purpose line with the notebook brand icon', () => {
    const page = readAppFile('app/notes/NotesPage.tsx');
    const css = readAppFile('components/notes/Notes.module.css');

    // The same NotebookPen icon as the home entry card and the sidebar entry. The plus sign belongs
    // only to the "save as note" action button, not to the page identity.
    expect(page).toContain('NotebookPen');
    expect(page).not.toContain('notePurposePlus');
    expect(page).toContain('notePurposeLine');
    expect(page).toContain('notePurposeIcon');
    expect(cssClassBlock(css, 'notePurposeLine')).toContain('inline-flex');
    expect(cssClassBlock(css, 'notePurposeIcon')).toContain('var(--o-primary)');
  });

  it('promotes source and reading controls at the top of the detail page', () => {
    const css = readAppFile('components/notes/Notes.module.css');
    const source = readAppFile('components/notes/NoteDetail.tsx');

    // The hero is a manuscript masthead (transparent, no box, large title), and the source model byline uses detailSourceModel with the brand color.
    expect(cssClassBlock(css, 'detailHero')).toContain('background: transparent;');
    expect(cssClassBlock(css, 'detailTitleInput')).toContain('font-size: clamp(30px, 3.4vw, 34px);');
    expect(cssClassBlock(css, 'detailSourceModel')).toContain('color: var(--note-source-color);');
    // The content card is not height-limited with inner scrolling: the body expands fully and the
    // whole page scrolls, matching the manuscript masthead. This pins the card shape itself so it
    // cannot regress to scrolling inside the card.
    expect(cssClassBlock(css, 'detailContentCard')).toContain('border-radius: 20px;');
    expect(cssClassBlock(css, 'detailContentCard')).toContain('overflow: hidden;');
    expect(cssClassBlock(css, 'detailContentCard')).not.toContain('max-height:');
    expect(cssClassBlock(css, 'detailContentTabs')).toContain('width: 100%;');
    expect(cssClassBlock(css, 'detailContentTabs')).toContain('grid-template-columns: repeat(2, minmax(0, 1fr));');
    expect(cssClassBlock(css, 'sourceActionBadgeIcon')).toContain('border-radius: 999px;');
    expect(cssClassBlock(css, 'inlineTagsScroller')).toContain('overflow-x: auto;');
    expect(cssClassBlock(css, 'tagChip')).toContain('border-radius: 999px;');
    expect(cssClassBlock(css, 'tagChip')).toContain('var(--o-note-tag-bg)');
    expect(cssClassBlock(css, 'tagChip')).toContain('var(--o-note-tag-text)');
    expect(cssClassBlock(css, 'tagChipIcon')).toContain('var(--o-note-tag-icon)');
    expect(source).toContain('<Tag size={11} aria-hidden className={styles.tagChipIcon} />');
    expect(source).not.toContain('className={styles.tagHash}');
    expect(source).toContain('extractCrosscheckDisplayBody');
    expect(source).toContain("setContentPane('snapshot')");
    expect(source).not.toContain('<details className={styles.snapshotDisclosure}>');
  });

  it('keeps notes surfaces tokenized for dark mode instead of module-level dark overrides', () => {
    const css = readAppFile('components/notes/Notes.module.css');

    expect(css).toContain('var(--o-surface)');
    expect(css).toContain('var(--o-bg)');
    expect(css).toContain('var(--o-text)');
    expect(css).not.toContain(":global(html[data-theme='dark'])");
    expect(css).not.toContain('[data-theme=dark]');
  });

  it('collapses notes layout and source metadata for narrow mobile viewports', () => {
    const css = readAppFile('components/notes/Notes.module.css');
    const mobile = mediaBlock(css, '(max-width: 767px)');

    expect(mobile).toContain('.pageShell,');
    expect(mobile).toContain('padding: 16px;');
    expect(mobile).toContain('.notesGrid');
    expect(mobile).toContain('grid-template-columns: minmax(0, 1fr);');
    expect(mobile).toContain('.detailHeader,');
    expect(mobile).toContain('flex-direction: column;');
    expect(cssClassBlock(css, 'sourceBadgeText')).toContain('text-overflow: ellipsis;');
  });

  it('keeps related-note chips and cross-check sheet usable on 360px screens', () => {
    const composerCss = readAppFile('components/chat/InputComposer.module.css');
    const crosscheckCss = readAppFile('components/chat/CrosscheckSheet.module.css');
    const composerMobile = mediaBlock(composerCss, '(max-width: 767px)');
    const crosscheckMobile = mediaBlock(crosscheckCss, '(max-width: 720px)');

    expect(cssClassBlock(composerCss, 'relatedNoteTitle')).toContain('max-width: min(260px, 48vw);');
    expect(composerMobile).toContain('.composer');
    expect(composerMobile).toContain('max-width: 100%;');
    expect(crosscheckMobile).toContain('.compareGrid');
    expect(crosscheckMobile).toContain('grid-template-columns: 1fr;');
    expect(crosscheckMobile).toContain('align-items: stretch;');
  });
});

import type { ReactNode } from 'react';
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { MemoryItems, type MemoryItem } from '@oriveo/core/context/memory-items';
import type { MemoryItemRepository } from '../../../lib/core/memory/memory-item-repository';
import { requestMemoryOrganize, type MemoryModelCandidate } from '../../../lib/core/memory/memory-organize';
import { MemoryOrganizeDialog } from './MemoryOrganizeDialog';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({ children, onClick, disabled }: { children: ReactNode; onClick?: () => void; disabled?: boolean }) => (
    <button type="button" onClick={onClick} disabled={disabled}>
      {children}
    </button>
  ),
  Dialog: ({ open, children }: { open: boolean; onClose?: () => void; children: ReactNode }) => (
    open ? <div role="dialog">{children}</div> : null
  ),
}));

// Model request stand-in: does not hit a real provider; the reply text goes to the organize dialog (which judges emptiness and hands it to the real organizeParse).
vi.mock('../../../lib/core/memory/memory-organize', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../lib/core/memory/memory-organize')>();
  return { ...actual, requestMemoryOrganize: vi.fn() };
});

const requestMock = vi.mocked(requestMemoryOrganize);

function replyWith(text: string) {
  requestMock.mockImplementation(async () => text);
}

const ORIGINAL: MemoryItem = MemoryItems.canonical({
  id: 'migrated-1',
  kind: 'fact',
  content: 'I write historical novels.\nPrefer answers in Arabic.\nLives in Cairo.',
  mutationId: 'mutation-migrated-1',
  deviceId: 'device-other',
  revision: 1,
  source: { type: 'migration' },
});

const CANDIDATE: MemoryModelCandidate = {
  provider: { id: 'relay-1', kind: 'relay', models: [{ id: 'model-1' }] } as unknown as Provider,
  model: { id: 'model-1' } as unknown as AIModel,
};

function fakeRepository() {
  const calls: string[] = [];
  const repository = {
    create: vi.fn(async (input: { kind: string; content: string }) => {
      calls.push(`create ${input.kind} ${input.content}`);
      return null;
    }),
    remove: vi.fn(async (id: string) => {
      calls.push(`remove ${id}`);
      return null;
    }),
  } as unknown as MemoryItemRepository;
  const runWrite = vi.fn(async (_context: string, op: (repo: MemoryItemRepository) => Promise<unknown>) => {
    await op(repository);
    return true;
  });
  return { calls, runWrite };
}

const REPLY = [
  'Here you go:',
  '[{"kind":"identity","content":"I write historical novels."},',
  '{"kind":"preference","content":"Prefer answers in Arabic."},',
  '{"kind":"unknown","content":"Lives in Cairo."}]',
].join('\n');

function rows(): HTMLElement[] {
  return within(screen.getByRole('list')).getAllByRole('listitem');
}

describe('MemoryOrganizeDialog', () => {
  beforeEach(() => {
    requestMock.mockReset();
  });

  it('proposes_and_saves_selected', async () => {
    replyWith(REPLY);
    const { calls, runWrite } = fakeRepository();
    const onClose = vi.fn();
    render(<MemoryOrganizeDialog item={ORIGINAL} candidates={[CANDIDATE]} runWrite={runWrite} onClose={onClose} />);

    expect(screen.getByRole('status').textContent).toBe('organizeLoading');
    expect(screen.queryByRole('button', { name: 'organizeSave' })).toBeNull();

    await waitFor(() => expect(rows()).toHaveLength(3));
    expect(requestMock).toHaveBeenCalledWith({
      provider: CANDIDATE.provider,
      model: CANDIDATE.model,
      content: ORIGINAL.content,
    });
    // Each row: category label + text; all selected by default; an unknown kind falls to fact (About me).
    expect(rows().map((row) => row.textContent)).toEqual([
      'groupAboutI write historical novels.',
      'groupPreferencesPrefer answers in Arabic.',
      'groupAboutLives in Cairo.',
    ]);
    expect(rows().every((row) => (within(row).getByRole('checkbox') as HTMLInputElement).checked)).toBe(true);
    expect((screen.getByRole('switch', { name: 'organizeKeepOriginal' }) as HTMLInputElement).checked).toBe(false);

    fireEvent.click(within(rows()[1]).getByRole('checkbox'));
    fireEvent.click(screen.getByRole('button', { name: 'organizeSave' }));

    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect(calls).toEqual([
      'create identity I write historical novels.',
      'create fact Lives in Cairo.',
      'remove migrated-1',
    ]);
  });

  it('keep_original_toggle', async () => {
    replyWith(REPLY);
    const { calls, runWrite } = fakeRepository();
    const onClose = vi.fn();
    render(<MemoryOrganizeDialog item={ORIGINAL} candidates={[CANDIDATE]} runWrite={runWrite} onClose={onClose} />);

    await waitFor(() => expect(rows()).toHaveLength(3));
    fireEvent.click(screen.getByRole('switch', { name: 'organizeKeepOriginal' }));
    fireEvent.click(screen.getByRole('button', { name: 'organizeSave' }));

    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect(calls).toEqual([
      'create identity I write historical novels.',
      'create preference Prefer answers in Arabic.',
      'create fact Lives in Cairo.',
    ]);
  });

  it('parse_empty_changes_nothing', async () => {
    replyWith('Sorry, I cannot split this.');
    const empty = fakeRepository();
    const view = render(
      <MemoryOrganizeDialog item={ORIGINAL} candidates={[CANDIDATE]} runWrite={empty.runWrite} onClose={() => undefined} />,
    );

    await waitFor(() => expect(screen.getByRole('alert').textContent).toBe('organizeEmpty'));
    expect(screen.queryByRole('button', { name: 'organizeSave' })).toBeNull();
    expect(screen.getByRole('button', { name: 'cancel' })).toBeTruthy();
    expect(empty.runWrite).not.toHaveBeenCalled();
    expect(empty.calls).toEqual([]);
    view.unmount();

    // Request failed: one failure line, only Cancel remains, no item is written; only the one given candidate is requested, with no switching to another provider.
    requestMock.mockClear();
    requestMock.mockRejectedValue(new Error('network down'));
    const failed = fakeRepository();
    render(
      <MemoryOrganizeDialog item={ORIGINAL} candidates={[CANDIDATE]} runWrite={failed.runWrite} onClose={() => undefined} />,
    );

    await waitFor(() => expect(screen.getByRole('alert').textContent).toBe('organizeFailed'));
    expect(requestMock).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('button', { name: 'organizeSave' })).toBeNull();
    expect(failed.runWrite).not.toHaveBeenCalled();
  });

  it('blank_reply_is_failure', async () => {
    // Reply empty after trim: counts as a failed request (organizeFailed), not "no items split out".
    replyWith('  \n\t ');
    const blank = fakeRepository();
    render(
      <MemoryOrganizeDialog item={ORIGINAL} candidates={[CANDIDATE]} runWrite={blank.runWrite} onClose={() => undefined} />,
    );

    await waitFor(() => expect(screen.getByRole('alert').textContent).toBe('organizeFailed'));
    expect(requestMock).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('button', { name: 'organizeSave' })).toBeNull();
    expect(screen.getByRole('button', { name: 'cancel' })).toBeTruthy();
    expect(blank.runWrite).not.toHaveBeenCalled();
  });

  it('no_model_hint', () => {
    const { runWrite } = fakeRepository();
    render(<MemoryOrganizeDialog item={ORIGINAL} candidates={[]} runWrite={runWrite} onClose={() => undefined} />);

    expect(screen.getByRole('alert').textContent).toBe('organizeNoModel');
    expect(screen.queryByRole('button', { name: 'organizeSave' })).toBeNull();
    expect(screen.getByRole('button', { name: 'cancel' })).toBeTruthy();
    expect(requestMock).not.toHaveBeenCalled();
    expect(runWrite).not.toHaveBeenCalled();
  });
});

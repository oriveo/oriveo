import type { ReactNode } from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { MemoryItems, type MemoryItem, type MemoryItemInput } from '@oriveo/core/context/memory-items';
import type { MemoryItemRepository } from '../../../lib/core/memory/memory-item-repository';
import { MemoryRawView } from './MemoryRawView';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) => (
    values ? `${key}:${JSON.stringify(values)}` : key
  ),
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({ children, onClick, disabled }: { children: ReactNode; onClick?: () => void; disabled?: boolean }) => (
    <button type="button" onClick={onClick} disabled={disabled}>
      {children}
    </button>
  ),
}));

let createdSeq = 0;
function item(id: string, kind: MemoryItemInput['kind'], content: string, extra: Partial<MemoryItemInput> = {}): MemoryItem {
  createdSeq += 1;
  return MemoryItems.canonical({
    id,
    kind,
    content,
    mutationId: `mutation-${id}`,
    deviceId: 'device-other',
    revision: 1,
    createdAt: `2026-10-${String(createdSeq).padStart(2, '0')}T00:00:00Z`,
    ...extra,
  });
}

// Repository stand-in: records write operations in call order.
function fakeRepository() {
  const calls: string[] = [];
  const repository = {
    update: vi.fn(async (id: string, patch: { content?: string }) => {
      calls.push(`update ${id} ${patch.content}`);
      return null;
    }),
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

function textbox(): HTMLTextAreaElement {
  return screen.getByRole('textbox', { name: 'rawView' }) as HTMLTextAreaElement;
}

describe('MemoryRawView', () => {
  beforeEach(() => {
    createdSeq = 0;
  });

  it('renders_active_only', () => {
    const removed = MemoryItems.tombstone({
      item: item('d1', 'identity', 'Deleted fact'),
      mutationId: 'mutation-del',
      deviceId: 'device-other',
      deletedAt: '2026-10-10T00:00:00Z',
    });
    const items = [
      item('a1', 'identity', 'I write historical novels'),
      item('p1', 'preference', 'Paused preference', { status: 'paused' }),
      removed,
      item('c1', 'preference', 'Conflicted copy', { status: 'conflicted', conflictGroupId: 'g1' }),
      item('e1', 'event', 'Went to the market', { layer: 'episodic' }),
      item('i1', 'instruction', 'Always answer in Arabic'),
    ];
    const { runWrite } = fakeRepository();
    render(<MemoryRawView items={items} runWrite={runWrite} onSaved={() => undefined} onCancel={() => undefined} />);

    expect(screen.getByText('rawViewHint')).toBeTruthy();
    expect(textbox().value).toBe(MemoryItems.rawRender(items));
    expect(textbox().value).toBe('I write historical novels\n---\nAlways answer in Arabic');
  });

  it('excludes_episodic', () => {
    const items = [
      item('a1', 'identity', 'I write historical novels'),
      item('e1', 'decision', 'Chose Postgres', { layer: 'episodic', occurredAt: '2026-10-05T00:00:00Z' }),
      item('e2', 'event', 'Moved to Cairo', { layer: 'episodic', status: 'paused' }),
      item('d1', 'decision', 'Semantic decision'),
    ];
    const { runWrite } = fakeRepository();
    render(<MemoryRawView items={items} runWrite={runWrite} onSaved={() => undefined} onCancel={() => undefined} />);

    expect(textbox().value).toBe('I write historical novels\n---\nSemantic decision');
    expect(textbox().value).not.toContain('Chose Postgres');
  });

  it('unchanged_saves_nothing', async () => {
    const items = [item('a1', 'identity', 'First'), item('a2', 'fact', 'Second')];
    const { calls, runWrite } = fakeRepository();
    const onSaved = vi.fn();
    render(<MemoryRawView items={items} runWrite={runWrite} onSaved={onSaved} onCancel={() => undefined} />);

    fireEvent.click(screen.getByRole('button', { name: 'rawViewSave' }));

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
    expect(runWrite).not.toHaveBeenCalled();
    expect(calls).toEqual([]);
  });

  it('edit_applies_ops', async () => {
    const items = [item('a1', 'identity', 'Alpha'), item('a2', 'fact', 'Beta'), item('a3', 'identity', 'Gamma')];
    const first = fakeRepository();
    const onSaved = vi.fn();
    const view = render(<MemoryRawView items={items} runWrite={first.runWrite} onSaved={onSaved} onCancel={() => undefined} />);

    // Alpha matches as-is; Beta2 takes the first remaining item; Gamma has no segment to match -> deleted.
    fireEvent.change(textbox(), { target: { value: 'Beta2\n---\nAlpha' } });
    fireEvent.click(screen.getByRole('button', { name: 'rawViewSave' }));

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
    expect(first.calls).toEqual(['update a2 Beta2', 'remove a3']);
    view.unmount();

    // More segments than items: the extra segments create new facts.
    const second = fakeRepository();
    render(<MemoryRawView items={items} runWrite={second.runWrite} onSaved={onSaved} onCancel={() => undefined} />);
    fireEvent.change(textbox(), { target: { value: 'Alpha\n---\nBeta\n---\nGamma\n---\n  New line  \n---\n\n---\nDelta' } });
    fireEvent.click(screen.getByRole('button', { name: 'rawViewSave' }));

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(2));
    expect(second.calls).toEqual(['create fact New line', 'create fact Delta']);
  });

  it('too_long_shows_index', async () => {
    const items = [item('a1', 'identity', 'Alpha')];
    const { calls, runWrite } = fakeRepository();
    const onSaved = vi.fn();
    render(<MemoryRawView items={items} runWrite={runWrite} onSaved={onSaved} onCancel={() => undefined} />);

    fireEvent.change(textbox(), { target: { value: `Alpha\n---\n${'x'.repeat(2001)}\n---\nShort` } });
    fireEvent.click(screen.getByRole('button', { name: 'rawViewSave' }));

    // rawApply's index counts from 0; the user sees it plus 1.
    expect(screen.getByRole('alert').textContent).toBe('rawViewTooLong:{"index":2}');
    expect(runWrite).not.toHaveBeenCalled();
    expect(onSaved).not.toHaveBeenCalled();
    expect(calls).toEqual([]);

    // After shortening, the hint disappears and saving is possible.
    fireEvent.change(textbox(), { target: { value: 'Alpha\n---\nShort' } });
    expect(screen.queryByRole('alert')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'rawViewSave' }));
    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
    expect(calls).toEqual(['create fact Short']);
  });
});

import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { MemoryItems, type MemoryItem } from '@oriveo/core/context/memory-items';
import { MemoryUsedPopover } from './MemoryUsedPopover';

const push = vi.fn();
let storeItems: MemoryItem[] = [];

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push }),
}));

vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: <T,>(selector: (state: { memoryItems: MemoryItem[] }) => T) => selector({ memoryItems: storeItems }),
}));

vi.mock('next-intl', () => ({
  useTranslations: (namespace: string) => (key: string) => {
    const messages: Record<string, string> = {
      'pages.memory.used.chip': 'Memory',
      'pages.memory.used.title': 'Memory used in this answer',
      'pages.memory.used.deleted': 'Deleted memory',
      'pages.memory.used.wrong': 'Fix this',
      'pages.memory.used.a11y': 'This answer used your memory',
    };
    return messages[`${namespace}.${key}`] ?? key;
  },
}));

const item = (id: string, content: string, status: MemoryItem['status'] = 'active') =>
  MemoryItems.canonical({ id, kind: 'preference', content, mutationId: `m-${id}`, deviceId: 'web', status });

describe('MemoryUsedPopover', () => {
  beforeEach(() => {
    push.mockReset();
    storeItems = [];
  });

  it('lists_items_and_deleted', () => {
    const long = 'A'.repeat(70);
    storeItems = [
      item('a', 'Prefers concise answers\nSecond line is not shown'),
      item('b', long),
      item('c', 'Tombstoned', 'deleted'),
    ];
    render(<MemoryUsedPopover memoryItemIds={['a', 'b', 'c', 'missing']} />);

    const chip = screen.getByRole('button', { name: 'This answer used your memory' });
    expect(chip.textContent).toBe('Memory');
    expect(screen.queryByRole('dialog')).toBeNull();

    fireEvent.click(chip);
    const dialog = screen.getByRole('dialog', { name: 'Memory used in this answer' });
    expect(dialog.textContent).toContain('Memory used in this answer');

    const rows = screen.getAllByRole('listitem');
    expect(rows).toHaveLength(4);
    expect(rows[0].textContent).toContain('Prefers concise answers');
    expect(rows[0].textContent).not.toContain('Second line');
    expect(rows[1].textContent).toContain(`${'A'.repeat(60)}…`);
    expect(rows[1].textContent).not.toContain('A'.repeat(61));
    expect(rows[2].textContent).toBe('Deleted memory');
    expect(rows[3].textContent).toBe('Deleted memory');
    expect(screen.getAllByRole('button', { name: 'Fix this' })).toHaveLength(2);
  });

  it('fix_opens_editor', () => {
    storeItems = [item('mem-1', 'Uses TypeScript')];
    render(<MemoryUsedPopover memoryItemIds={['mem-1']} />);

    fireEvent.click(screen.getByRole('button', { name: 'This answer used your memory' }));
    fireEvent.click(screen.getByRole('button', { name: 'Fix this' }));

    expect(push).toHaveBeenCalledWith('/settings/memory?edit=mem-1');
    expect(screen.queryByRole('dialog')).toBeNull();
  });
});

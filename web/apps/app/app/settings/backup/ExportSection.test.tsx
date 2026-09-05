import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { ReactNode } from 'react';
import { ExportSection } from './ExportSection';

const mocks = vi.hoisted(() => ({
  exportBackup: vi.fn(),
  saveBackupFile: vi.fn(),
}));

type MockState = {
  conversations: Array<{ messages: Array<Record<string, unknown>> }>;
  providers: Array<{ id: string }>;
};

let mockState: MockState = {
  conversations: [],
  providers: [],
};

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockState) => unknown) => selector(mockState),
}));

vi.mock('../../../lib/backup', () => ({
  exportBackup: (...args: unknown[]) => mocks.exportBackup(...args),
  saveBackupFile: (...args: unknown[]) => mocks.saveBackupFile(...args),
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    className,
  }: {
    children: ReactNode;
    onClick?: () => void;
    disabled?: boolean;
    className?: string;
  }) => (
    <button type="button" className={className} onClick={onClick} disabled={disabled}>
      {children}
    </button>
  ),
  Input: ({
    value,
    onChange,
    placeholder,
    type,
  }: {
    value?: string;
    onChange?: (event: { target: { value: string } }) => void;
    placeholder?: string;
    type?: string;
  }) => (
    <input
      type={type}
      value={value}
      placeholder={placeholder}
      onChange={(event) => onChange?.({ target: { value: event.target.value } })}
    />
  ),
  Dialog: ({ open, children }: { open: boolean; children: ReactNode }) =>
    open ? <div role="dialog">{children}</div> : null,
}));

describe('ExportSection', () => {
  beforeEach(() => {
    mockState = {
      conversations: [
        { messages: [{ id: 1 }, { id: 2 }] },
        { messages: [{ id: 3 }] },
      ],
      providers: [{ id: 'provider-1' }, { id: 'provider-2' }],
    };
    mocks.exportBackup.mockReset();
    mocks.saveBackupFile.mockReset();
  });

  it('renders the current data overview counts', () => {
    render(<ExportSection />);

    expect(screen.getByText('dataConversations')).toBeTruthy();
    expect(screen.getAllByText('2')).toHaveLength(2);
    expect(screen.getByText('dataProviders')).toBeTruthy();
    expect(screen.getByText('dataMessages')).toBeTruthy();
    expect(screen.getByText('3')).toBeTruthy();
  });

  it('blocks encrypted export when the passwords do not match', async () => {
    render(<ExportSection />);

    fireEvent.click(screen.getByRole('checkbox'));
    fireEvent.change(screen.getByPlaceholderText('passwordPlaceholder'), {
      target: { value: 'password-123' },
    });
    fireEvent.change(screen.getByPlaceholderText('confirmPasswordPlaceholder'), {
      target: { value: 'different-123' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'export' }));

    expect(mocks.exportBackup).not.toHaveBeenCalled();
    expect(screen.getByText('passwordMismatch')).toBeTruthy();
  });

  it('exports the backup and saves the generated file on success', async () => {
    const blob = new Blob(['backup-data']);
    mocks.exportBackup.mockResolvedValue(blob);
    mocks.saveBackupFile.mockResolvedValue(undefined);

    render(<ExportSection />);

    fireEvent.click(screen.getByRole('button', { name: 'export' }));

    await waitFor(() => {
      expect(mocks.exportBackup).toHaveBeenCalledWith({
        includeApiKeys: false,
        password: undefined,
      });
    });
    expect(mocks.saveBackupFile).toHaveBeenCalledWith(
      blob,
      expect.stringMatching(/^Oriveo-Backup-\d{4}-\d{2}-\d{2}\.oriveo$/),
    );
    expect(screen.getByText('success')).toBeTruthy();
  });

  it('shows an export error when the save flow fails', async () => {
    mocks.exportBackup.mockRejectedValue(new Error('boom'));

    render(<ExportSection />);

    fireEvent.click(screen.getByRole('button', { name: 'export' }));

    await waitFor(() => {
      expect(screen.getByText('exportFailed')).toBeTruthy();
    });
  });
});

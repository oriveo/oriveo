import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { ReactNode } from 'react';
import type { ImportPreview, ImportResult } from '../../../lib/backup';
import { ImportSection } from './ImportSection';

const mocks = vi.hoisted(() => ({
  parseBackupFile: vi.fn(),
  generateImportPreview: vi.fn(),
  executeImportAndRefreshStore: vi.fn(),
}));

function buildPreview(overrides?: Partial<ImportPreview>): ImportPreview {
  return {
    backupFile: {
      version: 1,
      createdAt: '2026-04-09T00:00:00.000Z',
      appVersion: '1.0.0',
      platform: 'Web',
      checksum: 'sha256:test',
      containsKeys: false,
      encryptedKeys: null,
      data: {
        providers: [],
        conversations: [],
      },
    },
    totalConversations: 2,
    totalProviders: 1,
    totalNotes: 0,
    totalNoteFolders: 0,
    existingConversationCount: 0,
    existingProviderCount: 0,
    existingNoteCount: 0,
    existingNoteFolderCount: 0,
    newConversationCount: 2,
    newProviderCount: 1,
    newNoteCount: 0,
    newNoteFolderCount: 0,
    hasImages: false,
    checksumValid: true,
    attachmentChecksumIssues: [],
    imageEntries: new Map(),
    ...overrides,
  };
}

function buildResult(overrides?: Partial<ImportResult>): ImportResult {
  return {
    conversationsImported: 2,
    conversationsSkipped: 0,
    conversationsMerged: 0,
    providersImported: 1,
    providersSkipped: 0,
    providersMerged: 0,
    skillsImported: 0,
    skillsSkipped: 0,
    skillsMerged: 0,
    skillsRequiringKnowledgeReupload: 0,
    notesImported: 0,
    notesSkipped: 0,
    notesMerged: 0,
    noteFoldersImported: 0,
    noteFoldersSkipped: 0,
    noteFoldersMerged: 0,
    keysRestored: 0,
    imagesRestored: 0,
    restoredPreferences: false,
    restoredLastUsedModel: false,
    ...overrides,
  };
}

vi.mock('../../../lib/backup', () => ({
  parseBackupFile: (...args: unknown[]) => mocks.parseBackupFile(...args),
  generateImportPreview: (...args: unknown[]) => mocks.generateImportPreview(...args),
  executeImportAndRefreshStore: (...args: unknown[]) => mocks.executeImportAndRefreshStore(...args),
}));

vi.mock('./BackupPreviewCard', () => ({
  BackupPreviewCard: ({ preview }: { preview: ImportPreview }) => (
    <div data-testid="backup-preview-card">{preview.totalConversations}</div>
  ),
}));

vi.mock('./ImportResultCard', () => ({
  ImportResultCard: ({ result }: { result: ImportResult }) => (
    <div data-testid="import-result-card">{result.conversationsImported}</div>
  ),
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    tone,
    size,
    className,
  }: {
    children: ReactNode;
    onClick?: () => void;
    disabled?: boolean;
    tone?: string;
    size?: string;
    className?: string;
  }) => (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      data-tone={tone}
      data-size={size}
      className={className}
    >
      {children}
    </button>
  ),
  Input: ({
    value,
    onChange,
    onKeyDown,
    placeholder,
    type,
  }: {
    value?: string;
    onChange?: (event: { target: { value: string } }) => void;
    onKeyDown?: (event: { key: string }) => void;
    placeholder?: string;
    type?: string;
  }) => (
    <input
      type={type}
      value={value}
      placeholder={placeholder}
      onChange={(event) => onChange?.({ target: { value: event.target.value } })}
      onKeyDown={(event) => onKeyDown?.({ key: event.key })}
    />
  ),
  Dialog: ({
    open,
    children,
    onClose,
  }: {
    open: boolean;
    children: ReactNode;
    onClose?: () => void;
  }) => (
    open ? (
      <div>
        <button type="button" onClick={onClose}>close-dialog</button>
        {children}
      </div>
    ) : null
  ),
}));

describe('ImportSection', () => {
  beforeEach(() => {
    mocks.parseBackupFile.mockReset();
    mocks.generateImportPreview.mockReset();
    mocks.executeImportAndRefreshStore.mockReset();
  });

  it('shows an invalid file error when parsing fails', async () => {
    mocks.parseBackupFile.mockRejectedValue(new Error('INVALID_FILE'));

    const { container } = render(<ImportSection />);
    const fileInput = container.querySelector('input[type="file"]');
    if (!fileInput) throw new Error('file input not found');

    fireEvent.change(fileInput, {
      target: { files: [new File(['bad'], 'broken.oriveo')] },
    });

    await waitFor(() => {
      expect(screen.getByText('invalidFile')).toBeTruthy();
    });
  });

  it('requests the legacy password and continues to preview after decrypting', async () => {
    const file = new File(['legacy'], 'legacy.oriveo');
    const preview = buildPreview();
    mocks.parseBackupFile
      .mockRejectedValueOnce(new Error('PASSWORD_REQUIRED'))
      .mockResolvedValueOnce({ backupFile: preview.backupFile, imageEntries: preview.imageEntries });
    mocks.generateImportPreview.mockResolvedValue(preview);

    const { container } = render(<ImportSection />);
    const fileInput = container.querySelector('input[type="file"]');
    if (!fileInput) throw new Error('file input not found');

    fireEvent.change(fileInput, {
      target: { files: [file] },
    });

    await waitFor(() => {
      expect(screen.getByPlaceholderText('importPassword')).toBeTruthy();
    });

    fireEvent.change(screen.getByPlaceholderText('importPassword'), {
      target: { value: 'legacy-password' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'next' }));

    await waitFor(() => {
      expect(screen.getByTestId('backup-preview-card')).toBeTruthy();
    });
    expect(mocks.parseBackupFile).toHaveBeenNthCalledWith(2, file, 'legacy-password');
  });

  it('confirms replace-all imports, restores keys, and shows the result card', async () => {
    const preview = buildPreview({
      backupFile: {
        ...buildPreview().backupFile,
        containsKeys: true,
        encryptedKeys: 'encrypted',
      },
    });
    const result = buildResult({ keysRestored: 1 });
    mocks.parseBackupFile.mockResolvedValue({
      backupFile: preview.backupFile,
      imageEntries: preview.imageEntries,
    });
    mocks.generateImportPreview.mockResolvedValue(preview);
    mocks.executeImportAndRefreshStore.mockResolvedValue(result);

    const { container } = render(<ImportSection />);
    const fileInput = container.querySelector('input[type="file"]');
    if (!fileInput) throw new Error('file input not found');

    fireEvent.change(fileInput, {
      target: { files: [new File(['data'], 'backup.oriveo')] },
    });

    await waitFor(() => {
      expect(screen.getByTestId('backup-preview-card')).toBeTruthy();
    });

    fireEvent.click(screen.getByRole('radio', { name: /modeReplaceAll/ }));
    fireEvent.click(screen.getByRole('button', { name: 'import' }));

    await waitFor(() => {
      expect(screen.getByText('replaceConfirmTitle')).toBeTruthy();
    });

    fireEvent.click(screen.getByRole('button', { name: 'replaceConfirmAction' }));

    await waitFor(() => {
      expect(screen.getByPlaceholderText('keyPasswordPlaceholder')).toBeTruthy();
    });

    fireEvent.change(screen.getByPlaceholderText('keyPasswordPlaceholder'), {
      target: { value: 'restore-secret' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'restoreKeys' }));

    await waitFor(() => {
      expect(mocks.executeImportAndRefreshStore).toHaveBeenCalledWith(preview, 'replaceAll', 'restore-secret');
    });
    expect(screen.getByTestId('import-result-card')).toBeTruthy();
  });
});

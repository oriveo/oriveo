import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useAttachmentDragDrop } from '../useAttachmentDragDrop';

const { mockValidateAndConvertFiles, mockLoadAttachmentUtils } = vi.hoisted(() => ({
  mockValidateAndConvertFiles: vi.fn().mockResolvedValue([
    { id: 'att-1', kind: 'image', fileName: 'photo.jpg' },
  ]),
  mockLoadAttachmentUtils: vi.fn(),
}));

vi.mock('../../utils/attachment-utils-lazy', () => ({
  loadAttachmentUtils: mockLoadAttachmentUtils,
}));

describe('useAttachmentDragDrop', () => {
  const onFilesAccepted = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
    mockLoadAttachmentUtils.mockResolvedValue({
      validateAndConvertFiles: mockValidateAndConvertFiles,
    });
  });

  it('should start with dragActive = false', () => {
    const { result } = renderHook(() => useAttachmentDragDrop(onFilesAccepted));
    expect(result.current.dragActive).toBe(false);
  });

  it('should expose drag handlers', () => {
    const { result } = renderHook(() => useAttachmentDragDrop(onFilesAccepted));
    expect(result.current.dragHandlers).toHaveProperty('onDragEnter');
    expect(result.current.dragHandlers).toHaveProperty('onDragOver');
    expect(result.current.dragHandlers).toHaveProperty('onDragLeave');
    expect(result.current.dragHandlers).toHaveProperty('onDrop');
  });

  it('should set dragActive on dragEnter and clear on dragLeave', () => {
    const { result } = renderHook(() => useAttachmentDragDrop(onFilesAccepted));
    const fakeEvent = { preventDefault: vi.fn() } as any;

    act(() => result.current.dragHandlers.onDragEnter(fakeEvent));
    expect(result.current.dragActive).toBe(true);

    act(() => result.current.dragHandlers.onDragLeave(fakeEvent));
    expect(result.current.dragActive).toBe(false);
  });

  it('should handle nested dragEnter/Leave (counter-based)', () => {
    const { result } = renderHook(() => useAttachmentDragDrop(onFilesAccepted));
    const fakeEvent = { preventDefault: vi.fn() } as any;

    act(() => result.current.dragHandlers.onDragEnter(fakeEvent));
    act(() => result.current.dragHandlers.onDragEnter(fakeEvent));
    expect(result.current.dragActive).toBe(true);

    act(() => result.current.dragHandlers.onDragLeave(fakeEvent));
    // Still dragging (counter=1)
    expect(result.current.dragActive).toBe(true);

    act(() => result.current.dragHandlers.onDragLeave(fakeEvent));
    expect(result.current.dragActive).toBe(false);
  });

  it('should call onFilesAccepted on drop', async () => {
    const { result } = renderHook(() => useAttachmentDragDrop(onFilesAccepted));
    const fakeDropEvent = {
      preventDefault: vi.fn(),
      dataTransfer: { files: [new File(['x'], 'photo.jpg', { type: 'image/jpeg' })] },
    } as any;

    await act(async () => {
      await result.current.dragHandlers.onDrop(fakeDropEvent);
    });

    expect(onFilesAccepted).toHaveBeenCalledWith([
      expect.objectContaining({ id: 'att-1', kind: 'image' }),
    ]);
    expect(mockLoadAttachmentUtils).toHaveBeenCalledTimes(1);
    expect(result.current.dragActive).toBe(false);
  });

  it('filters dropped attachments through model and provider capability gate', async () => {
    mockValidateAndConvertFiles.mockResolvedValueOnce([
      { id: 'att-image', kind: 'image', fileName: 'photo.jpg' },
      { id: 'att-file', kind: 'file', fileName: 'doc.pdf' },
    ]);
    const { result } = renderHook(() => useAttachmentDragDrop(
      onFilesAccepted,
      undefined,
      { canAcceptAttachment: (attachment) => attachment.kind === 'file' },
    ));
    const fakeDropEvent = {
      preventDefault: vi.fn(),
      dataTransfer: {
        files: [
          new File(['x'], 'photo.jpg', { type: 'image/jpeg' }),
          new File(['x'], 'doc.pdf', { type: 'application/pdf' }),
        ],
      },
    } as any;

    await act(async () => {
      await result.current.dragHandlers.onDrop(fakeDropEvent);
    });

    expect(onFilesAccepted).toHaveBeenCalledWith([
      expect.objectContaining({ id: 'att-file', kind: 'file' }),
    ]);
  });

  it('should report oversized dropped files without converting them', async () => {
    const onOversizedFiles = vi.fn();
    const { result } = renderHook(() => useAttachmentDragDrop(onFilesAccepted, onOversizedFiles));
    const oversizedFile = new File(['x'], 'huge.pdf', { type: 'application/pdf' });
    Object.defineProperty(oversizedFile, 'size', { value: 50 * 1024 * 1024 + 1 });
    const fakeDropEvent = {
      preventDefault: vi.fn(),
      dataTransfer: { files: [oversizedFile] },
    } as any;

    await act(async () => {
      await result.current.dragHandlers.onDrop(fakeDropEvent);
    });

    expect(onOversizedFiles).toHaveBeenCalledWith([oversizedFile]);
    expect(mockLoadAttachmentUtils).not.toHaveBeenCalled();
    expect(mockValidateAndConvertFiles).not.toHaveBeenCalled();
    expect(onFilesAccepted).not.toHaveBeenCalled();
  });

  // The BYOK side had no aggregate limit at all, so a few hundred images would push the message
  // document past the 1MiB per-document cap. The semantics match AttachmentImportLimiter: count the
  // total and accept the prefix that fits the remaining allowance, rather than rejecting the
  // whole batch.
  it('truncates a BYOK drop to the remaining allowance and does not convert the rest', async () => {
    const { result } = renderHook(() => useAttachmentDragDrop(
      onFilesAccepted,
      undefined,
      { existingAttachments: [{ id: 'existing', kind: 'image', fileName: 'a.jpg', mimeType: 'image/jpeg' }] },
    ));
    const files = ['b.jpg', 'c.jpg', 'd.jpg', 'e.jpg'].map(
      (name) => new File(['x'], name, { type: 'image/jpeg' }),
    );
    const fakeDropEvent = { preventDefault: vi.fn(), dataTransfer: { files } } as any;

    await act(async () => {
      await result.current.dragHandlers.onDrop(fakeDropEvent);
    });

    // Limit 3 with 1 already present leaves 2 slots
    expect(mockValidateAndConvertFiles).toHaveBeenCalledTimes(1);
    const converted = mockValidateAndConvertFiles.mock.calls[0][0] as File[];
    expect(converted.map((f) => f.name)).toEqual(['b.jpg', 'c.jpg']);
  });

  it('rejects the whole BYOK batch with no conversion when the allowance is already full', async () => {
    const existing = ['a.jpg', 'b.jpg', 'c.jpg'].map((name, i) => ({
      id: `existing-${i}`, kind: 'image' as const, fileName: name, mimeType: 'image/jpeg',
    }));
    const { result } = renderHook(() => useAttachmentDragDrop(
      onFilesAccepted,
      undefined,
      { existingAttachments: existing },
    ));
    const fakeDropEvent = {
      preventDefault: vi.fn(),
      dataTransfer: { files: [new File(['x'], 'd.jpg', { type: 'image/jpeg' })] },
    } as any;

    await act(async () => {
      await result.current.dragHandlers.onDrop(fakeDropEvent);
    });

    expect(mockValidateAndConvertFiles).not.toHaveBeenCalled();
    expect(onFilesAccepted).not.toHaveBeenCalled();
  });
});

import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Attachment } from '@oriveo/shared';
import { AttachmentImage } from './AttachmentImage';

const { mockUseAttachmentImage, mockLoadImageData, mockDownloadAttachmentIfNeeded, mockGetActiveUID } = vi.hoisted(() => ({
  mockUseAttachmentImage: vi.fn(),
  mockLoadImageData: vi.fn(),
  mockDownloadAttachmentIfNeeded: vi.fn(),
  mockGetActiveUID: vi.fn(),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

vi.mock('../../lib/hooks/useAttachmentImage', () => ({
  useAttachmentImage: mockUseAttachmentImage,
}));

vi.mock('../../lib/infra/storage/image-store', () => ({
  loadImageData: mockLoadImageData,
}));

vi.mock('../../lib/core/sync-port', () => ({
  downloadAttachmentIfNeeded: mockDownloadAttachmentIfNeeded,
}));

vi.mock('../../lib/infra/storage/partition', () => ({
  getActiveUID: mockGetActiveUID,
}));

const attachment: Attachment = {
  id: 'attachment-1',
  kind: 'image',
  fileName: 'image-01.png',
  mimeType: 'image/png',
  base64Data: 'ZmFrZQ==',
};

describe('AttachmentImage', () => {
  beforeEach(() => {
    mockUseAttachmentImage.mockReset();
    mockLoadImageData.mockReset();
    mockDownloadAttachmentIfNeeded.mockReset();
    mockGetActiveUID.mockReset();
    mockUseAttachmentImage.mockReturnValue('data:image/png;base64,ZmFrZQ==');
    mockLoadImageData.mockResolvedValue(null);
    mockDownloadAttachmentIfNeeded.mockResolvedValue(null);
    mockGetActiveUID.mockResolvedValue('user-1');
    vi.stubGlobal('URL', {
      ...URL,
      createObjectURL: vi.fn(() => 'blob:full-image'),
      revokeObjectURL: vi.fn(),
    });
  });

  it('uses the provided link class when rendering a clickable image card', () => {
    render(
      <AttachmentImage
        attachment={attachment}
        className="image-class"
        linkClassName="link-class"
        asLink
      />,
    );

    const button = screen.getByRole('button');
    const image = screen.getByAltText('image-01.png');

    expect(button.className).toContain('link-class');
    expect(image.className).toBe('image-class');
  });

  it('falls back to an inline reset style when no link class is provided', () => {
    render(
      <AttachmentImage
        attachment={attachment}
        className="image-class"
        asLink
      />,
    );

    const button = screen.getByRole('button');
    expect(button.getAttribute('style')).toContain('display: block');
  });

  it('shows the thumbnail with a loading indicator until the synced original image is available', async () => {
    const fullBlob = new Blob(['full-image'], { type: 'image/png' });
    let finishDownload: (value: string) => void = () => {};
    mockLoadImageData
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(fullBlob);
    mockDownloadAttachmentIfNeeded.mockReturnValueOnce(new Promise((resolve) => {
      finishDownload = resolve;
    }));

    render(
      <AttachmentImage
        attachment={{
          ...attachment,
          storageRef: 'users/user-1/attachments/attachment-1',
        }}
        asLink
      />,
    );

    fireEvent.click(screen.getByRole('button'));

    const dialog = await screen.findByRole('dialog');
    expect(dialog).not.toBeNull();
    expect(within(dialog).getByText('loadingOriginal')).not.toBeNull();
    expect(within(dialog).getByAltText('image-01.png').getAttribute('src')).toBe('data:image/png;base64,ZmFrZQ==');

    finishDownload('attachment-1');

    await waitFor(() => {
      expect(within(dialog).queryByText('loadingOriginal')).toBeNull();
      expect(within(dialog).getByAltText('image-01.png').getAttribute('src')).toBe('blob:full-image');
    });
    expect(mockDownloadAttachmentIfNeeded).toHaveBeenCalledWith(
      'user-1',
      'users/user-1/attachments/attachment-1',
      'attachment-1',
      'image/png',
    );
  });
});

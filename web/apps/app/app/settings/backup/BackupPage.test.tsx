import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { BackupPage } from './BackupPage';

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: mocks.routerPush }),
}));

vi.mock('./ExportSection', () => ({
  ExportSection: () => <div data-testid="export-section" />,
}));

vi.mock('./ImportSection', () => ({
  ImportSection: () => <div data-testid="import-section" />,
}));

describe('BackupPage', () => {
  beforeEach(() => {
    mocks.routerPush.mockReset();
  });

  it('renders both backup sections', () => {
    render(<BackupPage />);

    expect(screen.getByTestId('export-section')).toBeTruthy();
    expect(screen.getByTestId('import-section')).toBeTruthy();
  });

  it('navigates back to settings from click and keyboard', () => {
    render(<BackupPage />);

    const backLink = screen.getByRole('button', { name: 'title' });
    fireEvent.click(backLink);
    fireEvent.keyDown(backLink, { key: 'Enter' });

    expect(mocks.routerPush).toHaveBeenCalledTimes(2);
    expect(mocks.routerPush).toHaveBeenNthCalledWith(1, '/settings');
    expect(mocks.routerPush).toHaveBeenNthCalledWith(2, '/settings');
  });
});

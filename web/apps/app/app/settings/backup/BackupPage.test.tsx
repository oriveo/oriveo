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

  // The back control is a native <button> (shared BackButton); the browser turns Enter / Space into a click, so no onKeyDown is needed
  it('navigates back to settings from the shared back button', () => {
    render(<BackupPage />);

    const backButton = screen.getByRole('button', { name: 'back' });
    expect(backButton.tagName).toBe('BUTTON');
    fireEvent.click(backButton);

    expect(mocks.routerPush).toHaveBeenCalledTimes(1);
    expect(mocks.routerPush).toHaveBeenCalledWith('/settings');
  });
});

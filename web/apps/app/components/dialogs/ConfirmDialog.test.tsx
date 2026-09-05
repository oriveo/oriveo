// @vitest-environment jsdom

import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { ConfirmDialog } from './ConfirmDialog';

afterEach(cleanup);

const baseProps = {
  open: true,
  title: 'Delete conversation',
  confirmLabel: 'Delete',
  cancelLabel: 'Cancel',
  onConfirm: vi.fn(),
  onCancel: vi.fn(),
};

describe('ConfirmDialog', () => {
  it('renders nothing when open=false', () => {
    render(<ConfirmDialog {...baseProps} open={false} />);
    expect(screen.queryByText('Delete conversation')).toBeNull();
  });

  it('renders the title / message / both buttons', () => {
    render(<ConfirmDialog {...baseProps} message="Are you sure you want to delete it?" />);
    expect(screen.getByText('Delete conversation')).toBeTruthy();
    expect(screen.getByText('Are you sure you want to delete it?')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Delete' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeTruthy();
  });

  it('clicking confirm / cancel fires the matching callback', () => {
    const onConfirm = vi.fn();
    const onCancel = vi.fn();
    render(<ConfirmDialog {...baseProps} onConfirm={onConfirm} onCancel={onCancel} />);
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }));
    expect(onConfirm).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(onCancel).toHaveBeenCalledTimes(1);
  });

  it('disables both buttons while loading', () => {
    render(<ConfirmDialog {...baseProps} loading />);
    expect((screen.getByRole('button', { name: 'Delete' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: 'Cancel' }) as HTMLButtonElement).disabled).toBe(true);
  });
});

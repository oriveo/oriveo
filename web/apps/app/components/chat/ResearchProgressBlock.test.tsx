import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ResearchProgressBlock } from './ResearchProgressBlock';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

afterEach(cleanup);

describe('ResearchProgressBlock', () => {
  const steps = [
    { tool: 'library_search', label: 'roadmap', status: 'completed' as const },
    { tool: 'library_read', label: 'doc-1', status: 'running' as const },
  ];

  it('shows live progress, tool labels, and status names', () => {
    render(<ResearchProgressBlock steps={steps} isStreaming />);

    expect(screen.getByText('progress.running')).toBeTruthy();
    expect(screen.getByText('1/2')).toBeTruthy();
    expect(screen.getByText('progress.tool.search')).toBeTruthy();
    expect(screen.getByText('roadmap')).toBeTruthy();
    expect(screen.getByLabelText('progress.status.running')).toBeTruthy();
  });

  it('can collapse and uses the completed label after streaming', () => {
    render(<ResearchProgressBlock steps={steps} isStreaming={false} />);
    const toggle = screen.getByRole('button', { name: /progress.complete/ });
    expect(toggle.getAttribute('aria-expanded')).toBe('true');

    fireEvent.click(toggle);
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    expect(screen.queryByText('roadmap')).toBeNull();
  });
});

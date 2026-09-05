/**
 * A stalled conversation must offer retry. History lives on the device, so retry is the only
 * way out of this screen.
 */
import { describe, expect, it, vi } from 'vitest';
import { render, screen, cleanup, fireEvent } from '@testing-library/react';
import { afterEach } from 'vitest';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => `t:${key}`,
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({ children, onClick, ...rest }: React.ComponentProps<'button'>) => (
    <button onClick={onClick} {...rest}>{children}</button>
  ),
}));

vi.mock('lucide-react', () => ({
  CloudOff: () => <svg data-testid="cloud-off" />,
}));

vi.mock('./ConversationStalledState.module.css', () => ({ default: {} }));

import { ConversationStalledState } from './ConversationStalledState';

afterEach(cleanup);

describe('ConversationStalledState', () => {
  it('retries loading local history', () => {
    const onRetry = vi.fn();
    render(<ConversationStalledState onRetry={onRetry} />);

    const retry = screen.getByTestId('conversation-stalled-retry');
    expect(retry).toBeTruthy();
    fireEvent.click(retry);
    expect(onRetry).toHaveBeenCalledTimes(1);
    expect(screen.getByText('t:historyUnavailableMessage')).toBeTruthy();
    expect(screen.queryByTestId('conversation-stalled-login')).toBeNull();
    expect(screen.queryByTestId('conversation-stalled-upgrade')).toBeNull();
  });
});

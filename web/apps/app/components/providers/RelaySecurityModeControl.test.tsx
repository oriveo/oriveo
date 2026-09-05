import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { RelaySecurityModeControl } from './RelaySecurityModeControl';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key,
}));

describe('RelaySecurityModeControl', () => {
  it('keeps the first downgrade click in confirmation state and writes only after affirmative confirm', async () => {
    const onChange = vi.fn();
    render(
      <RelaySecurityModeControl
        value="remote_https"
        endpoint="192.168.1.20:8080/v1"
        hasCredentialMaterial={false}
        onChange={onChange}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'changeConnectionType' }));
    fireEvent.click(screen.getByRole('button', { name: /connectionTypeLocalHttp/ }));
    expect(onChange).not.toHaveBeenCalled();
    expect(screen.getByText('securityModePlainHttpWarning')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'confirmPlainHttp' }));
    await waitFor(() => expect(onChange).toHaveBeenCalledWith({
      mode: 'local_http',
      normalizedEndpoint: 'http://192.168.1.20:8080/v1',
    }));
  });

  it('uses the credential-material branch from the caller and requires the atomic-delete action', () => {
    render(
      <RelaySecurityModeControl
        value="remote_https"
        endpoint="http://192.168.1.20:8080/v1"
        hasCredentialMaterial
        onChange={vi.fn()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: 'changeConnectionType' }));
    fireEvent.click(screen.getByRole('button', { name: /connectionTypeLocalHttp/ }));
    expect(screen.getByText('securityModeClearCredentialsWarning')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'clearCredentialsAndSwitch' })).toBeTruthy();
  });

  it('disables weaker modes for explicit HTTPS instead of entering a guaranteed mismatch', () => {
    render(
      <RelaySecurityModeControl
        value="remote_https"
        endpoint="https://192.168.1.20:8080/v1"
        hasCredentialMaterial={false}
        onChange={vi.fn()}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: 'changeConnectionType' }));
    const local = screen.getByRole('button', { name: /connectionTypeLocalHttp/ }) as HTMLButtonElement;
    expect(local.disabled).toBe(true);
    expect(screen.getAllByText('securityModeSchemeMismatch').length).toBeGreaterThan(0);
  });

  it('shows stored TOFU as paired HTTPS with its pinned-certificate description but never as a selectable option', () => {
    render(
      <RelaySecurityModeControl
        value="tofu_https"
        endpoint="https://paired.local"
        hasCredentialMaterial={false}
        onChange={vi.fn()}
      />,
    );

    expect(screen.getByText('connectionTypePairedHttps')).toBeTruthy();
    expect(screen.getByText('connectionTypePairedHttpsDesc')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'changeConnectionType' }));
    expect(screen.queryByRole('button', { name: /connectionTypePairedHttps/ })).toBeNull();
  });

  it('re-applies the selected mode when its endpoint still needs a scheme writeback', async () => {
    const onChange = vi.fn();
    render(
      <RelaySecurityModeControl
        value="remote_https"
        endpoint="relay.example.com/v1"
        hasCredentialMaterial={false}
        onChange={onChange}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'changeConnectionType' }));
    fireEvent.click(screen.getByRole('button', { name: /connectionTypeRemoteHttps/ }));
    await waitFor(() => expect(onChange).toHaveBeenCalledWith({
      mode: 'remote_https',
      normalizedEndpoint: 'https://relay.example.com/v1',
    }));
  });
});

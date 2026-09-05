import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { LocalComputeSetup } from './LocalComputeSetup';
import { useCustomLLMConnectionCoordinator } from './custom-llm-connection-coordinator';

const mocks = vi.hoisted(() => ({
  connect: vi.fn(),
  addProvider: vi.fn(),
  routerPush: vi.fn(),
  routerBack: vi.fn(),
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: mocks.routerPush, back: mocks.routerBack }),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key,
}));

vi.mock('../../../../lib/core/providers/local-browser-probe', () => ({
  connectLocalEngineInBrowser: (...args: unknown[]) => mocks.connect(...args),
}));

vi.mock('../../../../lib/core/provider-ops', () => ({
  addProvider: (...args: unknown[]) => mocks.addProvider(...args),
}));

vi.mock('../../../../providers/StoreProvider', () => ({
  getVanillaStore: () => ({}),
  // Submission telemetry needs to know whether this is the first provider, so the component subscribes
  // to providers.
  useAppStore: (selector: (state: { providers: unknown[] }) => unknown) =>
    selector({ providers: [] }),
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({ children, onClick, disabled, className }: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
    className?: string;
  }) => <button type="button" onClick={onClick} disabled={disabled} className={className}>{children}</button>,
}));

function LocalComputeSetupHarness() {
  const connection = useCustomLLMConnectionCoordinator();
  return <LocalComputeSetup connection={connection} />;
}

async function confirmLocalHttp() {
  fireEvent.change(screen.getByLabelText('requestURLLabel'), {
    target: { value: 'http://127.0.0.1:11434' },
  });
  fireEvent.click(screen.getByRole('button', { name: 'changeConnectionType' }));
  fireEvent.click(screen.getByRole('button', { name: /connectionTypeLocalHttp/ }));
  fireEvent.click(screen.getByRole('button', { name: 'confirmPlainHttp' }));
  await waitFor(() => expect((screen.getByLabelText('requestURLLabel') as HTMLInputElement).value)
    .toBe('http://127.0.0.1:11434'));
}

describe('LocalComputeSetup', () => {
  beforeEach(() => {
    Object.defineProperty(window, 'isSecureContext', { configurable: true, value: true });
    mocks.connect.mockReset();
    mocks.addProvider.mockReset();
    mocks.addProvider.mockResolvedValue(true);
    mocks.routerPush.mockReset();
    mocks.connect.mockResolvedValue({
      state: 'wrong_engine',
      failure: 'invalid_response',
      endpoint: 'http://127.0.0.1:11434',
      modelIDs: [],
      models: [],
      generationVerified: false,
    });
  });

  it('local scenario stays fail-safe until the user explicitly confirms local_http', async () => {
    render(<LocalComputeSetupHarness />);
    const connect = screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement;
    expect(screen.getByText('connectionTypeRemoteHttps')).toBeTruthy();
    expect(connect.disabled).toBe(true);
    const endpoint = screen.getByLabelText('requestURLLabel') as HTMLInputElement;
    expect(endpoint.value).toBe('');
    expect(endpoint.placeholder).toBe('http://127.0.0.1:11434');
    expect(mocks.connect).not.toHaveBeenCalled();

    await confirmLocalHttp();
    expect(connect.disabled).toBe(false);
    fireEvent.click(connect);
    await waitFor(() => expect(mocks.connect).toHaveBeenCalledWith(expect.objectContaining({
      engine: 'ollama',
      endpoint: 'http://127.0.0.1:11434',
      securityMode: 'local_http',
    })));
  });

  it('revokes a confirmed cleartext mode when switching to a different engine endpoint', async () => {
    render(<LocalComputeSetupHarness />);
    await confirmLocalHttp();
    expect(screen.getByText('connectionTypeLocalHttp')).toBeTruthy();

    fireEvent.change(screen.getByLabelText('localCompute'), { target: { value: 'lmstudio' } });

    expect(screen.getByText('connectionTypeRemoteHttps')).toBeTruthy();
    expect((screen.getByLabelText('requestURLLabel') as HTMLInputElement).value)
      .toBe('http://127.0.0.1:11434');
    expect((screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement).disabled)
      .toBe(true);
    expect(mocks.connect).not.toHaveBeenCalled();
  });

  it('connects and persists Open WebUI only through HTTPS with bearer authentication', async () => {
    mocks.connect.mockResolvedValueOnce({
      state: 'ready',
      endpoint: 'https://openwebui.example',
      modelIDs: ['fixture-model'],
      models: [{ id: 'fixture-model', localLoadState: 'loaded', executionLocality: 'local' }],
      apiBaseURL: 'https://openwebui.example/api',
      generationVerified: true,
    });
    render(<LocalComputeSetupHarness />);

    fireEvent.change(screen.getByLabelText('localCompute'), { target: { value: 'openwebui' } });
    fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'https://openwebui.example' } });
    const detect = screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement;
    expect(detect.disabled).toBe(true);
    fireEvent.change(screen.getByLabelText('apiKeyLabel'), { target: { value: 'openwebui-secret' } });
    expect(detect.disabled).toBe(false);
    fireEvent.click(detect);

    await waitFor(() => expect(mocks.connect).toHaveBeenCalledWith(expect.objectContaining({
      engine: 'openwebui',
      endpoint: 'https://openwebui.example',
      securityMode: 'remote_https',
      apiKey: 'openwebui-secret',
    })));
    fireEvent.click(await screen.findByRole('button', { name: 'connectAndSave' }));
    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect(mocks.addProvider.mock.calls[0]?.[1]).toMatchObject({
      apiKey: 'openwebui-secret',
      baseURLText: 'https://openwebui.example',
      relayResolvedBaseURLText: 'https://openwebui.example/api',
      relayResolvedAuthMode: 'bearer',
      relayRequested: {
        authMode: 'bearer',
        securityMode: 'remote_https',
        engineProfile: 'openwebui',
        resolvedAPIBaseURL: 'https://openwebui.example/api',
      },
    });
  });

  it('clears the Open WebUI bearer key when the user confirms an HTTP downgrade', async () => {
    render(<LocalComputeSetupHarness />);
    fireEvent.change(screen.getByLabelText('localCompute'), { target: { value: 'openwebui' } });
    fireEvent.change(screen.getByLabelText('requestURLLabel'), { target: { value: 'http://127.0.0.1:3000' } });
    fireEvent.change(screen.getByLabelText('apiKeyLabel'), { target: { value: 'openwebui-secret' } });

    fireEvent.click(screen.getByRole('button', { name: 'changeConnectionType' }));
    fireEvent.click(screen.getByRole('button', { name: /connectionTypeLocalHttp/ }));
    fireEvent.click(screen.getByRole('button', { name: 'clearCredentialsAndSwitch' }));

    await waitFor(() => expect((screen.getByLabelText('apiKeyLabel') as HTMLInputElement).value).toBe(''));
    expect(screen.getByText('connectionTypeLocalHttp')).toBeTruthy();
    expect((screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement).disabled).toBe(true);
    expect(mocks.connect).not.toHaveBeenCalled();
  });

  it('aborts the active production connector generation on unmount and keeps every editor disabled while pending', async () => {
    let resolveConnect: ((value: unknown) => void) | undefined;
    mocks.connect.mockReturnValueOnce(new Promise((resolve) => { resolveConnect = resolve; }));
    const view = render(<LocalComputeSetupHarness />);
    await confirmLocalHttp();
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));

    await waitFor(() => expect(mocks.connect).toHaveBeenCalledTimes(1));
    const signal = mocks.connect.mock.calls[0]?.[0]?.signal as AbortSignal;
    expect(signal.aborted).toBe(false);
    expect((screen.getByLabelText('localCompute') as HTMLSelectElement).disabled).toBe(true);
    expect((screen.getByLabelText('requestURLLabel') as HTMLInputElement).disabled).toBe(true);
    expect((screen.getByLabelText('defaultModelLabel') as HTMLInputElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: 'changeConnectionType' }) as HTMLButtonElement).disabled).toBe(true);

    view.unmount();
    expect(signal.aborted).toBe(true);
    await act(async () => {
      resolveConnect?.({
        state: 'ready',
        endpoint: 'http://127.0.0.1:11434',
        modelIDs: ['local-model'],
        models: [{ id: 'local-model', localLoadState: 'loaded', executionLocality: 'local' }],
        apiBaseURL: 'http://127.0.0.1:11434/v1',
        generationVerified: true,
      });
    });
    expect(mocks.addProvider).not.toHaveBeenCalled();
    expect(mocks.routerPush).not.toHaveBeenCalled();
  });

  it('unmounting while persistence is pending invalidates the real addProvider guard and does not navigate', async () => {
    mocks.connect.mockResolvedValueOnce({
      state: 'ready',
      endpoint: 'http://127.0.0.1:11434',
      modelIDs: ['local-model'],
      models: [{ id: 'local-model', localLoadState: 'loaded', executionLocality: 'local' }],
      apiBaseURL: 'http://127.0.0.1:11434/v1',
      generationVerified: true,
    });
    let releasePersistence: (() => void) | undefined;
    mocks.addProvider.mockImplementationOnce(async (
      _store: unknown,
      _provider: unknown,
      options: { shouldCommit: () => boolean },
    ) => {
      await new Promise<void>((resolve) => { releasePersistence = resolve; });
      return options.shouldCommit();
    });
    const view = render(<LocalComputeSetupHarness />);
    await confirmLocalHttp();
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));
    await screen.findByRole('button', { name: 'connectAndSave' });
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSave' }));

    await waitFor(() => expect(releasePersistence).toBeTypeOf('function'));
    const shouldCommit = mocks.addProvider.mock.calls[0]?.[2]?.shouldCommit as () => boolean;
    expect(shouldCommit()).toBe(true);
    view.unmount();
    expect(shouldCommit()).toBe(false);
    await act(async () => { releasePersistence?.(); });

    expect(mocks.routerPush).not.toHaveBeenCalled();
  });

  it('does not navigate when addProvider returns false because of the UID guard', async () => {
    mocks.connect.mockResolvedValueOnce({
      state: 'ready',
      endpoint: 'http://127.0.0.1:11434',
      modelIDs: ['local-model'],
      models: [{ id: 'local-model', localLoadState: 'loaded', executionLocality: 'local' }],
      apiBaseURL: 'http://127.0.0.1:11434/v1',
      generationVerified: true,
    });
    mocks.addProvider.mockResolvedValueOnce(false);
    render(<LocalComputeSetupHarness />);
    await confirmLocalHttp();
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));
    await screen.findByRole('button', { name: 'connectAndSave' });
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSave' }));

    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect(mocks.routerPush).not.toHaveBeenCalled();
  });
});

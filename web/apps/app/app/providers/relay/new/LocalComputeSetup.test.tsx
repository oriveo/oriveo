import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { LocalComputeSetup } from './LocalComputeSetup';
import { useCustomLLMConnectionCoordinator } from './custom-llm-connection-coordinator';

const mocks = vi.hoisted(() => ({
  connect: vi.fn(),
  fingerprint: vi.fn(),
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

vi.mock('../../../../lib/core/providers/local-browser-probe', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../../lib/core/providers/local-browser-probe')>()),
  connectLocalEngineInBrowser: (...args: unknown[]) => mocks.connect(...args),
  fingerprintLocalEngineInBrowser: (...args: unknown[]) => mocks.fingerprint(...args),
}));

vi.mock('../../../../lib/core/provider-ops', () => ({
  addProvider: (...args: unknown[]) => mocks.addProvider(...args),
}));

vi.mock('../../../../providers/StoreProvider', () => ({
  getVanillaStore: () => ({}),
  // Submission telemetry needs to know whether this is the first provider, so the component subscribes
  // to providers.
  useAppStore: (selector: (state: { providers: unknown[]; setLastUsedModelRef: () => void }) => unknown) =>
    selector({ providers: [], setLastUsedModelRef: () => undefined }),
}));

vi.mock('@oriveo/ui', () => ({
  BackButton: ({ label, onClick }: { label: string; onClick?: () => void }) => (
    <button type="button" aria-label={label} onClick={onClick} />
  ),
  CloseButton: ({ label, onClick }: { label: string; onClick?: () => void }) => (
    <button type="button" aria-label={label} onClick={onClick} />
  ),
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

/** Loopback http is authorized by the address itself; there is no cleartext confirmation switch any more. */
async function enterLoopbackEndpoint() {
  fireEvent.change(screen.getByLabelText('engineAddress'), {
    target: { value: 'http://127.0.0.1:11434' },
  });
  // The address slot shows only the part after the scheme; the scheme goes into the chip.
  await waitFor(() => expect((screen.getByLabelText('engineAddress') as HTMLInputElement).value)
    .toBe('127.0.0.1:11434'));
}

function chooseEngineManually(engine: string) {
  fireEvent.click(screen.getByRole('button', { name: 'localManualEngine' }));
  fireEvent.change(screen.getByLabelText('engine'), { target: { value: engine } });
}

describe('LocalComputeSetup', () => {
  beforeEach(() => {
    Object.defineProperty(window, 'isSecureContext', { configurable: true, value: true });
    mocks.connect.mockReset();
    mocks.fingerprint.mockReset();
    mocks.fingerprint.mockResolvedValue({ outcome: 'engine', engineProfile: 'ollama', channel: 'openai_chat_completions' });
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

  it('authorizes loopback http as local_http by address (no cleartext confirmation switch) and lets the fingerprinted engine drive the connection', async () => {
    render(<LocalComputeSetupHarness />);
    const connect = screen.getByRole('button', { name: 'detectConnectionSettings' }) as HTMLButtonElement;
    expect(screen.queryByRole('button', { name: 'changeConnectionType' })).toBeNull();
    expect(connect.disabled).toBe(true);
    const endpoint = screen.getByLabelText('engineAddress') as HTMLInputElement;
    expect(endpoint.value).toBe('');
    expect(endpoint.placeholder).toBe('127.0.0.1:11434');
    expect(mocks.connect).not.toHaveBeenCalled();

    await enterLoopbackEndpoint();
    expect(connect.disabled).toBe(false);
    fireEvent.click(connect);
    await waitFor(() => expect(mocks.connect).toHaveBeenCalledWith(expect.objectContaining({
      engine: 'ollama',
      endpoint: 'http://127.0.0.1:11434',
      securityMode: 'local_http',
    })));
    expect(mocks.fingerprint).toHaveBeenCalledWith(expect.objectContaining({
      endpoint: 'http://127.0.0.1:11434',
      securityMode: 'local_http',
    }));
  });

  it('local address slot: scheme goes only into the chip; without :// the written scheme is kept; clearing empties everything', async () => {
    render(<LocalComputeSetupHarness />);
    const endpoint = screen.getByLabelText('engineAddress') as HTMLInputElement;
    const chip = () => screen.getByTestId('local-endpoint-scheme').textContent;
    fireEvent.change(endpoint, { target: { value: 'http://192.168.1.20:11434' } });
    await waitFor(() => expect([endpoint.value, chip()]).toEqual(['192.168.1.20:11434', 'http']));
    fireEvent.change(endpoint, { target: { value: '192.168.1.21:11434' } });
    await waitFor(() => expect([endpoint.value, chip()]).toEqual(['192.168.1.21:11434', 'http']));
    fireEvent.change(endpoint, { target: { value: '' } });
    await waitFor(() => expect([endpoint.value, chip()]).toEqual(['', 'https']));
  });

  it('manually choosing an engine only changes the engine, keeps the typed address, and skips fingerprinting', async () => {
    render(<LocalComputeSetupHarness />);
    await enterLoopbackEndpoint();

    chooseEngineManually('lmstudio');

    expect((screen.getByLabelText('engineAddress') as HTMLInputElement).value)
      .toBe('127.0.0.1:11434');
    expect(mocks.connect).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));
    await waitFor(() => expect(mocks.connect).toHaveBeenCalledWith(expect.objectContaining({
      engine: 'lmstudio',
      securityMode: 'local_http',
    })));
    expect(mocks.fingerprint).not.toHaveBeenCalled();
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

    chooseEngineManually('openwebui');
    fireEvent.change(screen.getByLabelText('engineAddress'), { target: { value: 'https://openwebui.example' } });
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

  it('never sends the Open WebUI bearer key over loopback http: the production connector rejects cleartext credentials and makes no request', async () => {
    const actual = await vi.importActual<typeof import('../../../../lib/core/providers/local-browser-probe')>(
      '../../../../lib/core/providers/local-browser-probe',
    );
    mocks.connect.mockImplementationOnce(actual.connectLocalEngineInBrowser);
    const fetchSpy = vi.spyOn(globalThis, 'fetch');
    render(<LocalComputeSetupHarness />);
    chooseEngineManually('openwebui');
    fireEvent.change(screen.getByLabelText('engineAddress'), { target: { value: 'http://127.0.0.1:3000' } });
    fireEvent.change(screen.getByLabelText('apiKeyLabel'), { target: { value: 'openwebui-secret' } });
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));

    expect(await screen.findByText('cleartextCredentialsBlocked')).toBeTruthy();
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(mocks.addProvider).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
  });

  it('aborts the active production connector generation on unmount and keeps every editor disabled while pending', async () => {
    let resolveConnect: ((value: unknown) => void) | undefined;
    mocks.connect.mockReturnValueOnce(new Promise((resolve) => { resolveConnect = resolve; }));
    const view = render(<LocalComputeSetupHarness />);
    await enterLoopbackEndpoint();
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));

    await waitFor(() => expect(mocks.connect).toHaveBeenCalledTimes(1));
    const signal = mocks.connect.mock.calls[0]?.[0]?.signal as AbortSignal;
    expect(signal.aborted).toBe(false);
    expect((screen.getByRole('button', { name: 'localManualEngine' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByLabelText('engineAddress') as HTMLInputElement).disabled).toBe(true);
    // The local page has no default model slot: the verification sample is the first catalog entry, and the connector receives no model hint.
    expect(screen.queryByLabelText('defaultModelLabel')).toBeNull();
    expect(mocks.connect.mock.calls[0]?.[0]?.modelHint).toBeUndefined();

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
    await enterLoopbackEndpoint();
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

  it('writes the engine declaration given by the connector into AIModel.engineDeclaration when registering local models', async () => {
    mocks.connect.mockResolvedValueOnce({
      state: 'ready',
      endpoint: 'http://127.0.0.1:11434',
      modelIDs: ['vision-model', 'plain-model'],
      models: [
        { id: 'vision-model', localLoadState: 'unknown', executionLocality: 'local', engineDeclaration: { image: true, toolCall: false } },
        { id: 'plain-model', localLoadState: 'unknown', executionLocality: 'local' },
      ],
      apiBaseURL: 'http://127.0.0.1:11434/v1',
      generationVerified: true,
    });
    render(<LocalComputeSetupHarness />);
    await enterLoopbackEndpoint();
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));
    fireEvent.click(await screen.findByRole('button', { name: 'connectAndSave' }));

    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    const saved = mocks.addProvider.mock.calls[0]?.[1] as Provider;
    expect(saved.relayRequested?.engineProfile).toBe('ollama');
    expect(saved.models[0]?.engineDeclaration).toEqual({ image: true, toolCall: false });
    expect(saved.models[1]).not.toHaveProperty('engineDeclaration');
    expect(saved.catalogModels[0]?.engineDeclaration).toEqual({ image: true, toolCall: false });
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
    await enterLoopbackEndpoint();
    fireEvent.click(screen.getByRole('button', { name: 'detectConnectionSettings' }));
    await screen.findByRole('button', { name: 'connectAndSave' });
    fireEvent.click(screen.getByRole('button', { name: 'connectAndSave' }));

    await waitFor(() => expect(mocks.addProvider).toHaveBeenCalledTimes(1));
    expect(mocks.routerPush).not.toHaveBeenCalled();
  });
});

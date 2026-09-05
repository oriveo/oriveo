import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  ProviderSetupStep,
  TELEMETRY_KIND_UNSPECIFIED,
  providerKeyValidatedProperties,
  providerSetupAbandonedProperties,
  ProviderSetupSurface,
  TelemetryAuthMode,
  telemetryEndpoint,
  telemetryEndpointHost,
  telemetryModelID,
  telemetryProviderKind,
} from './index';

describe('telemetryEndpoint', () => {
  it('strips credentials, query and fragment that some relays hide tokens in', () => {
    expect(
      telemetryEndpoint('https://alice:secret@Relay.Example.com:8443/v1/?api_key=hidden#frag'),
    ).toBe('https://relay.example.com:8443/v1');
  });

  it('fills in https when the user typed a bare host, matching the real relay parsing', () => {
    expect(telemetryEndpoint('relay.example.com/v1/')).toBe('https://relay.example.com/v1');
    expect(telemetryEndpoint('api.openai.com/v1')).toBe('https://api.openai.com/v1');
  });

  it('returns empty string for missing or non-http input (empty filters better than null)', () => {
    expect(telemetryEndpoint(undefined)).toBe('');
    expect(telemetryEndpoint(null)).toBe('');
    expect(telemetryEndpoint('   ')).toBe('');
    expect(telemetryEndpoint('ftp://relay.example.com')).toBe('');
    expect(telemetryEndpoint('not a url at all')).toBe('');
  });
});

describe('telemetryEndpointHost', () => {
  it('keeps the non-default port so breakdown can tell instances apart', () => {
    expect(telemetryEndpointHost('https://relay.example.com:8443/v1?k=1')).toBe(
      'relay.example.com:8443',
    );
    expect(telemetryEndpointHost('relay.example.com/v1/chat/completions')).toBe(
      'relay.example.com',
    );
  });

  it('returns empty string when the endpoint cannot be parsed', () => {
    expect(telemetryEndpointHost('')).toBe('');
    expect(telemetryEndpointHost('ftp://relay.example.com')).toBe('');
  });
});

describe('provider setup telemetry constants', () => {
  // unspecified (the user has not chosen yet) has to stay distinct from unknown (there should be a
  // value but it could not be read), or the analytics cannot tell browsing from broken telemetry.
  it('separates unspecified from unknown', () => {
    expect(TELEMETRY_KIND_UNSPECIFIED).toBe('unspecified');
    expect(telemetryProviderKind(null)).toBe('unknown');
    expect(TELEMETRY_KIND_UNSPECIFIED).not.toBe(telemetryProviderKind(null));
  });

  // This vocabulary is shared across clients, so a change here has to be made on the other clients too
  it('pins the cross-platform step_reached vocabulary', () => {
    expect(Object.values(ProviderSetupStep)).toEqual([
      'kind_picker',
      'kind_selected',
      'endpoint_entered',
      'api_key_entered',
      'submitting',
    ]);
  });

  it('builds one self-contained diagnostic property set for abandoned setup', () => {
    expect(providerSetupAbandonedProperties({
      providerKind: 'relay',
      stepReached: ProviderSetupStep.endpointEntered,
      endpoint: 'https://alice:secret@Relay.Example.com:8443/v1/?api_key=hidden',
      relayKind: 'codex_style',
      entryPoint: 'providers',
      isFirstProvider: false,
      connectionAttempts: 2,
      lastErrorCode: 'network_timeout',
    })).toEqual({
      provider_kind: 'relay',
      step_reached: 'endpoint_entered',
      endpoint_host: 'relay.example.com:8443',
      endpoint: 'https://relay.example.com:8443/v1',
      relay_kind: 'codex_style',
      entry_point: 'providers',
      is_first_provider: false,
      connection_attempts: 2,
      last_error_code: 'network_timeout',
    });
  });

  // Submit result telemetry: pressing add must carry the same set of diagnostic dimensions whether
  // it succeeds or fails, or a failed add gives no way to tell which endpoint or entry point it
  // got stuck on.
  it('builds one self-contained diagnostic property set for a failed submit', () => {
    expect(providerKeyValidatedProperties({
      providerKind: 'relay',
      success: false,
      errorCode: 'relay_upstream_404',
      endpoint: 'https://alice:secret@Relay.Example.com:8443/v1/?api_key=hidden',
      relayKind: 'openai_compatible',
      entryPoint: 'providers',
      isFirstProvider: true,
      connectionAttempts: 3,
      authMode: TelemetryAuthMode.subscription,
      setupSurface: ProviderSetupSurface.relaySetup,
    })).toEqual({
      provider_kind: 'relay',
      success: false,
      error_code: 'relay_upstream_404',
      endpoint_host: 'relay.example.com:8443',
      endpoint: 'https://relay.example.com:8443/v1',
      relay_kind: 'openai_compatible',
      entry_point: 'providers',
      is_first_provider: true,
      connection_attempts: 3,
      auth_mode: 'subscription',
      setup_surface: 'relay_setup',
    });
  });

  it('reports an empty error code on success instead of faking unknown', () => {
    const properties = providerKeyValidatedProperties({
      providerKind: 'openai',
      success: true,
      endpoint: 'api.openai.com/v1',
      entryPoint: 'onboarding',
      connectionAttempts: 1,
      setupSurface: ProviderSetupSurface.providerSetup,
    });

    expect(properties.error_code).toBe('');
    expect(properties.auth_mode).toBe('api_key');
    expect(properties.endpoint).toBe('https://api.openai.com/v1');
    // When it is unknown whether this is the first provider, the key is omitted rather than invented as false.
    expect('is_first_provider' in properties).toBe(false);
  });

  it('keeps the surface vocabulary aligned across the three clients', () => {
    expect(Object.values(ProviderSetupSurface)).toEqual([
      'provider_setup',
      'relay_setup',
      'local_compute',
    ]);
    expect(Object.values(TelemetryAuthMode)).toEqual(['api_key', 'subscription']);
  });
});

describe('telemetryModelID', () => {
  it('drops the private catalog model ID for relay, since it carries company, project and internal code names and is not an aggregatable dimension', () => {
    expect(telemetryModelID('relay', 'acme-internal/finance-copilot-v3')).toBe('custom');
    expect(telemetryModelID('relay', 'custom')).toBe('custom');
  });

  it('reports the model ID for official providers verbatim, since it comes from a public catalog', () => {
    expect(telemetryModelID('openAI', 'gpt-4o')).toBe('gpt-4o');
    expect(telemetryModelID('openAI', 'qwen-max')).toBe('qwen-max');
    // The placeholder value is chosen by the call site from the event semantics; the helper only reduces the dimension
    expect(telemetryModelID(undefined, 'unknown')).toBe('unknown');
    expect(telemetryModelID(null, 'none')).toBe('none');
  });

  it('routes every telemetry call carrying a model identity through the helper, with no inline relay conditional or bare model.id', () => {
    const root = resolve(process.cwd(), '../../..');
    const emitters = [
      'apps/app/lib/core/chat/send-start.ts',
      'apps/app/lib/core/chat/send-completion.ts',
      'apps/app/lib/core/chat/operations-send.ts',
      'apps/app/lib/core/chat/operations-retry.ts',
      'apps/app/lib/core/chat/operations-edit.ts',
      'apps/app/lib/core/chat/stop-stream.ts',
      'apps/app/lib/core/chat/operations-library-send.ts',
      'apps/app/components/chat/ChatView.tsx',
      'apps/app/components/chat/hooks/useChatModelSelection.ts',
    ];
    for (const file of emitters) {
      const source = readFileSync(resolve(root, 'web', file), 'utf8');
      // An inline condition is exactly how this kind of leak happens: whoever adds a new call site will not remember to repeat it
      expect(source, file).not.toMatch(/'relay'\s*\?\s*'custom'/);
      // The right-hand side of a reported field must never be the model object's id directly
      expect(source, file).not.toMatch(/(from_|to_|served_)?model_id:\s*[\w.?]*\bmodel\??\.id\b/);
    }
  });
});

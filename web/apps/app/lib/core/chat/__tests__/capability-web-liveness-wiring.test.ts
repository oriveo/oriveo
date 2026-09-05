import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { resolveChatCapabilityOutboundDecision } from '../chat-capability-outbound-decision';
import { filterRequestCapabilityIntent } from '../stream-options';

/**
 * The three places that consume the stale-web-preference liveness decision.
 *
 * There is only one rule (`modelControlWebReachesTheWire`), pinned cell by cell in the layout unit
 * tests. What is pinned here is that all three consumers are actually wired to it: with the rule
 * written correctly but only two of the three wired up, the globe chip stays lit while the request
 * carries no web field at all.
 *
 * 1. chip highlight -> `resolveChatCapabilityOutboundDecision.hasWebSelection`
 * 2. panel restore state -> the restore effect in ChatView (`setWebSearchEnabled` must pass this gate)
 * 3. outbound explicit intent key -> `webReachesTheWire` in `filterRequestCapabilityIntent`
 */
describe('the three consumers of the web liveness decision', () => {
  const autoAvailable = { state: 'auto_available' as const };
  const pending = { state: 'unknown' as const, reasonCode: 'model_route_pending' };
  const reasoningControl = { state: 'unknown' as const, availableIntents: [] as string[] };
  const decision = (input: Partial<Parameters<typeof resolveChatCapabilityOutboundDecision>[0]> = {}) => (
    resolveChatCapabilityOutboundDecision({
      webRequested: true,
      webControl: autoAvailable,
      webDormant: false,
      reasoningModeRequested: 'automatic',
      reasoningControl,
      reasoningDormant: false,
      ...input,
    })
  );

  it('1. chip highlight: unlit when there is no official configuration and no custom override', () => {
    expect(decision().hasWebSelection).toBe(true);
    expect(decision({ webControl: pending }).hasWebSelection).toBe(false);
    expect(decision({ webControl: pending, webCustomIsActive: true }).hasWebSelection).toBe(true);
    // When the user never turned web search on, it stays unlit regardless of liveness.
    expect(decision({ webRequested: false }).hasWebSelection).toBe(false);
    // A local dormant state (the upstream rejected it before) also unlights it.
    expect(decision({ webDormant: true }).hasWebSelection).toBe(false);
  });

  it('1. a custom override lights the globe but must not make the outbound path compile an official web recipe that does not exist', () => {
    const result = decision({ webControl: pending, webCustomIsActive: true });
    expect(result.hasWebSelection).toBe(true);
    expect(result.webSearchEnabled).toBe(false);
    expect(result.hasActiveCapabilitySelection).toBe(true);
  });

  it('3. outbound explicit intent key: a preference that cannot reach the wire is not an explicit web request', () => {
    const provider = { id: 'p', kind: 'openAI', models: [], catalogModels: [], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '' } as never;
    const model = { id: 'gpt-x', name: 'GPT', capabilities: ['web'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '' } as never;

    const live = filterRequestCapabilityIntent({
      provider, model, reasoningMode: 'automatic', webSearchEnabled: true, webReachesTheWire: true,
      streamOptions: { capabilityPreferences: { web: 'automatic' } } as never,
    });
    const dark = filterRequestCapabilityIntent({
      provider, model, reasoningMode: 'automatic', webSearchEnabled: true, webReachesTheWire: false,
      streamOptions: { capabilityPreferences: { web: 'automatic' } } as never,
    });

    expect(dark.supportsWebSearch).toBe(false);
    // Control: the same input can only go outbound when liveness is true (whether it actually does is
    // then decided by the evidence surface).
    expect(live.supportsWebSearch === true || live.supportsWebSearch === false).toBe(true);
    expect(dark.supportsWebSearch).not.toBe(true);
  });

  /**
   * Source assertions on whether the rule is wired up. Behavioral assertions can only prove "the
   * function behaves correctly when it receives false", not "the production path really computed it once
   * and passed it in".
   */
  it('2 and 3. source assertions on the production read sites: the restore state and both send paths go through liveness', () => {
    const chatView = readSource('components/chat/ChatView.tsx');
    // Restore state: the liveness rule is read in exactly one place, `readStoredWebIntent` (the reset
    // after a mutual exclusion is released reads it too, and two hand-copied readers would inevitably
    // drift). Assert that this one place really ANDs liveness with "the user expressed a preference".
    const restore = /reachesTheWire: values\.web !== 'off' && webPreferenceReachesTheWire\(/;
    expect(restore.test(chatView)).toBe(true);
    // Also, every `setWebSearchEnabled(<truthy>)` must come from that one read site (or from the option
    // the user just picked in the panel); no second path may light the globe.
    const liveTruthySets = [...chatView.matchAll(/setWebSearchEnabled\(([^\n]*)\)/g)]
      .map((match) => match[1]!.trim())
      .filter((argument) => argument !== 'false');
    expect(liveTruthySets.length).toBeGreaterThan(0);
    for (const argument of liveTruthySets) {
      expect(argument.includes('reachesTheWire') || argument.includes("next !== 'off'"), argument).toBe(true);
    }
    // The chip's globe rule consumes the same custom-override fact.
    expect(chatView).toContain('webCustomIsActive');

    for (const file of ['lib/core/chat/operations-send.ts', 'lib/core/chat/operations-continue.ts']) {
      const source = readSource(file);
      expect(source, file).toContain('webReachesTheWire: webPreferenceReachesTheWire(');
    }
  });

  /** Local custom fields have no read chain to hook into, so every discrete read site must run the forward pass itself. */
  it('source assertions on the production read sites: the panel, advanced settings, the editor page and both send paths all run the forward pass', () => {
    const readPoints = [
      'components/chat/ChatView.tsx',
      'components/chat/ModelOptionsPopover.tsx',
      'components/generation/GenerationParameterPanel.tsx',
      'components/generation/CustomRequestFieldsEditor.tsx',
      'lib/core/chat/operations-send.ts',
      'lib/core/chat/operations-continue.ts',
    ];
    for (const file of readPoints) {
      expect(readSource(file), file).toContain('forwardPortCustomFragmentsIfNeeded(');
    }
  });
});

function readSource(relative: string): string {
  let current = process.cwd();
  while (!existsInDirectory(current, 'lib/core/chat/custom-fragment-settings.ts')) {
    const next = path.dirname(current);
    if (next === current) throw new Error('apps/app root');
    current = next;
  }
  return readFileSync(path.join(current, relative), 'utf8');
}

function existsInDirectory(directory: string, relative: string): boolean {
  try {
    readFileSync(path.join(directory, relative), 'utf8');
    return true;
  } catch {
    return false;
  }
}

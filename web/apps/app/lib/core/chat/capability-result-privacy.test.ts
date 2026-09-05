import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { encodeCapabilityResultContext, type CapabilityResultContext } from './capability-result-runtime';

const context: CapabilityResultContext = {
  version: 1,
  revision: 'runtime-r3',
  entries: [{
    owner: 'web', source: 'provider_recipe', wireApplied: true,
    protocol: 'openai_responses', responseParserKind: 'openai_responses_web_v1',
    definition: { capability: 'web', protocol: 'openai_responses', responseParserKind: 'openai_responses_web_v1', signals: [] },
  }],
};

describe('capability result privacy boundary', () => {
  it('serializes only local execution facts, never provider/model/prompt/response/error or endpoint data', () => {
    const encoded = encodeCapabilityResultContext(context);
    const padded = encoded.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - encoded.length % 4) % 4);
    const payload = JSON.parse(atob(padded)) as Record<string, unknown>;
    expect(Object.keys(payload).sort()).toEqual(['entries', 'revision', 'version']);
    const entries = payload.entries as Array<Record<string, unknown>>;
    expect(Object.keys(entries[0] ?? {}).sort()).toEqual([
      'definition', 'owner', 'protocol', 'responseParserKind', 'source', 'wireApplied',
    ]);
    expect(JSON.stringify(payload)).not.toMatch(/"(provider|model|prompt|response|error|endpoint|path|value|query)"\s*:/i);
  });

  it('does not add capability results to telemetry producers', () => {
    const root = resolve(process.cwd(), '../../..');
    const sources = [
      'web/apps/app/app/api/chat/stream/route.ts',
      'web/apps/app/lib/core/chat/capability-result-runtime.ts',
      'web/apps/app/lib/core/chat/stream-runner.ts',
    ].map((file) => readFileSync(resolve(root, file), 'utf8'));
    expect(sources.join('\n')).not.toMatch(/trackEvent\s*\(/);
  });

  // The boundary is field-level: whether a capability ran never changes which events are emitted,
  // only which fields may be carried. Degrading at the event level would make relay conversations
  // disappear from the dashboard entirely. The behavioural assertions for the attribute contract
  // live in __tests__/chat-lifecycle-telemetry.test.ts.
  it('keeps capability facts out of telemetry by field, never by dropping the whole property bag', () => {
    const root = resolve(process.cwd(), '../../..');
    const send = readFileSync(resolve(root, 'web/apps/app/lib/core/chat/operations-send.ts'), 'utf8');
    const sendStart = readFileSync(resolve(root, 'web/apps/app/lib/core/chat/send-start.ts'), 'utf8');
    const completion = readFileSync(resolve(root, 'web/apps/app/lib/core/chat/send-completion.ts'), 'utf8');
    const continueAnswer = readFileSync(resolve(root, 'web/apps/app/lib/core/chat/operations-continue.ts'), 'utf8');
    // web_search_used is gated at field level on the final outbound options rather than on user
    // intent, and the only attributes are the registered provider_kind / model_id. Both outbound
    // paths, first send and continue, use the same gate and the same shape; the behavioural
    // assertions live in __tests__/chat-lifecycle-telemetry.test.ts.
    expect(send).toMatch(/if \(relayStreamOptions\?\.supportsWebSearch\) \{/);
    expect(continueAnswer).toMatch(/if \(providerStreamOptions\?\.supportsWebSearch\) \{/);
    // No dual-path fork remains: none of the three helpers may emit a bare lifecycle event without attributes
    const bareLifecycleEvent =
      /trackEvent\(\s*['"](chat_started|chat_message_sent|chat_message_completed|chat_message_failed)['"]\s*\)/;
    for (const source of [send, sendStart, completion]) {
      expect(source).not.toMatch(bareLifecycleEvent);
      expect(source).not.toMatch(/hasCapabilityExecutionFacts/);
    }
    // Sentry reporting is a separate, non-telemetry use of p5Failure and stays as it is
    expect(send).toMatch(/shouldReportProviderError\(err\) && !p5Failure/);
  });
});

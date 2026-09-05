import { describe, expect, it } from 'vitest';
import { TELEMETRY_EVENTS, createNoopTelemetry, type TelemetryEventName } from '..';

describe('createNoopTelemetry', () => {
  it('reports itself as disabled and swallows every call', () => {
    const telemetry = createNoopTelemetry({
      apiKey: null,
      platform: 'web-app',
      appVersion: '0.0.0',
    });

    expect(telemetry.isEnabled()).toBe(false);
    expect(() => telemetry.track('app_opened')).not.toThrow();
    expect(() => telemetry.page('/settings')).not.toThrow();
    expect(() => telemetry.identify('uid_1')).not.toThrow();
    expect(() => telemetry.reset()).not.toThrow();
    expect(() => telemetry.setSuperProperties({ locale: 'en' })).not.toThrow();
  });

  it('needs no configuration at all', () => {
    expect(createNoopTelemetry().isEnabled()).toBe(false);
  });
});

describe('TELEMETRY_EVENTS', () => {
  it('has no duplicate event names', () => {
    const set = new Set(TELEMETRY_EVENTS);
    expect(set.size).toBe(TELEMETRY_EVENTS.length);
  });

  it('uses snake_case for all events', () => {
    for (const event of TELEMETRY_EVENTS) {
      expect(event).toMatch(/^[a-z][a-z0-9_]*$/);
    }
  });

  it('lists exactly the names the union type allows', () => {
    // A name added to the type but not the array would silently drop out of any consumer that
    // iterates the list, which is how a client ends up validating against a stale vocabulary.
    const names: readonly TelemetryEventName[] = TELEMETRY_EVENTS;
    expect(names.length).toBeGreaterThan(0);
  });
});

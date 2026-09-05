import { describe, expect, it } from 'vitest';
import { isTransportFailure } from './transport-failure';

/** Build an error shaped like what a browser throws (the name is the criterion, so instanceof and realms do not matter). */
function named(name: string, message: string): Error {
  const error = new Error(message);
  error.name = name;
  return error;
}

describe('isTransportFailure', () => {
  it.each([
    ['Chrome', 'Failed to fetch'],
    ['Chrome + Sentry host suffix', 'Failed to fetch (api.localhost)'],
    ['Safari', 'Load failed'],
    ['Firefox', 'NetworkError when attempting to fetch resource'],
    ['React Native/undici variant', 'Network request failed'],
  ])('recognizes the %s fetch connection failure', (_engine, message) => {
    expect(isTransportFailure(named('TypeError', message))).toBe(true);
  });

  it('recognizes cancellation and timeout by name, independent of wording', () => {
    expect(isTransportFailure(named('AbortError', 'The user aborted a request.'))).toBe(true);
    expect(isTransportFailure(named('TimeoutError', 'any wording'))).toBe(true);
  });

  it('never swallows a real code defect that also happens to be a TypeError', () => {
    // This is the entire reason the criterion narrows on the message: a bare instanceof TypeError
    // would silence real bugs as if the user had gone offline.
    expect(isTransportFailure(named('TypeError', "x.map is not a function"))).toBe(false);
    expect(
      isTransportFailure(named('TypeError', "Cannot read properties of undefined (reading 'id')")),
    ).toBe(false);
  });

  it('ignores non-transport errors and non-objects', () => {
    expect(isTransportFailure(named('Error', 'Failed to fetch'))).toBe(false);
    expect(isTransportFailure('Failed to fetch')).toBe(false);
    expect(isTransportFailure(null)).toBe(false);
    expect(isTransportFailure(undefined)).toBe(false);
  });
});

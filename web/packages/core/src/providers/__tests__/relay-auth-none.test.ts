import { describe, expect, it } from 'vitest';

import {
  applyDirectCustomHeaders,
  applyDirectQueryParams,
  buildDirectAuthHeaders,
} from '../relay-adapter';

describe('Relay auth=none production request builder', () => {
  const config = {
    apiKey: 'must-not-leak',
    transport: 'openai_chat_completions' as const,
    authMode: 'none' as const,
    headers: [
      { key: 'Authorization', value: 'Bearer must-not-leak' },
      { key: 'X-Private-Key', value: 'must-not-leak' },
    ],
    queryParams: [{ key: 'key', value: 'must-not-leak' }],
  };

  it('injects no authorization or API-key header', () => {
    expect(buildDirectAuthHeaders(config.apiKey, config.authMode)).toEqual({});
    expect(applyDirectCustomHeaders({}, config, () => 'uuid')).toEqual({});
  });

  it('injects no key or custom query parameter', () => {
    expect(applyDirectQueryParams('http://192.168.1.20:8080/v1/models', config))
      .toBe('http://192.168.1.20:8080/v1/models');
  });
});

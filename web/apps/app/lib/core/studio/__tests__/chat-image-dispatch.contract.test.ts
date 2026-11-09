// @vitest-environment node
/**
 * Shared fixture chat_image_dispatch.v1.json: every dispatch case runs through the Web
 * decideChatImageDispatch, every studio error kind maps onto the fixture category and
 * the Web chat error kind, and the code constants equal the fixture spec.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  CHAT_IMAGE_ERROR_MAP,
  CHAT_IMAGE_PARAMS,
  chatImageErrorCategory,
  chatImageErrorKind,
  chatStudioBaseUrl,
  decideChatImageDispatch,
  LEGACY_PROVIDER_KINDS,
  STUDIO_ROUTES,
  type ChatImageAttachment,
  type ChatImageFailureKind,
} from '../chat-image-dispatch';
import type { ImageProfile, ImageRoute } from '../image-profile';
import { repoRoot } from '../../../../../../test-support/repo-root';

const ROOT = repoRoot();
const FIXTURE = resolve(ROOT, 'shared/studio-contracts/chat_image_dispatch.v1.json');

interface DispatchCase {
  caseId: string;
  input: {
    providerKind: string;
    modelId: string;
    legacyImageDispatch: boolean;
    profileRef: string | null;
    attachments: ChatImageAttachment[];
  };
  expect: unknown;
}

interface BaseUrlCase {
  caseId: string;
  input: { route: ImageRoute; connectionBaseUrl: string | null };
  expect: { baseUrl: string | null };
}

interface Fixture {
  spec: {
    chatParams: Record<string, unknown>;
    studioRoutes: string[];
    legacyProviderKinds: string[];
    errorMap: Record<string, string>;
  };
  profiles: Record<string, ImageProfile>;
  dispatch: DispatchCase[];
  baseUrl: BaseUrlCase[];
}

const fixture = JSON.parse(readFileSync(FIXTURE, 'utf8')) as Fixture;

const CATEGORY_TO_CHAT_KIND: Record<string, string> = {
  upstream_400: 'badRequest',
  invalid_key: 'invalidKey',
  quota_exceeded: 'quotaExceeded',
  rate_limited: 'rateLimited',
  model_unavailable: 'unavailable',
  upstream_502: 'upstream',
  upstream_507: 'upstream',
  network: 'network',
  empty_response: 'emptyResponse',
};

describe('constants', () => {
  it('studio routes equal spec.studioRoutes', () => {
    expect([...STUDIO_ROUTES]).toEqual(fixture.spec.studioRoutes);
  });

  it('legacy provider kinds equal spec.legacyProviderKinds', () => {
    expect([...LEGACY_PROVIDER_KINDS]).toEqual(fixture.spec.legacyProviderKinds);
  });

  it('chat params equal spec.chatParams', () => {
    expect(CHAT_IMAGE_PARAMS).toEqual(fixture.spec.chatParams);
  });

  it('error map equals spec.errorMap', () => {
    expect(CHAT_IMAGE_ERROR_MAP).toEqual(fixture.spec.errorMap);
  });
});

describe('dispatch', () => {
  it('fixture has dispatch cases', () => {
    expect(fixture.dispatch.length).toBeGreaterThan(0);
  });

  it.each(fixture.dispatch.map((c) => [c.caseId, c] as const))('%s', (_id, c) => {
    const profile = c.input.profileRef === null ? null : fixture.profiles[c.input.profileRef];
    expect(profile).not.toBeUndefined();
    const result = decideChatImageDispatch({
      providerKind: c.input.providerKind,
      legacyImageDispatch: c.input.legacyImageDispatch,
      profile: profile ?? null,
      attachments: c.input.attachments,
    });
    expect(result).toEqual(c.expect);
  });

  it('edit profile without maxReferenceImages takes only the first image', () => {
    const { maxReferenceImages: _dropped, ...profile } = fixture.profiles.openai_gpt_image!;
    const result = decideChatImageDispatch({
      providerKind: 'openAI',
      legacyImageDispatch: true,
      profile,
      attachments: [
        { id: 'a1', mime: 'image/png', hasBytes: true },
        { id: 'a2', mime: 'image/png', hasBytes: true },
      ],
    });
    expect(result).toEqual({
      path: 'studio',
      operation: 'edit',
      images: [{ attachmentId: 'a1', slot: 1, role: 'base' }],
    });
  });
});

describe('baseUrlMatchesFixture', () => {
  it('covers every fixture case', () => {
    expect(fixture.baseUrl.length).toBe(19);
  });

  it.each(fixture.baseUrl.map((c) => [c.caseId, c] as const))('%s', (_id, c) => {
    expect(chatStudioBaseUrl(c.input.route, c.input.connectionBaseUrl)).toBe(c.expect.baseUrl);
  });
});

describe('errorMap', () => {
  const entries = Object.entries(fixture.spec.errorMap) as [ChatImageFailureKind, string][];

  it.each(entries)('%s maps to category %s', (kind, category) => {
    expect(chatImageErrorCategory(kind)).toBe(category);
  });

  it.each(entries)('%s maps to the chat error kind of its category', (kind, category) => {
    const chatKind = CATEGORY_TO_CHAT_KIND[category];
    expect(chatKind).toBeDefined();
    expect(chatImageErrorKind(kind, 'upstream said no')).toBe(chatKind);
    expect(chatImageErrorKind(kind, null)).toBe(chatKind);
  });

  it('refused with moderation_blocked maps to moderation', () => {
    expect(chatImageErrorKind('refused', 'moderation_blocked')).toBe('moderation');
  });

  it('upstream_error with moderation_unavailable maps to moderation', () => {
    expect(chatImageErrorKind('upstream_error', 'moderation_unavailable')).toBe('moderation');
  });

  it('moderation messages on other kinds keep their category', () => {
    expect(chatImageErrorKind('upstream_error', 'moderation_blocked')).toBe('upstream');
    expect(chatImageErrorKind('refused', 'moderation_unavailable')).toBe('badRequest');
    expect(chatImageErrorKind('network', 'moderation_blocked')).toBe('network');
  });
});

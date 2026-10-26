/**
 * Shared vi.mock factory for `lib/core/metadata/metadata-client`.
 *
 * Partial factories (`() => ({ onlySomeExports })`) turn every export they do
 * not list into `undefined`, so any new production call into metadata-client
 * breaks unrelated tests. This factory spreads the real module first and then
 * applies the per-test overrides, keeping the caller's vi.fn handles intact.
 *
 * Importing the real module has no IDB / network side effects (all state is
 * lazy and only touched by init/refresh calls), so no export needs a safety stub.
 *
 * Usage (vi.mock is hoisted, so load the helper lazily inside the factory):
 *   vi.mock('<rel>/metadata-client', async (importOriginal) =>
 *     (await import('<rel>/lib/__tests__/mocks/metadata-client')).metadataClientMock(importOriginal, { ... }));
 */
type MetadataClientModule = typeof import('../../core/metadata/metadata-client');

export type MetadataClientOverrides = Partial<Record<keyof MetadataClientModule, unknown>>;

export async function metadataClientMock(
  importOriginal: <T = unknown>() => Promise<T>,
  overrides: MetadataClientOverrides = {},
): Promise<MetadataClientModule> {
  const actual = await importOriginal<MetadataClientModule>();
  return { ...actual, ...overrides } as MetadataClientModule;
}

/**
 * API key character validation.
 *
 * The implementation lives in `@oriveo/core/providers/key-validation` so that the relay form
 * validator and every key input share one rule; otherwise the same key can be accepted by the
 * form and rejected on save. This file only re-exports it for the renderer side.
 */
export { isPrintableAsciiKey } from '@oriveo/core/providers/key-validation';

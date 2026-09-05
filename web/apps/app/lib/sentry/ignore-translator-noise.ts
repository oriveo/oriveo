import {
  isHydrationErrorEvent,
  type SentryEventLike,
} from "@oriveo/shared";

type QueryRoot = {
  querySelector(selectors: string): unknown;
};

// Internal attributes that Edge/Microsoft Translator leaves on the DOM when it rewrites a page.
// Noise is suppressed only when a hydration error also matches these markers, never by filtering
// out the Edge browser as a whole.
const MICROSOFT_TRANSLATOR_DOM_SELECTOR = [
  "[_msttexthash]",
  "[_msthash]",
  "[_mstmutation]",
  "[_mstaria-label]",
  "[_mstplaceholder]",
].join(",");

function getBrowserDocument(): QueryRoot | null {
  return typeof document === "undefined" ? null : document;
}

export function isIgnorableMicrosoftTranslatorHydration(
  event: SentryEventLike,
  root: QueryRoot | null = getBrowserDocument(),
): boolean {
  if (!isHydrationErrorEvent(event) || !root) return false;

  try {
    return Boolean(root.querySelector(MICROSOFT_TRANSLATOR_DOM_SELECTOR));
  } catch {
    // Keep the event if detection fails, so the noise filter cannot swallow a real error.
    return false;
  }
}

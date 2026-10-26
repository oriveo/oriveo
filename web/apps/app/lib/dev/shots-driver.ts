/**
 * Shared driver helper for screenshot pages (context-shots / memory-shots / relay-shots, ...):
 * wait for an element to appear before clicking production controls.
 */

/** Upper bound for a single wait; on timeout only warn and return null so the shot captures the current frame. */
const DRIVE_TIMEOUT_MS = 10_000;

export interface WaitForElementOptions<T extends Element> {
  /** Warning prefix, e.g. `memory-shots`. */
  label: string;
  /** Optional secondary filter (e.g. by button text, skipping disabled); the first match wins. */
  match?: (element: T) => boolean;
}

/** Wait until an element appears (a data-testid / aria-label / id the production page already carries); returns null on cancel or timeout. */
export function waitForElement<T extends Element>(
  selector: string,
  signal: { cancelled: boolean },
  { label, match }: WaitForElementOptions<T>,
): Promise<T | null> {
  const startedAt = Date.now();
  return new Promise((resolve) => {
    const tick = () => {
      if (signal.cancelled) return resolve(null);
      const element = [...document.querySelectorAll<T>(selector)].find((candidate) => !match || match(candidate));
      if (element) return resolve(element);
      if (Date.now() - startedAt > DRIVE_TIMEOUT_MS) {
        console.warn(`[${label}] timed out waiting for ${selector}`);
        return resolve(null);
      }
      window.setTimeout(tick, 50);
    };
    tick();
  });
}

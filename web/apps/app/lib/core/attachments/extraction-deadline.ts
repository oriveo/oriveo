/**
 * Extraction deadline (attachment extraction output spec section 14): 30 seconds per extraction, timed with a monotonic clock.
 *
 * Each format calls {@link ExtractionDeadline.check} at the start of every loop round (PDF page, zip entry, worksheet, slide,
 * EPUB chapter, every 1000 rows of XLSX / ODS, every 64 KB of RTF input); a single uninterruptible engine call is checked only after it returns.
 * A timeout is reported as `extraction_timeout`.
 */
import { ExtractionError } from './file-text-extractor';

export const EXTRACTION_DEADLINE_MS = 30_000;

/** Monotonic clock returning milliseconds. Defaults to `performance.now()`; tests inject a fake clock. */
export type MonotonicClock = () => number;

const defaultClock: MonotonicClock = () => performance.now();

export class ExtractionDeadline {
  private readonly expiresAt: number;

  constructor(
    private readonly now: MonotonicClock = defaultClock,
    budgetMs: number = EXTRACTION_DEADLINE_MS,
  ) {
    this.expiresAt = now() + budgetMs;
  }

  /** Remaining milliseconds; 0 once expired. */
  get remainingMs(): number {
    return Math.max(0, this.expiresAt - this.now());
  }

  get expired(): boolean {
    return this.now() >= this.expiresAt;
  }

  /** Throws `extraction_timeout` if expired. */
  check(): void {
    if (this.expired) throw new ExtractionError('extraction_timeout');
  }
}

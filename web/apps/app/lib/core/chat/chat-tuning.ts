/**
 * Central home for runtime tuning constants in the chat domain.
 *
 * Magic numbers that would otherwise be scattered across the chat modules are named and
 * documented here so they can be reviewed and adjusted in one place. Only tunable performance and
 * experience knobs belong here, never protocol or business constraints.
 */

// Proactive persistence threshold for long streams: once the accumulated chunks during a stream
// reach either threshold, streamingText is written through to message.text. That write triggers a
// persistence write to IDB and a re-render of every component subscribed to conversations, so the
// threshold cannot be too small. pagehide has its own sessionStorage backup, so this threshold
// mainly covers a browser crash.
export const PARTIAL_FLUSH_THRESHOLD_CHARS = 4000;
export const PARTIAL_FLUSH_THRESHOLD_MS = 60_000;

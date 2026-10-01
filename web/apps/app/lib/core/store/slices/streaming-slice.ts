import type { AppActions } from '../app-store';
import type { AppStoreSet } from './types';

type StreamingActions = Pick<
  AppActions,
  | 'setStreamingText'
  | 'appendStreamingText'
  | 'setStreamingReasoningText'
  | 'appendStreamingReasoningText'
  | 'markStreamingReasoningStarted'
  | 'setStreamingActivity'
  | 'beginStreamingForConversation'
  | 'clearStreamingForConversation'
>;

/**
 * Streaming slice: per-conversation partials held in dictionaries.
 * Consistency rule across the six maps: the keys of streamingConversationIds must stay in sync with
 * streamingTexts, streamingMessageIds, streamingReasoningTexts, streamingReasoningActive and
 * streamingActivities.
 * The only mutation entry points are beginStreamingForConversation and
 * clearStreamingForConversation, each a single set() that maintains the invariant atomically.
 */
export function createStreamingSlice(set: AppStoreSet): StreamingActions {
  return {
    setStreamingText: (convId, text) =>
      set((s) => ({ streamingTexts: { ...s.streamingTexts, [convId]: text } })),
    appendStreamingText: (convId, chunk) =>
      set((s) => ({
        streamingTexts: {
          ...s.streamingTexts,
          [convId]: (s.streamingTexts[convId] ?? '') + chunk,
        },
      })),
    setStreamingReasoningText: (convId, text) =>
      set((s) => ({
        streamingReasoningTexts: { ...s.streamingReasoningTexts, [convId]: text },
      })),
    appendStreamingReasoningText: (convId, chunk) =>
      set((s) => ({
        streamingReasoningTexts: {
          ...s.streamingReasoningTexts,
          [convId]: (s.streamingReasoningTexts[convId] ?? '') + chunk,
        },
      })),
    // Explicit "thinking has started" signal: the criterion is that a reasoning event arrived, not
    // that the text is non-empty. During a long think the upstream only sends empty-string
    // heartbeats (see the AppState.streamingReasoningActive comment), and an empty string has no
    // text to append, so this boolean is the only thing the UI can light "Thinking..." from.
    // Idempotent: once set the original state is returned, avoiding pointless re-renders, since the
    // heartbeats can run for minutes.
    markStreamingReasoningStarted: (convId) =>
      set((s) => {
        if (s.streamingReasoningActive[convId]) return s;
        return {
          streamingReasoningActive: { ...s.streamingReasoningActive, [convId]: true },
        };
      }),
    // Idempotent: the same value keeps the same reference, since several upstream frames can
    // report one search. Only a registered stream is written, so an event that arrives after the
    // clear cannot bring the key back.
    setStreamingActivity: (convId, activity) =>
      set((s) => {
        if (!(convId in s.streamingTexts)) return s;
        if ((s.streamingActivities[convId] ?? null) === activity) return s;
        return { streamingActivities: { ...s.streamingActivities, [convId]: activity } };
      }),
    beginStreamingForConversation: (convId, msgId) =>
      set((s) => {
        const idsHasConv = s.streamingConversationIds.includes(convId);
        return {
          streamingTexts: { ...s.streamingTexts, [convId]: '' },
          streamingReasoningTexts: { ...s.streamingReasoningTexts, [convId]: '' },
          streamingReasoningActive: { ...s.streamingReasoningActive, [convId]: false },
          streamingActivities: { ...s.streamingActivities, [convId]: null },
          streamingMessageIds: { ...s.streamingMessageIds, [convId]: msgId },
          // Only touch the ids reference the first time convId appears, to avoid a pointless re-render
          streamingConversationIds: idsHasConv
            ? s.streamingConversationIds
            : [...s.streamingConversationIds, convId],
        };
      }),
    clearStreamingForConversation: (convId) =>
      set((s) => {
        if (
          !(convId in s.streamingTexts) &&
          !(convId in s.streamingReasoningTexts) &&
          !(convId in s.streamingMessageIds) &&
          !s.streamingConversationIds.includes(convId)
        ) {
          return s;
        }
        const nextTexts = { ...s.streamingTexts };
        const nextReasoning = { ...s.streamingReasoningTexts };
        const nextReasoningActive = { ...s.streamingReasoningActive };
        const nextActivities = { ...s.streamingActivities };
        const nextMsgIds = { ...s.streamingMessageIds };
        delete nextTexts[convId];
        delete nextReasoning[convId];
        delete nextReasoningActive[convId];
        delete nextActivities[convId];
        delete nextMsgIds[convId];
        return {
          streamingTexts: nextTexts,
          streamingReasoningTexts: nextReasoning,
          streamingReasoningActive: nextReasoningActive,
          streamingActivities: nextActivities,
          streamingMessageIds: nextMsgIds,
          streamingConversationIds: s.streamingConversationIds.filter((id) => id !== convId),
        };
      }),
  };
}

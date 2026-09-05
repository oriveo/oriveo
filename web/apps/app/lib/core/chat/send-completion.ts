/**
 * Telemetry and usage reporting helpers for the sendMessage completion path.
 *
 * Used only by operations-send.ts, where moving roughly 60 lines of side effects out here keeps
 * the main transaction function small. The usage reporting branch for continueAnswering is
 * simpler, with no retrievalCost and no image_generated, and deliberately does not reuse this
 * helper so the interface stays narrow.
 */
import type { StoreApi } from "zustand";
import type {
  Attachment,
  AIModel,
  Provider,
  Conversation,
} from "@oriveo/shared";
import type { AppStore } from "../store/app-store";
import type { StreamUsage } from "../providers/types";
import type { CostSource } from "./cost";
import { COST_EPSILON } from "../../utils/format-utils";
import { withErrorReporting } from "../../sentry/report-silent";
import { trackEvent, telemetryProviderKind, telemetryModelID } from "../telemetry";
import { relaySendTelemetryProperties } from "../telemetry/relay-properties";
import { shouldTrackProviderUsage } from "./usage-tracking";

export interface SendCompletionParams {
  store: StoreApi<AppStore>;
  provider: Provider;
  model: AIModel;
  conversationId: string;
  /** Conversation snapshot the stream is bound to: newConv for the first message, otherwise the conversation argument */
  effectiveConversation: Conversation | undefined;
  skillId: string | undefined;
  usage: StreamUsage | undefined;
  /** Total cost including retrievalCost, used for chat_message_completed */
  cost: number;
  costSource: CostSource;
  servedModelID: string | undefined;
  processedAttachments: Attachment[];
  /** Retrieval usage and cost for skill knowledge lookup */
  promptContext: {
    retrievalUsage?: StreamUsage;
    retrievalCost: number;
    retrievalModelId?: string;
  };
  sendStartedAt: number;
  completedAt: string;
}

/** Combines the chat_message_completed and image_generated telemetry into one call for sendMessage. */
export function reportSendCompletion(p: SendCompletionParams): void {
  const {
    store,
    provider,
    model,
    conversationId,
    effectiveConversation,
    skillId,
    usage,
    cost,
    costSource,
    servedModelID,
    processedAttachments,
    promptContext,
    sendStartedAt,
    completedAt,
  } = p;
  const reportedModelID = telemetryModelID(provider.kind, model.id);
  // The model the upstream actually served is also an id from the relay's private catalog, so it
  // is reduced exactly like model_id. When the upstream reported nothing it stays null rather
  // than borrowing the requested id.
  const reportedServedModelID = servedModelID ? telemetryModelID(provider.kind, servedModelID) : null;

  // Field-level boundary: no capability execution facts are reported at all, while the matrix
  // registration fields (provider, model, cost, latency) are always sent. Without them a relay
  // conversation disappears from the dashboards entirely, with no provider_kind to filter on.
  trackEvent("chat_message_completed", {
    provider_kind: telemetryProviderKind(provider.kind),
    model_id: reportedModelID,
    served_model_id: reportedServedModelID,
    prompt_tokens: usage?.prompt_tokens ?? null,
    completion_tokens: usage?.completion_tokens ?? null,
    latency_ms: Date.now() - sendStartedAt,
    cost_usd_micros: Math.round(cost * 1_000_000),
    has_image_output: processedAttachments.length > 0,
    // relay_url / relay_protocol come from the same helper as chat_message_sent, so both dashboards agree
    ...relaySendTelemetryProperties(provider),
  });
  if (processedAttachments.length > 0) {
    trackEvent("image_generated", {
      provider_kind: telemetryProviderKind(provider.kind),
      model_id: reportedModelID,
      image_count: processedAttachments.length,
      duration_ms: Date.now() - sendStartedAt,
    });
  }
}

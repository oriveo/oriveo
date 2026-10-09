import { ADDITIONAL_BODY_ERROR_KIND, validateAdditionalBody } from '@oriveo/core/providers/request-builders/additional-body';
import type { StreamEvent, StreamHandle, StreamOptions } from '../providers/types';
import { additionalBodyRetryEligible } from './additional-body-retry';

/** Only send-path facts such as HTTP status / in-stream frames / events already received enter the decision; the error event itself and metadata do not count as content. */
const NON_CONTENT_EVENT_TYPES = new Set<StreamEvent['type']>(['error', 'model', 'usage', 'done', 'continuation', 'activity']);

export function isUpstreamContentEvent(event: StreamEvent): boolean {
  return !NON_CONTENT_EVENT_TYPES.has(event.type) && !(event.type === 'reasoning' && !event.content);
}

/** Same criterion as proxy-client: the additional body in the outbound options must validate and be non-empty, otherwise the route-side merger will not really merge it. */
export function additionalBodyAppliedTo(options: StreamOptions | undefined): boolean {
  if (!options?.additionalBody) return false;
  const validation = validateAdditionalBody(options.additionalBody.raw);
  return Boolean(validation.accepted && Object.keys(validation.value ?? {}).length > 0);
}

export type AdditionalBodyRetryVerdict = {
  eligible: boolean;
  /** Raw text of the in-stream error frame (already redacted and truncated by the send layer), for the technical details. */
  technicalDetail?: string;
};

/**
 * The library / MCP flows run their own multi-leg loop and bypass stream-runner: on each model leg's stream this records the same set of
 * send-path facts as stream-runner, and on failure hands them to the same `additionalBodyRetryEligible` decision.
 */
export function createAdditionalBodyRetryTap(options: StreamOptions | undefined) {
  const additionalBodyApplied = additionalBodyAppliedTo(options);
  let receivedUpstreamEvent = false;
  let lastError: Extract<StreamEvent, { type: 'error' }> | undefined;
  return {
    wrap(handle: StreamHandle): StreamHandle {
      const stream = handle.stream.pipeThrough(new TransformStream<StreamEvent, StreamEvent>({
        transform(event, controller) {
          if (event.type === 'error') lastError = event;
          else if (isUpstreamContentEvent(event)) receivedUpstreamEvent = true;
          controller.enqueue(event);
        },
      }));
      return { ...handle, stream };
    },
    /** When the failure is not a model leg's error frame / HTTP error (tool execution, library backend, ...) there is no lastError and no way out is offered. */
    resolve(input: { sideEffects: boolean }): AdditionalBodyRetryVerdict {
      if (!lastError) return { eligible: false };
      const eligible = additionalBodyRetryEligible({
        additionalBodyApplied,
        receivedUpstreamEvent,
        sideEffects: input.sideEffects,
        localRejection: lastError.errorKind === ADDITIONAL_BODY_ERROR_KIND,
        ...(lastError.streamErrorFrame
          ? { streamErrorFrame: { classifiedKind: lastError.errorKind } }
          : typeof lastError.status === 'number' ? { httpStatus: lastError.status } : {}),
      });
      return {
        eligible,
        ...(eligible && lastError.streamErrorFrame && lastError.error ? { technicalDetail: lastError.error } : {}),
      };
    },
  };
}

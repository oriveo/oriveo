// MiniMax OpenAI-compatible SSE adapter: turns the <think> text protocol inside content into reasoning events.
import {
  createThinkingTagParserState,
  parseThinkingTaggedDelta,
} from "../transport/thinking-tag-parser";
import { streamResponseHeaders } from "../request-builders/response-utils";

export function adaptMiniMaxChatStream(upstream: Response): Response {
  const source = upstream.body;
  if (!source) {
    return new Response("data: [DONE]\n\n", {
      headers: streamResponseHeaders(),
    });
  }

  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const parser = createThinkingTagParserState();
  let buffer = "";

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const reader = source.getReader();
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          flushMiniMaxBuffer(controller, encoder, false);
        }
        buffer += decoder.decode();
        flushMiniMaxBuffer(controller, encoder, true);
        for (const event of parseThinkingTaggedDelta("", parser, { final: true })) {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
        }
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      } catch (error) {
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({
          type: "error",
          error: error instanceof Error ? error.message : "MiniMax stream failed",
          errorKind: "network",
          source: "network",
        })}\n\n`));
      } finally {
        controller.close();
      }
    },
  });

  function flushMiniMaxBuffer(
    controller: ReadableStreamDefaultController<Uint8Array>,
    encoder: TextEncoder,
    flushRemainder: boolean,
  ) {
    while (true) {
      const separatorIndex = buffer.indexOf("\n\n");
      if (separatorIndex < 0) break;
      const frame = buffer.slice(0, separatorIndex);
      buffer = buffer.slice(separatorIndex + 2);
      enqueueMiniMaxFrame(controller, encoder, frame, parser);
    }

    if (flushRemainder && buffer.trim()) {
      enqueueMiniMaxFrame(controller, encoder, buffer, parser);
      buffer = "";
    }
  }

  return new Response(stream, {
    headers: streamResponseHeaders(),
  });
}

export function enqueueMiniMaxFrame(
  controller: ReadableStreamDefaultController<Uint8Array>,
  encoder: TextEncoder,
  frame: string,
  parser = createThinkingTagParserState(),
): void {
  for (const line of frame.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("data:")) continue;
    const data = trimmed.slice(5).trim();
    if (!data) continue;
    if (data === "[DONE]") continue;
    for (const event of parseMiniMaxChatChunk(data, parser)) {
      controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
    }
  }
}

export function parseMiniMaxChatChunk(
  data: string,
  parser = createThinkingTagParserState(),
): Array<Record<string, unknown>> {
  let chunk: {
    choices?: Array<{
      delta?: {
        content?: unknown;
        reasoning_content?: unknown;
        reasoning?: unknown;
      };
    }>;
    usage?: unknown;
    model?: unknown;
  };
  try {
    chunk = JSON.parse(data);
  } catch {
    return [];
  }

  const events: Array<Record<string, unknown>> = [];
  const delta = chunk.choices?.[0]?.delta;
  const reasoning = delta?.reasoning_content ?? delta?.reasoning;
  // reasoning and content are mutually exclusive within one delta (reasoning_content wins), but
  // the function must not early-return: the usage and model fields at the top level of the same
  // chunk still have to be processed, or a final chunk carrying reasoning would lose the usage
  // numbers and the model name.
  if (typeof reasoning === "string" && reasoning) {
    events.push({ type: "reasoning", content: reasoning });
  } else if (typeof delta?.content === "string" && delta.content) {
    events.push(...parseThinkingTaggedDelta(delta.content, parser));
  }
  if (chunk.usage && typeof chunk.usage === "object") {
    events.push({ type: "usage", usage: chunk.usage });
  }
  if (typeof chunk.model === "string" && chunk.model) {
    events.push({ type: "model", modelID: chunk.model });
  }
  return events;
}

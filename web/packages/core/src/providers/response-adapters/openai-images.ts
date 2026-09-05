// OpenAI Images API response adapter: JSON to an SSE event stream (image / usage / [DONE]).
import type { ImageDownloader } from "../../ports";

export async function adaptOpenAIImagesResponse(
  upstream: Response,
): Promise<Response> {
  const payload = (await upstream.json()) as {
    data?: Array<{ b64_json?: string | null; url?: string | null }>;
    usage?: { input_tokens?: number; output_tokens?: number };
  };

  const events: string[] = [];
  await appendOpenAIImageEvents(events, payload.data ?? []);

  if (payload.usage) {
    const promptTokens = payload.usage.input_tokens ?? 0;
    const completionTokens = payload.usage.output_tokens ?? 0;
    events.push(
      `data: ${JSON.stringify({
        type: "usage",
        usage: {
          prompt_tokens: promptTokens,
          completion_tokens: completionTokens,
          total_tokens: promptTokens + completionTokens,
        },
      })}\n\n`,
    );
  }

  events.push("data: [DONE]\n\n");

  return new Response(events.join(""), {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    },
  });
}

export async function appendOpenAIImageEvents(
  events: string[],
  items: Array<{ b64_json?: string | null; url?: string | null }>,
  downloadImage?: ImageDownloader,
): Promise<void> {
  for (const item of items) {
    if (item.b64_json) {
      events.push(
        `data: ${JSON.stringify({ type: "image", url: `data:image/png;base64,${item.b64_json}` })}\n\n`,
      );
      continue;
    }

    if (!item.url) {
      continue;
    }

    if (!downloadImage) {
      events.push(
        `data: ${JSON.stringify({ type: "image", url: item.url })}\n\n`,
      );
      continue;
    }

    const dataURL = await downloadImage(item.url);
    events.push(
      `data: ${JSON.stringify({ type: "image", url: dataURL ?? item.url })}\n\n`,
    );
  }
}

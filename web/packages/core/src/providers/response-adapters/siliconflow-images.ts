// SiliconFlow Images API response adapter: same schema as the OpenAI format, but the URL has to be downloaded and turned into a data URL.
import { appendOpenAIImageEvents } from "./openai-images";
import type { ImageDownloader } from "../../ports";

export async function adaptSiliconFlowImagesResponse(
  upstream: Response,
  downloadImage?: ImageDownloader,
): Promise<Response> {
  const payload = (await upstream.json()) as {
    data?: Array<{ b64_json?: string | null; url?: string | null }>;
    usage?: { input_tokens?: number; output_tokens?: number };
  };

  const events: string[] = [];
  await appendOpenAIImageEvents(events, payload.data ?? [], downloadImage);

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

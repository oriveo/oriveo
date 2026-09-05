// Qwen DashScope multimodal-generation response adapter: URLs expire after 24h, so download and convert to base64 immediately
import type { ImageDownloader } from "../../ports";

export async function adaptQwenImagesResponse(
  upstream: Response,
  downloadImage?: ImageDownloader,
): Promise<Response> {
  const payload = (await upstream.json()) as {
    output?: {
      choices?: Array<{
        message?: {
          content?: Array<{ image?: string }>;
        };
      }>;
    };
    usage?: { input_tokens?: number; output_tokens?: number };
  };

  const events: string[] = [];

  // Extract the image URL and download it to base64 right away, since DashScope URLs expire
  // after 24h. downloadImage enforces an https allow list plus size and timeout limits (against
  // SSRF) and is injected by the host.
  const imageURL = payload.output?.choices?.[0]?.message?.content?.[0]?.image;
  if (imageURL) {
    const dataURL = downloadImage ? await downloadImage(imageURL) : null;
    // Download failed, URL not on the allow list, or over the limit: fall back to the original URL, which the DashScope client can still fetch within 24h
    events.push(
      `data: ${JSON.stringify({ type: "image", url: dataURL ?? imageURL })}\n\n`,
    );
  }

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

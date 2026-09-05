// MiniMax /image_generation response adapter: base64 or URL results into an SSE event stream
export async function adaptMiniMaxImagesResponse(
  upstream: Response,
): Promise<Response> {
  const payload = (await upstream.json()) as {
    data?: { image_base64?: string[]; image_url?: string[] };
  };

  const events: string[] = [];

  for (const b64 of payload.data?.image_base64 ?? []) {
    events.push(
      `data: ${JSON.stringify({ type: "image", url: `data:image/png;base64,${b64}` })}\n\n`,
    );
  }
  for (const url of payload.data?.image_url ?? []) {
    events.push(`data: ${JSON.stringify({ type: "image", url })}\n\n`);
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

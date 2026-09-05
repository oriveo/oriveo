import { NextRequest } from 'next/server';
import { assertUrlNotSsrf, SsrfBlockedError } from '../../_shared/ssrf-guard';
import { isImagePromptAllowed, MODERATION_BLOCK_MESSAGE } from '../../_shared/moderation';

export const runtime = 'nodejs';

export async function POST(request: NextRequest) {
  let parsed: {
    apiKey: string;
    model?: string;
    prompt: string;
    size?: string;
    quality?: string;
    style?: string;
    baseURL?: string;
    requestDefaults?: Record<string, unknown>;
  };
  try {
    parsed = await request.json();
  } catch {
    return Response.json({ error: 'Invalid JSON body' }, { status: 400 });
  }
  const { apiKey, model, prompt, size, quality, style, baseURL } = parsed;

  if (!apiKey || !prompt) {
    return Response.json({ error: 'Missing required fields' }, { status: 400 });
  }

  // Content moderation: screen the image prompt before it goes upstream, block anything not allowed, and fail closed.
  if (!(await isImagePromptAllowed(prompt))) {
    return Response.json({ error: MODERATION_BLOCK_MESSAGE }, { status: 400 });
  }

  const base = baseURL || 'https://api.openai.com/v1';

  const isGrok = /\/\/api\.x\.ai(\/|$)/i.test(base);

  const requestDefaults = sanitizeImageRequestDefaults(parsed.requestDefaults);
  const body: Record<string, unknown> = {
    n: 1,
    response_format: 'b64_json',
    ...requestDefaults,
    model: model || 'dall-e-3',
    prompt,
  };

  // Grok images/generations does not accept the size, quality or style parameters
  if (!isGrok) {
    body.size = size || (typeof body.size === 'string' ? body.size : '1024x1024');
    if (quality) body.quality = quality;
    if (style) body.style = style;
  } else {
    delete body.size;
    delete body.quality;
    delete body.style;
  }

  const imageURL = `${base}/images/generations`;
  try {
    // SSRF guard: base can come from the caller, so block private, reserved and metadata addresses before fetching.
    await assertUrlNotSsrf(imageURL);
  } catch (error) {
    if (error instanceof SsrfBlockedError) {
      return Response.json({ error: error.message }, { status: 403 });
    }
    throw error;
  }

  try {
    const res = await fetch(imageURL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(body),
      // The SSRF guard only validates the initial URL, so do not follow an upstream 302 to an internal or metadata address; a 3xx falls into the !res.ok branch below.
      redirect: 'manual',
    });

    if (!res.ok) {
      const errorText = await res.text().catch(() => '');
      return Response.json({ error: errorText }, { status: res.status });
    }

    const data = await res.json();
    return Response.json(data);
  } catch {
    return Response.json({ error: 'Failed to generate image' }, { status: 502 });
  }
}

function sanitizeImageRequestDefaults(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  const input = value as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  if (typeof input.size === 'string' && input.size.trim()) out.size = input.size;
  if (typeof input.response_format === 'string' && input.response_format.trim()) {
    out.response_format = input.response_format;
  }
  if (typeof input.n === 'number' && Number.isFinite(input.n) && input.n > 0) {
    out.n = input.n;
  }
  return out;
}

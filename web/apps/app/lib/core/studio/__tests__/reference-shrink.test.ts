// @vitest-environment node
/**
 * Browser reference shrinker with faked createImageBitmap / OffscreenCanvas
 * (vitest has no canvas): checks output size, white flattening before draw,
 * EXIF orientation request and JPEG encode options. Case names are shared
 * across iOS / Android / Web.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { shrinkReferenceImage } from '../reference-shrink';

interface BitmapPlan {
  width: number;
  height: number;
  /** Size after EXIF orientation is applied; defaults to width / height. */
  orientedWidth?: number;
  orientedHeight?: number;
  undecodable?: boolean;
}

interface DrawOp {
  op: 'fillRect' | 'drawImage';
  args: number[];
  fillStyle: string;
}

const JPEG_OUT = Uint8Array.of(0xff, 0xd8, 0xff, 0xd9);
const INPUT = Uint8Array.of(1, 2, 3, 4);

let plan: BitmapPlan;
let bitmapCalls: { type: string; options: ImageBitmapOptions | undefined }[];
let closed: number;
let canvases: FakeCanvas[];
let encodeFails: boolean;

class FakeContext {
  fillStyle = '';
  ops: DrawOp[] = [];

  fillRect(x: number, y: number, w: number, h: number): void {
    this.ops.push({ op: 'fillRect', args: [x, y, w, h], fillStyle: this.fillStyle });
  }

  drawImage(_image: unknown, x: number, y: number, w: number, h: number): void {
    this.ops.push({ op: 'drawImage', args: [x, y, w, h], fillStyle: this.fillStyle });
  }
}

class FakeCanvas {
  readonly ctx = new FakeContext();
  readonly encodeOptions: unknown[] = [];

  constructor(
    readonly width: number,
    readonly height: number,
  ) {
    canvases.push(this);
  }

  getContext(kind: string): FakeContext | null {
    return kind === '2d' ? this.ctx : null;
  }

  async convertToBlob(options: unknown): Promise<Blob> {
    this.encodeOptions.push(options);
    if (encodeFails) throw new Error('EncodingError: encode failed');
    return new Blob([JPEG_OUT], { type: 'image/jpeg' });
  }
}

beforeEach(() => {
  plan = { width: 1, height: 1 };
  bitmapCalls = [];
  closed = 0;
  canvases = [];
  encodeFails = false;
  vi.stubGlobal('OffscreenCanvas', FakeCanvas);
  vi.stubGlobal(
    'createImageBitmap',
    async (source: Blob, options?: ImageBitmapOptions) => {
      bitmapCalls.push({ type: source.type, options });
      if (plan.undecodable) throw new Error('InvalidStateError: undecodable');
      const oriented = options?.imageOrientation === 'from-image';
      return {
        width: oriented ? (plan.orientedWidth ?? plan.width) : plan.width,
        height: oriented ? (plan.orientedHeight ?? plan.height) : plan.height,
        close: () => {
          closed += 1;
        },
      };
    },
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function onlyCanvas(): FakeCanvas {
  expect(canvases).toHaveLength(1);
  return canvases[0]!;
}

describe('shrinkReferenceImage', () => {
  it('shrink.downscales_long_edge', async () => {
    plan = { width: 3000, height: 1500 };
    const result = await shrinkReferenceImage(INPUT, 'image/png');
    expect(result).not.toBeNull();
    expect(result!.mime).toBe('image/jpeg');
    expect(Array.from(result!.data)).toEqual(Array.from(JPEG_OUT));
    expect(bitmapCalls).toEqual([{ type: 'image/png', options: { imageOrientation: 'from-image' } }]);
    const canvas = onlyCanvas();
    expect(Math.abs(canvas.width - 2048)).toBeLessThanOrEqual(1);
    expect(Math.abs(canvas.height - 1024)).toBeLessThanOrEqual(1);
    expect(canvas.ctx.ops.map((o) => o.op)).toEqual(['fillRect', 'drawImage']);
    expect(canvas.ctx.ops[1]!.args).toEqual([0, 0, canvas.width, canvas.height]);
    expect(canvas.encodeOptions).toEqual([{ type: 'image/jpeg', quality: 0.9 }]);
    expect(closed).toBe(1);
  });

  it('shrink.small_not_upscaled', async () => {
    plan = { width: 800, height: 600 };
    const result = await shrinkReferenceImage(INPUT, 'image/png');
    expect(result?.mime).toBe('image/jpeg');
    const canvas = onlyCanvas();
    expect([canvas.width, canvas.height]).toEqual([800, 600]);
    expect(canvas.ctx.ops[1]!.args).toEqual([0, 0, 800, 600]);
    expect(canvas.encodeOptions).toEqual([{ type: 'image/jpeg', quality: 0.9 }]);
  });

  it('shrink.alpha_flattened_white', async () => {
    plan = { width: 64, height: 32 };
    const result = await shrinkReferenceImage(INPUT, 'image/png');
    expect(result?.mime).toBe('image/jpeg');
    const canvas = onlyCanvas();
    const [fill, draw] = canvas.ctx.ops;
    expect(fill).toEqual({ op: 'fillRect', args: [0, 0, 64, 32], fillStyle: '#ffffff' });
    expect(draw!.op).toBe('drawImage');
  });

  it('shrink.exif_applied', async () => {
    plan = { width: 300, height: 100, orientedWidth: 100, orientedHeight: 300 };
    const result = await shrinkReferenceImage(INPUT, 'image/jpeg');
    expect(result?.mime).toBe('image/jpeg');
    expect(bitmapCalls).toEqual([{ type: 'image/jpeg', options: { imageOrientation: 'from-image' } }]);
    const canvas = onlyCanvas();
    expect([canvas.width, canvas.height]).toEqual([100, 300]);
  });

  it('shrink.undecodable_returns_null', async () => {
    plan = { width: 1, height: 1, undecodable: true };
    const result = await shrinkReferenceImage(INPUT, 'image/png');
    expect(result).toBeNull();
    expect(canvases).toHaveLength(0);
  });

  // Web-only case: encoder failure also yields null so the budget keeps the original.
  it('shrink.encode_failure_returns_null', async () => {
    plan = { width: 3000, height: 1500 };
    encodeFails = true;
    const result = await shrinkReferenceImage(INPUT, 'image/png');
    expect(result).toBeNull();
    expect(onlyCanvas().encodeOptions).toEqual([{ type: 'image/jpeg', quality: 0.9 }]);
    expect(closed).toBe(1);
  });

  it('shrink.canvas_unavailable_returns_null', async () => {
    plan = { width: 800, height: 600 };
    vi.stubGlobal('OffscreenCanvas', undefined);
    const result = await shrinkReferenceImage(INPUT, 'image/png');
    expect(result).toBeNull();
    expect(bitmapCalls).toHaveLength(1);
    expect(closed).toBe(1);
  });
});

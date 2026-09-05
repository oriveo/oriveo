/**
 * Image generation UI presets (size, quality, style), consumed by the ImageGeneration component.
 *
 * Generation itself runs through the route-driven path: /api/chat/stream dispatches via
 * request-builders.
 */

export const IMAGE_SIZES = [
  { value: '1024x1024', labelKey: 'sizeSquare' },
  { value: '1792x1024', labelKey: 'sizeWide' },
  { value: '1024x1792', labelKey: 'sizeTall' },
];

export const IMAGE_QUALITIES = [
  { value: 'standard', labelKey: 'qualityStandard' },
  { value: 'hd', labelKey: 'qualityHD' },
];

export const IMAGE_STYLES = [
  { value: 'vivid', labelKey: 'styleVivid' },
  { value: 'natural', labelKey: 'styleNatural' },
];

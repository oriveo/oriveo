/**
 * Geometry of the anchored user-bubble gradient.
 * Gradient height = anchor container height H; with the bubble top at y = t inside the container, in the bubble's own coordinates the gradient starts at y = -t and ends at y = H - t,
 * so the bubble shows only the [t, t + h] slice. Bubbles in the chat list anchor to the viewport through CSS background-attachment: fixed (they do not go through here);
 * bubbles outside the chat list (the theme page preview card) are measured against their container and converted by this function into background-size / background-position.
 */
export interface AnchoredBubbleGradient {
  /** y of the gradient start (top stop) in bubble coordinates. */
  startY: number;
  /** y of the gradient end (bottom stop) in bubble coordinates. */
  endY: number;
  /** CSS applied to the bubble: the gradient fills the container height. */
  backgroundSize: string;
  /** CSS applied to the bubble: aligns container y = t with the bubble top. */
  backgroundPosition: string;
}

export function anchoredBubbleGradient(containerHeight: number, bubbleTop: number): AnchoredBubbleGradient {
  const height = Math.max(0, containerHeight);
  return {
    startY: -bubbleTop,
    endY: height - bubbleTop,
    backgroundSize: `100% ${height}px`,
    backgroundPosition: `0 ${-bubbleTop}px`,
  };
}

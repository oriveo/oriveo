import { describe, expect, it, vi } from "vitest";
import { isIgnorableMicrosoftTranslatorHydration } from "./ignore-translator-noise";

const hydrationEvent = {
  exception: {
    values: [{ value: "Hydration failed because the initial UI does not match the server." }],
  },
};

describe("isIgnorableMicrosoftTranslatorHydration", () => {
  it("filters hydration errors when Microsoft Translator DOM markers exist", () => {
    const querySelector = vi.fn(() => ({ tagName: "FONT" }));

    expect(
      isIgnorableMicrosoftTranslatorHydration(hydrationEvent, { querySelector }),
    ).toBe(true);
    expect(querySelector).toHaveBeenCalledOnce();
  });

  it("keeps hydration errors when the DOM has no translator markers", () => {
    expect(
      isIgnorableMicrosoftTranslatorHydration(hydrationEvent, {
        querySelector: () => null,
      }),
    ).toBe(false);
  });

  it("keeps unrelated runtime errors even when translator markers exist", () => {
    const querySelector = vi.fn(() => ({ tagName: "FONT" }));

    expect(
      isIgnorableMicrosoftTranslatorHydration(
        { exception: { values: [{ value: "TypeError: handler is not a function" }] } },
        { querySelector },
      ),
    ).toBe(false);
    expect(querySelector).not.toHaveBeenCalled();
  });

  it("keeps the event when DOM marker detection fails", () => {
    expect(
      isIgnorableMicrosoftTranslatorHydration(hydrationEvent, {
        querySelector: () => {
          throw new Error("invalid selector environment");
        },
      }),
    ).toBe(false);
  });
});

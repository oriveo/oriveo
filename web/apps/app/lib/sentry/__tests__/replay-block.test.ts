import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { THIRD_PARTY_IFRAME_REPLAY_BLOCK_SELECTORS } from "@oriveo/shared";
import { afterEach, describe, expect, it } from "vitest";

// rrweb decides needBlock with element.matches(blockSelector); Replay joins the block array with commas.
const blockSelector = THIRD_PARTY_IFRAME_REPLAY_BLOCK_SELECTORS.join(",");

function mount(html: string): HTMLIFrameElement {
  document.body.innerHTML = html;
  const iframe = document.querySelector("iframe");
  if (!iframe) throw new Error("fixture has no iframe");
  return iframe;
}

describe("Replay third-party iframe block", () => {
  afterEach(() => {
    document.body.innerHTML = "";
  });

  it("blocks the reCAPTCHA Enterprise badge iframe even before src is assigned", () => {
    // Real reCAPTCHA Enterprise badge markup: div.grecaptcha-logo > iframe[name="a-…"][title="reCAPTCHA"]
    const iframe = mount(
      '<div class="grecaptcha-badge"><div class="grecaptcha-logo"><iframe name="a-xswjsh7ymkec" title="reCAPTCHA"></iframe></div></div>',
    );
    expect(iframe.matches(blockSelector)).toBe(true);
  });

  it("blocks reCAPTCHA and Turnstile iframes by src", () => {
    expect(
      mount('<iframe src="https://www.google.com/recaptcha/enterprise/anchor?k=x"></iframe>').matches(blockSelector),
    ).toBe(true);
    expect(
      mount('<iframe src="https://challenges.cloudflare.com/cdn-cgi/challenge-platform/x"></iframe>').matches(blockSelector),
    ).toBe(true);
  });

  it("leaves first-party iframes recordable", () => {
    expect(mount('<iframe src="/preview/artifact"></iframe>').matches(blockSelector)).toBe(false);
  });

  it("is wired into the app replay integration", () => {
    const appConfig = readFileSync(resolve(__dirname, "../../../instrumentation-client.ts"), "utf8");
    expect(appConfig).toContain("block: [...THIRD_PARTY_IFRAME_REPLAY_BLOCK_SELECTORS]");
  });
});

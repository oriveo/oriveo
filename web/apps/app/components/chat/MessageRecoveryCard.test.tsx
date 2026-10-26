import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { MessageRecoveryCard } from "./MessageRecoveryCard";

// Module-level translator constant: returning a new function on every call makes components that put t in their deps loop forever (it once pegged a worker).
vi.mock("next-intl", () => {
  const translate = (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key;
  return { useTranslations: () => translate };
});

interface RejectionActionCase {
  id: string;
  expect: { action: string | null; secondaryAction?: string };
}

// Fixture shared/test-fixtures/capability/rejection-recovery.v1.json: walk up from the working directory to find the repo root.
const rejectionRecoveryFixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, "shared", "test-fixtures", "capability", "rejection-recovery.v1.json");
    if (existsSync(candidate)) {
      return JSON.parse(readFileSync(candidate, "utf8")) as { actionCases: RejectionActionCase[] };
    }
    dir = path.dirname(dir);
  }
  throw new Error("rejection-recovery.v1.json not found");
})();

describe("MessageRecoveryCard", () => {
  it("renders continue (primary) and regenerate for interrupted messages", () => {
    const onRetry = vi.fn();
    const onContinue = vi.fn();

    render(
      <MessageRecoveryCard
        state="interrupted"
        onRetry={onRetry}
        onContinue={onContinue}
      />,
    );

    // The interrupted state keeps the partial so continuing stays reachable, instead of forcing a full re-answer that discards it
    const continueButton = screen.getByRole("button", { name: "continueBtn" });
    fireEvent.click(continueButton);
    expect(onContinue).toHaveBeenCalledTimes(1);

    const regenerateButton = screen.getByRole("button", {
      name: "regenerateBtn",
    });
    fireEvent.click(regenerateButton);
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it("disables regenerate while the conversation is already sending", () => {
    const onRetry = vi.fn();

    render(
      <MessageRecoveryCard state="interrupted" onRetry={onRetry} disabled />,
    );

    const regenerateButton = screen.getByRole("button", {
      name: "regenerateBtn",
    });
    expect(regenerateButton.getAttribute("disabled")).not.toBeNull();

    fireEvent.click(regenerateButton);

    expect(onRetry).not.toHaveBeenCalled();
  });

  it("uses a Library recovery action instead of retrying a non-recoverable error", () => {
    const onPrimaryAction = vi.fn();
    render(
      <MessageRecoveryCard
        state="failed"
        errorTitle="Library unavailable"
        errorDetail="Reconnect the source."
        primaryActionLabel="Open Library settings"
        onPrimaryAction={onPrimaryAction}
        onRetry={vi.fn()}
      />,
    );

    fireEvent.click(
      screen.getByRole("button", { name: "Open Library settings" }),
    );
    expect(onPrimaryAction).toHaveBeenCalledOnce();
    expect(screen.queryByRole("button", { name: "retryBtn" })).toBeNull();
  });

  it.each(["image", "file", "video"] as const)(
    "offers one-tap resend without %s as the primary action after an upstream media rejection",
    (media) => {
      const onPrimaryAction = vi.fn();
      const onRetry = vi.fn();
      render(
        <MessageRecoveryCard
          state="failed"
          errorSource="provider"
          errorTitle="Provider request failed"
          errorDetail="Unexpected item type in content"
          resendWithoutMedia={media}
          onPrimaryAction={onPrimaryAction}
          onRetry={onRetry}
          onEdit={vi.fn()}
        />,
      );

      // The upstream text is still shown; the primary action is resending without that media, with no separate generic retry.
      expect(screen.getAllByText("Unexpected item type in content").length).toBeGreaterThan(0);
      expect(onPrimaryAction).not.toHaveBeenCalled();
      fireEvent.click(screen.getByRole("button", { name: `resendWithout.${media}` }));
      expect(onPrimaryAction).toHaveBeenCalledOnce();
      expect(onRetry).not.toHaveBeenCalled();
      expect(screen.queryByRole("button", { name: "retryBtn" })).toBeNull();
    },
  );

  // Fixture cases with a one-tap action: exactly two buttons, action first and switch-model after it, always visible; no edit / switch-key / generic retry.
  const ACTION_MEDIA: Record<string, "image" | "file" | "video" | undefined> = {
    resend_without_images: "image",
    resend_without_files: "file",
    resend_without_videos: "video",
  };
  const rejectionActionCases = rejectionRecoveryFixture.actionCases.filter(
    (c) => c.expect.action != null,
  );
  it.each(rejectionActionCases.map((c) => [c.id, c] as const))(
    "REJECTION-RECOVERY-%s card shows action then switch model",
    (_id, c) => {
      expect(c.expect.secondaryAction).toBe("switch_model");
      // Action -> copy: an unknown action in the fixture fails outright instead of silently falling back to the parameter copy.
      const action = c.expect.action as string;
      if (!(action in ACTION_MEDIA) && action !== "resend_without_parameter") {
        throw new Error(`unknown rejection action in fixture: ${action}`);
      }
      const media = ACTION_MEDIA[action];
      const actionLabel = media ? `resendWithout.${media}` : "resendWithoutSetting";
      const onPrimaryAction = vi.fn();
      const onSwitchModel = vi.fn();
      render(
        <MessageRecoveryCard
          state="failed"
          errorSource="provider"
          errorTitle="Provider request failed"
          errorDetail="upstream refused"
          resendWithoutMedia={media}
          primaryActionLabel={media ? undefined : actionLabel}
          onPrimaryAction={onPrimaryAction}
          rejectionRecoveryLayout
          onRetry={vi.fn()}
          onEdit={vi.fn()}
          onSwitchKey={vi.fn()}
          onSwitchModel={onSwitchModel}
        />,
      );

      const actionButtons = screen
        .getAllByRole("button")
        .filter((b) => b.textContent !== "technicalDetails");
      expect(actionButtons.map((b) => b.textContent)).toEqual([actionLabel, "switchModelBtn"]);
      fireEvent.click(actionButtons[1]);
      expect(onSwitchModel).toHaveBeenCalledOnce();
      expect(onPrimaryAction).not.toHaveBeenCalled();
      fireEvent.click(actionButtons[0]);
      expect(onPrimaryAction).toHaveBeenCalledOnce();
      expect(onSwitchModel).toHaveBeenCalledOnce();
    },
  );

  it("does not render the resend-without action without a handler", () => {
    render(
      <MessageRecoveryCard
        state="failed"
        errorTitle="Provider request failed"
        resendWithoutMedia="image"
        onRetry={vi.fn()}
      />,
    );
    expect(screen.queryByRole("button", { name: "resendWithout.image" })).toBeNull();
    expect(screen.getByRole("button", { name: "retryBtn" })).toBeTruthy();
  });

  // ── Localization at render time ─────────────────
  describe("render-time localization", () => {
    it("prefers the render-time copy over the language frozen at failure time", () => {
      render(
        <MessageRecoveryCard
          state="failed"
          // Persisted while the UI was in English, so the copy froze in English
          errorTitle="Rate limit exceeded"
          errorDetail="Too many requests."
          errorKind="rateLimited"
          errorDetailIsLocalized
          onRetry={vi.fn()}
        />,
      );

      expect(screen.getByText("rateLimited.title")).toBeTruthy();
      expect(screen.getByText("rateLimited.message")).toBeTruthy();
      expect(screen.queryByText("Rate limit exceeded")).toBeNull();
    });

    it("falls back to the stored strings for legacy messages without errorKind", () => {
      // The body appears both in the description and in the technical details section, so anchor the assertion to the description
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Balance Too Low"
          errorDetail="Add balance to continue."
          onRetry={vi.fn()}
        />,
      );

      expect(screen.getByText("Balance Too Low")).toBeTruthy();
      expect(container.querySelector("p.description")?.textContent).toBe(
        "Add balance to continue.",
      );
    });

    it("falls back to the stored strings for kinds outside the errors catalog (Library)", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Library needs reconnecting"
          errorDetail="Reconnect the source."
          errorKind="library_needs_reauth"
          onRetry={vi.fn()}
        />,
      );

      // Must not be overridden into a generic provider failure by the mapErrorKindKey upstream fallback
      expect(screen.getByText("Library needs reconnecting")).toBeTruthy();
      expect(container.querySelector("p.description")?.textContent).toBe(
        "Reconnect the source.",
      );
      expect(screen.queryByText("upstream.title")).toBeNull();
    });

    it("keeps the raw Server/SDK detail for non-managed failures while localizing the title", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Network Error"
          errorDetail="fetch failed: ECONNRESET"
          errorKind="network"
          onRetry={vi.fn()}
        />,
      );

      expect(screen.getByText("network.title")).toBeTruthy();
      // Raw upstream errors are not wrapped in a localized template
      expect(container.querySelector("p.description")?.textContent).toBe(
        "fetch failed: ECONNRESET",
      );
      expect(screen.queryByText("network.message")).toBeNull();
    });

    // A relay can pass OpenRouter's `429 | Provider returned error` through verbatim, so that
    // English string ends up in the body while the title has to be localized copy of our own.
    it("replaces Oriveo-owned technical text with localized copy and keeps the raw string for diagnosis", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Rate Limited"
          errorDetail="429 | Provider returned error"
          errorKind="rateLimited"
          errorSource="oriveo"
          detailIsInternalTechnicalText
          onRetry={vi.fn()}
          onSwitchModel={vi.fn()}
        />,
      );

      expect(screen.getByText("rateLimited.title")).toBeTruthy();
      expect(container.querySelector("p.description")?.textContent).toBe(
        "rateLimited.message",
      );
      // The original text is preserved, only demoted into the technical details section
      expect(screen.getByText("429 | Provider returned error")).toBeTruthy();
      // Both rate-limit ways out are still present
      expect(screen.getByRole("button", { name: "retryBtn" })).toBeTruthy();
      expect(screen.getByRole("button", { name: "switchModelBtn" })).toBeTruthy();
    });

    // Managed path with no network. After normalizing to network the body must read as a connection check,
    // not the engine's `Failed to fetch`.
    it("localizes a transport failure body instead of showing the raw engine wording", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Network Error"
          errorDetail="Failed to fetch"
          errorKind="network"
          errorSource="network"
          detailIsInternalTechnicalText
          onRetry={vi.fn()}
        />,
      );

      expect(screen.getByText("network.title")).toBeTruthy();
      expect(container.querySelector("p.description")?.textContent).toBe(
        "network.message",
      );
      expect(screen.getByRole("button", { name: "retryBtn" })).toBeTruthy();
    });

    // The upstream text of a subscription 426 is written for CLI users (`grok update`). The
    // failure card shows the app's own actionable copy (use an API key, or switch models) and
    // keeps the upstream text out of the body.
    it("shows the localized subscription copy instead of the upstream CLI instruction", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Grok Subscription Unavailable"
          errorDetail="ClientVersionRejected | Your Grok CLI version (1.0.4) is outdated. Please update to version 1.0.13 or later via `grok update`"
          errorKind="grokSubscriptionUnavailable"
          errorSource="oriveo"
          detailIsInternalTechnicalText
          onRetry={vi.fn()}
          onSwitchModel={vi.fn()}
        />,
      );
      expect(screen.getByText("grokSubscriptionUnavailable.title")).toBeTruthy();
      const body = container.querySelector("p.description")?.textContent ?? "";
      expect(body).toBe("grokSubscriptionUnavailable.message");
      expect(body).not.toContain("grok update");
      // The upstream text stays only in the technical details, collapsed by default, for
      // troubleshooting, the same way other app-sourced failures are handled.
      expect(screen.getByText(/grok update/)).toBeTruthy();
      expect(screen.getByRole("button", { name: "switchModelBtn" })).toBeTruthy();
    });

    it("never localizes an upstream provider body away, even when asked", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Request Failed"
          errorDetail="engine_overloaded_error | The engine is currently overloaded"
          errorKind="rateLimited"
          errorSource="provider"
          detailIsInternalTechnicalText
          onRetry={vi.fn()}
        />,
      );

      // Provider text is the only source of truth for the body: copyKey is always null for source=provider,
      // so this case is unaffected by the new switch.
      expect(container.querySelector("p.description")?.textContent).toBe(
        "engine_overloaded_error | The engine is currently overloaded",
      );
    });

    it("does not rewrite a provider response title from its recovery kind", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Request Failed"
          errorDetail="engine_overloaded_error | The engine is currently overloaded"
          errorKind="rateLimited"
          errorSource="provider"
          onRetry={vi.fn()}
          onSwitchModel={vi.fn()}
        />,
      );

      expect(screen.getByText("Request Failed")).toBeTruthy();
      expect(screen.queryByText("rateLimited.title")).toBeNull();
      expect(container.querySelector("p.description")?.textContent).toBe(
        "engine_overloaded_error | The engine is currently overloaded",
      );
      // kind still only drives the recovery action and never rewrites copy.
      expect(screen.getByRole("button", { name: "switchModelBtn" })).toBeTruthy();
    });
  });
});

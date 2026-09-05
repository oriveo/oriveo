import type { ReactNode } from "react";
import { useState } from "react";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  LibraryDocumentRef,
  LibraryProvider,
} from "../../lib/core/library/types";
import { LibraryContextPicker } from "./LibraryContextPicker";

const mocks = vi.hoisted(() => ({
  executeLibraryTool: vi.fn(),
}));

const HARNESS_SOURCES: LibraryProvider[] = ["notion", "google"];

vi.mock("../../lib/core/library/api", () => ({
  executeLibraryTool: (...args: unknown[]) => mocks.executeLibraryTool(...args),
}));

vi.mock("next-intl", () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}:${Object.values(values).join(":")}` : key,
}));

vi.mock("@oriveo/ui", () => ({
  Button: ({ children, onClick }: { children: ReactNode; onClick?: () => void }) => (
    <button type="button" onClick={onClick}>{children}</button>
  ),
  Dialog: ({ open, children }: { open: boolean; children: ReactNode }) =>
    open ? <div role="dialog">{children}</div> : null,
}));

function Harness({
  open = true,
  onClose = vi.fn(),
  onQuota,
  researchAvailable = true,
  researchServerSide = false,
  researchUnavailableReason,
  remainingResearches = null,
  maxDocuments = 12,
}: {
  open?: boolean;
  onClose?: () => void;
  onQuota?: (quota: { used: number; limit: number; remaining: number }) => void;
  researchAvailable?: boolean;
  researchServerSide?: boolean;
  researchUnavailableReason?: "serverDisabled" | "providerDenied" | "modelUnsupported";
  remainingResearches?: number | null;
  maxDocuments?: number;
}) {
  const [selected, setSelected] = useState<LibraryDocumentRef[]>([]);
  const [researchEnabled, setResearchEnabled] = useState(false);
  return (
    <LibraryContextPicker
      open={open}
      sources={HARNESS_SOURCES}
      selected={selected}
      researchAvailable={researchAvailable}
      researchServerSide={researchServerSide}
      researchUnavailableReason={researchUnavailableReason}
      researchEnabled={researchEnabled}
      onResearchEnabledChange={setResearchEnabled}
      remainingResearches={remainingResearches}
      maxDocuments={maxDocuments}
      onChange={setSelected}
      onClose={onClose}
      onQuota={onQuota}
    />
  );
}

describe("LibraryContextPicker", () => {
  beforeEach(() => {
    mocks.executeLibraryTool.mockReset();
    mocks.executeLibraryTool.mockImplementation((tool: string, args: { source?: string }) => {
      if (tool === "library_list" && args.source === "notion") {
        return Promise.resolve({
          result: {
            items: [{ id: "n-1", title: "Notion Roadmap", url: "https://www.notion.so/n-1" }],
          },
        });
      }
      if (tool === "library_list") {
        return Promise.resolve({
          result: {
            items: [{ id: "g-1", title: "Google Brief", url: "https://docs.google.com/document/d/g-1" }],
          },
        });
      }
      return Promise.resolve({ result: { hits: [] } });
    });
  });

  it("lists both connected sources and toggles concrete document selection", async () => {
    render(<Harness />);

    expect(await screen.findByText("Notion Roadmap")).toBeTruthy();
    expect(screen.getByText("Google Brief")).toBeTruthy();

    const row = screen.getByRole("button", { name: /Notion Roadmap/ });
    expect(row.getAttribute("aria-pressed")).toBe("false");
    fireEvent.click(row);

    await waitFor(() => expect(
      screen.getByRole("button", { name: /Notion Roadmap/ }).getAttribute("aria-pressed"),
    ).toBe("true"));
    expect(screen.getByText("contextPickerSelected:1")).toBeTruthy();
  });

  // The over-limit feedback has to happen at selection time: previously the only signal was a provider 400 after sending
  it("stops selection at the document limit and explains why", async () => {
    render(<Harness maxDocuments={1} />);

    fireEvent.click(await screen.findByRole("button", { name: /Notion Roadmap/ }));

    await waitFor(() => expect(
      screen.getByText("contextPickerLimitReached:1"),
    ).toBeTruthy());
    expect(screen.getByText("contextPickerSelectionCount:1:1")).toBeTruthy();

    const blocked = screen.getByRole("button", { name: /Google Brief/ }) as HTMLButtonElement;
    expect(blocked.disabled).toBe(true);
    fireEvent.click(blocked);
    expect(blocked.getAttribute("aria-pressed")).toBe("false");

    // Deselecting one allows selecting again, so the limit is not a dead end
    fireEvent.click(screen.getByRole("button", { name: /Notion Roadmap/ }));
    await waitFor(() => expect(
      (screen.getByRole("button", { name: /Google Brief/ }) as HTMLButtonElement).disabled,
    ).toBe(false));
  });

  it("searches only the connected sources", async () => {
    render(<Harness />);
    await screen.findByText("Notion Roadmap");
    mocks.executeLibraryTool.mockResolvedValueOnce({
      result: {
        hits: [{
          docId: "g-search",
          source: "google",
          title: "Launch Notes",
          url: "https://docs.google.com/document/d/g-search",
        }],
      },
    });

    fireEvent.change(screen.getByRole("textbox"), { target: { value: "launch" } });
    fireEvent.submit(screen.getByRole("textbox").closest("form")!);

    expect(await screen.findByText("Launch Notes")).toBeTruthy();
    expect(mocks.executeLibraryTool).toHaveBeenLastCalledWith(
      "library_search",
      { query: "launch", sources: ["notion", "google"], limit: 30 },
      expect.any(AbortSignal),
    );
  });

  it("resets pagination loading when closed during a load-more request", async () => {
    mocks.executeLibraryTool.mockImplementation(
      (tool: string, args: { source?: string; cursor?: string }, signal: AbortSignal) => {
        if (tool === "library_list" && args.cursor) {
          return new Promise((_resolve, reject) => {
            signal.addEventListener(
              "abort",
              () => reject(new DOMException("Aborted", "AbortError")),
              { once: true },
            );
          });
        }
        if (tool === "library_list" && args.source === "notion") {
          return Promise.resolve({
            result: {
              items: [{ id: "n-1", title: "Notion Roadmap" }],
              nextCursor: "notion-page-2",
            },
          });
        }
        return Promise.resolve({ result: { items: [] } });
      },
    );

    const { rerender } = render(<Harness open />);
    const loadMore = await screen.findByRole("button", {
      name: "contextPickerLoadMore:Notion",
    });
    fireEvent.click(loadMore);
    expect((screen.getByRole("button", {
      name: "contextPickerLoading",
    }) as HTMLButtonElement).disabled).toBe(true);

    rerender(<Harness open={false} />);
    rerender(<Harness open />);

    const reopenedLoadMore = await screen.findByRole("button", {
      name: "contextPickerLoadMore:Notion",
    });
    await waitFor(() => {
      expect((reopenedLoadMore as HTMLButtonElement).disabled).toBe(false);
    });
  });

  it("ignores quota from an obsolete root request", async () => {
    const rootResolvers: Array<(value: unknown) => void> = [];
    const onQuota = vi.fn();
    mocks.executeLibraryTool.mockImplementation((tool: string) => {
      if (tool === "library_list") {
        return new Promise((resolve) => rootResolvers.push(resolve));
      }
      return Promise.resolve({
        result: { hits: [] },
        quota: { used: 7, limit: 100, remaining: 93 },
      });
    });

    render(<Harness onQuota={onQuota} />);
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "new" } });
    fireEvent.submit(screen.getByRole("textbox").closest("form")!);

    await waitFor(() => expect(onQuota).toHaveBeenCalledWith({
      used: 7,
      limit: 100,
      remaining: 93,
    }));

    rootResolvers.forEach((resolve) => resolve({
      result: { items: [] },
      quota: { used: 1, limit: 100, remaining: 99 },
    }));
    await Promise.resolve();
    await Promise.resolve();

    expect(onQuota).toHaveBeenCalledTimes(1);
  });

  // A model that does not support agentic retrieval while server-side retrieval is available used to
  // be greyed out along with everything else, so the user only saw "this model does not support
  // automatic retrieval" while retrieval was in fact still possible, just on the server.
  it("stays enabled when server-side retrieval is available and shows the server-side wording", async () => {
    render(<Harness researchAvailable researchServerSide />);
    await screen.findByText("Notion Roadmap");

    const scope = screen.getByText("searchMyLibrary").closest("button");
    expect(scope?.hasAttribute("disabled")).toBe(false);
    expect(screen.getByText("searchMyLibraryServerHint")).toBeTruthy();
    expect(screen.queryByText("researchUnavailableHint")).toBeNull();
  });

  it("the agent path keeps the original wording; only when both are unavailable is it greyed out", async () => {
    const { rerender } = render(<Harness researchAvailable />);
    await screen.findByText("Notion Roadmap");
    expect(screen.getByText("searchMyLibraryHint")).toBeTruthy();

    rerender(<Harness researchAvailable={false} />);
    expect(screen.getByText("researchUnavailableHint")).toBeTruthy();
    expect(
      screen.getByText("searchMyLibrary").closest("button")?.hasAttribute("disabled"),
    ).toBe(true);
  });

  // The unavailability reason gets its own copy depending on whether it is the backend master
  // switch, the provider blocklist, or the model not supporting it; they may not all collapse into a single researchUnavailableHint.
  it("routes the unavailability reason for serverDisabled and providerDenied to dedicated copy", async () => {
    const { rerender } = render(
      <Harness researchAvailable={false} researchUnavailableReason="serverDisabled" />,
    );
    await screen.findByText("Notion Roadmap");
    expect(screen.getByText("researchDisabledHint")).toBeTruthy();
    expect(screen.queryByText("researchUnavailableHint")).toBeNull();

    rerender(
      <Harness researchAvailable={false} researchUnavailableReason="providerDenied" />,
    );
    expect(screen.getByText("researchProviderDeniedHint")).toBeTruthy();
    expect(screen.queryByText("researchUnavailableHint")).toBeNull();

    // modelUnsupported and a missing reason both keep the existing generic copy, with no new branch
    rerender(
      <Harness researchAvailable={false} researchUnavailableReason="modelUnsupported" />,
    );
    expect(screen.getByText("researchUnavailableHint")).toBeTruthy();
  });

  // The scope row checkbox used to not render at all when researchAvailable=false, leaving it one
  // column short of the document rows below so the checkboxes did not line up and the layout looked
  // broken. It now keeps a placeholder checkbox and greys it out instead.
  it("keeps a greyed-out placeholder checkbox when research is unavailable, with the reason still shown", async () => {
    const { rerender } = render(<Harness researchAvailable />);
    await screen.findByText("Notion Roadmap");

    const scopeBox = () =>
      screen.getByText("searchMyLibrary").closest("button")!.querySelector(".selection");

    expect(scopeBox()).not.toBeNull();
    expect(scopeBox()!.hasAttribute("data-disabled")).toBe(false);

    rerender(
      <Harness researchAvailable={false} researchUnavailableReason="serverDisabled" />,
    );

    // The entry point is still there (the placeholder did not disappear), it is only greyed out
    expect(scopeBox()).not.toBeNull();
    expect(scopeBox()!.getAttribute("data-disabled")).toBe("true");
    // and a reason has to be given, since an entry point that exists but is unavailable must explain why
    expect(screen.getByText("researchDisabledHint")).toBeTruthy();

    // Same column as the document rows: both row types have a checkbox, and the scope row must not be missing one
    const documentBoxes = screen
      .getByRole("button", { name: /Notion Roadmap/ })
      .querySelectorAll(".selection");
    expect(documentBoxes.length).toBe(1);
  });

  it("shows no check mark when unavailable, so a stale enabled state is not rendered as active", async () => {
    const { rerender } = render(<Harness researchAvailable />);
    await screen.findByText("Notion Roadmap");

    fireEvent.click(screen.getByText("searchMyLibrary").closest("button")!);
    const scopeBox = () =>
      screen.getByText("searchMyLibrary").closest("button")!.querySelector(".selection")!;
    await waitFor(() => expect(scopeBox().childElementCount).toBe(1));

    rerender(<Harness researchAvailable={false} />);
    expect(scopeBox().childElementCount).toBe(0);
  });
});

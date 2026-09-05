import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatMessage, Provider } from "@oriveo/shared";
import { MessageBubble } from "./MessageBubble";

const {
  mockCreateModelDisplayLookup,
  mockPreviewFileAttachment,
  mockLoadFilePreviewUtils,
  mockShowToast,
} = vi.hoisted(() => ({
  mockCreateModelDisplayLookup: vi.fn(),
  mockPreviewFileAttachment: vi.fn(),
  mockLoadFilePreviewUtils: vi.fn(),
  mockShowToast: vi.fn(),
}));

const { mockRouterPush, mockRouterRefresh } = vi.hoisted(() => ({
  mockRouterPush: vi.fn(),
  mockRouterRefresh: vi.fn(),
}));

const { mockHandleContextMenu } = vi.hoisted(() => ({
  mockHandleContextMenu: vi.fn(),
}));

const { mockAcknowledgeManagedPrivacy } = vi.hoisted(() => ({
  mockAcknowledgeManagedPrivacy: vi.fn(),
}));

const libraryFeatureFlagMock = vi.hoisted(() => ({ enabled: true }));

vi.mock("../../lib/core/library/feature-flag", () => ({
  isLibraryFeatureEnabled: () => libraryFeatureFlagMock.enabled,
}));

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: mockRouterPush, refresh: mockRouterRefresh }),
}));

vi.mock("next-intl", () => ({
  useTranslations: () => (key: string) => key,
  // MessageMeta.tsx pulls in useLocale, so this mock has to provide it; without it the suite fails
  // with No "useLocale" export ... even though production is fine.
  useLocale: () => "en",
}));

vi.mock("@oriveo/config", () => ({
  getProviderDisplayName: () => "OpenAI",
}));

vi.mock("@oriveo/ui", () => ({
  FileIcon: () => <span data-testid="file-icon" />,
  // MessageTokenUsageDialog uses Dialog, so it needs a mock here too.
  // Shaped like the ones in ChatView.test.tsx and LibraryConfirmationDialog.test.tsx.
  Dialog: ({ open, children }: { open: boolean; children: React.ReactNode }) =>
    open ? <div role="dialog">{children}</div> : null,
}));

vi.mock("../../lib/utils/format-utils", () => ({
  formatCost: () => null,
}));

vi.mock("./MarkdownRenderer", () => ({
  MarkdownRenderer: ({ content }: { content: string }) => <div>{content}</div>,
}));

vi.mock("./MessageActions", () => ({
  MessageActions: () => <div data-testid="message-actions" />,
}));

vi.mock("./TypingIndicator", () => ({
  TypingIndicator: () => <div data-testid="typing-indicator" />,
}));

vi.mock("./MessageRecoveryCard", () => ({
  MessageRecoveryCard: ({
    onRetry,
    onContinue,
    primaryActionLabel,
    onPrimaryAction,
  }: {
    onRetry?: () => void;
    onContinue?: () => void;
    primaryActionLabel?: string;
    onPrimaryAction?: () => void;
  }) => (
    <div data-testid="message-recovery-card">
      {onRetry ? (
        <button type="button" onClick={onRetry}>
          regenerateBtn
        </button>
      ) : null}
      {onContinue ? (
        <button type="button" onClick={onContinue}>
          continueBtn
        </button>
      ) : null}
      {primaryActionLabel && onPrimaryAction ? (
        <button type="button" onClick={onPrimaryAction}>
          {primaryActionLabel}
        </button>
      ) : null}
    </div>
  ),
}));

vi.mock("../ContextMenu", () => ({
  ContextMenu: () => null,
  useContextMenu: () => ({
    menu: null,
    handleContextMenu: mockHandleContextMenu,
    closeMenu: vi.fn(),
  }),
}));

vi.mock("../ProviderIcon", () => ({
  ProviderIcon: ({
    kind,
    size,
    bare,
  }: {
    kind: string;
    size?: number;
    bare?: boolean;
  }) => (
    <span
      data-testid="provider-icon"
      data-kind={kind}
      data-size={size ?? ""}
      data-bare={bare ? "true" : "false"}
    />
  ),
}));

vi.mock("../../lib/utils/file-preview-utils-lazy", () => ({
  loadFilePreviewUtils: mockLoadFilePreviewUtils,
}));

vi.mock("../../lib/hooks/useMessageEdit", () => ({
  useMessageEdit: () => ({
    editing: false,
    editText: "",
    setEditText: vi.fn(),
    handleStartEdit: vi.fn(),
    handleCancelEdit: vi.fn(),
    handleSubmitEdit: vi.fn(),
    handleEditKeyDown: vi.fn(),
  }),
}));

const mockSetPreferences = vi.fn();
let mockHasSeenNoteCaptureHint = false;

vi.mock("../../providers/StoreProvider", () => ({
  useAppStore: (
    selector: (state: {
      account: null;
      preferences: { hasSeenNoteCaptureHint?: boolean };
      setPreferences: ReturnType<typeof vi.fn>;
      conversations: unknown[];
      providers: unknown[];
    }) => unknown,
  ) =>
    selector({
      account: null,
      preferences: { hasSeenNoteCaptureHint: mockHasSeenNoteCaptureHint },
      setPreferences: mockSetPreferences,
      conversations: [],
      providers: [],
    }),
  getVanillaStore: () => ({ getState: () => ({}) }),
}));

vi.mock("../Toast", () => ({
  showToast: (...args: unknown[]) => mockShowToast(...args),
}));

vi.mock("./AttachmentImage", () => ({
  AttachmentImage: () => <div data-testid="attachment-image" />,
}));

vi.mock("../common/UserAvatar", () => ({
  UserAvatar: () => <div data-testid="user-avatar" />,
}));

vi.mock("../../lib/core/providers/model-display-lookup", () => ({
  createModelDisplayLookup: mockCreateModelDisplayLookup,
}));

const provider: Provider = {
  id: "provider-1",
  kind: "openAI",
  status: { kind: "connected" },
  models: [],
  catalogModels: [],
  apiKey: "sk-test",
  apiKeyPreview: "sk-...test",
};

const baseMessage: ChatMessage = {
  id: "message-1",
  role: "assistant",
  text: "Hello",
  providerID: "provider-1",
  providerKind: "openAI",
  providerName: "OpenAI",
  modelID: "gpt-4o-2024-08-06",
  modelName: "Persisted Model Name",
  state: "delivered",
  estimatedCost: 0,
};

const imageAttachment = {
  id: "attachment-1",
  kind: "image" as const,
  fileName: "image-01.png",
  mimeType: "image/png",
  base64Data: "ZmFrZQ==",
};

const fileAttachment = {
  id: "attachment-file-1",
  kind: "file" as const,
  fileName: "report.pdf",
  mimeType: "application/pdf",
  base64Data: "ZmFrZQ==",
};

describe("MessageBubble", () => {
  it("renders a sent QuoteContext snapshot with a distinct read-only presentation", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue({
        modelId: "gpt-4o",
        canonicalModelId: "gpt-4o",
        displayName: "GPT-4o",
      }),
    });
    const { container } = render(
      <MessageBubble
        message={{
          ...baseMessage,
          role: "user",
          text: "Continue this",
          quoteContext: {
            schemaVersion: 1,
            sourceMessageId: "deleted-source-still-viewable",
            sourceRole: "assistant",
            contentKind: "prose",
            leadingText: "before ",
            selectedText: "snapshot survives",
            trailingText: " after",
            contextTruncated: false,
          },
        }}
        provider={provider}
      />,
    );

    expect(container.querySelector('[data-presentation="sent"]')).not.toBeNull();
    expect(screen.getByRole("button", { name: /snapshot survives/ })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "quoteRemove" })).toBeNull();
  });

  beforeEach(() => {
    mockCreateModelDisplayLookup.mockReset();
    mockPreviewFileAttachment.mockReset();
    mockLoadFilePreviewUtils.mockReset();
    mockShowToast.mockReset();
    mockRouterPush.mockReset();
    mockRouterRefresh.mockReset();
    mockHandleContextMenu.mockReset();
    mockAcknowledgeManagedPrivacy.mockReset();
    mockAcknowledgeManagedPrivacy.mockResolvedValue({
      acknowledgedAt: "2026-05-12T00:00:00.000Z",
      clientAckVersion: "managed-privacy-v1",
    });
    mockSetPreferences.mockReset();
    mockHasSeenNoteCaptureHint = false;
    libraryFeatureFlagMock.enabled = true;
    mockLoadFilePreviewUtils.mockResolvedValue({
      previewFileAttachment: mockPreviewFileAttachment,
    });
  });

  it("uses model display lookup results for assistant metadata", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue({
        modelId: "gpt-4o",
        canonicalModelId: "gpt-4o",
        displayName: "GPT-4o Latest",
      }),
    });

    render(<MessageBubble message={baseMessage} provider={provider} />);

    expect(screen.getAllByText("GPT-4o Latest").length).toBeGreaterThan(0);
    expect(mockCreateModelDisplayLookup).toHaveBeenCalledWith(provider);
  });

  it("falls back to the persisted message model name when lookup returns nothing", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(<MessageBubble message={baseMessage} provider={provider} />);

    expect(screen.getAllByText("Persisted Model Name").length).toBeGreaterThan(
      0,
    );
  });

  it("renders a compact single-image gallery for assistant generated images", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{ ...baseMessage, attachments: [imageAttachment] }}
        provider={provider}
      />,
    );

    const gallery = screen.getByRole("list");
    expect(gallery.getAttribute("data-layout")).toBe("single");
    expect(screen.getAllByRole("listitem")).toHaveLength(1);
  });

  it("renders assistant generated images as a grid when there are multiple images", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{
          ...baseMessage,
          attachments: [
            imageAttachment,
            {
              ...imageAttachment,
              id: "attachment-2",
              fileName: "image-02.png",
            },
          ],
        }}
        provider={provider}
      />,
    );

    const gallery = screen.getByRole("list");
    expect(gallery.getAttribute("data-layout")).toBe("grid");
    expect(screen.getAllByRole("listitem")).toHaveLength(2);
  });

  it("renders only the assistant avatar as a provider badge", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(<MessageBubble message={baseMessage} provider={provider} />);

    const icons = screen.getAllByTestId("provider-icon");
    expect(icons).toHaveLength(1);

    expect(icons[0].getAttribute("data-kind")).toBe("openAI");
    expect(icons[0].getAttribute("data-size")).toBe("28");
    expect(icons[0].getAttribute("data-bare")).toBe("true");
  });

  it("shows the interrupted recovery card only when it is the conversation last message", () => {
    // The recovery card is only shown on the last message of a conversation, so stopping A and then sending B cannot let a continue on A overwrite B.
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });
    const { rerender } = render(
      <MessageBubble
        message={{ ...baseMessage, role: "assistant", state: "interrupted" }}
        provider={provider}
        onContinue={vi.fn()}
        isLastMessage
      />,
    );
    expect(screen.getByTestId("message-recovery-card")).toBeTruthy();

    // Once the conversation moves on and this is not the last message, the recovery card disappears, so continuing an interrupted message in the middle cannot delete what follows
    rerender(
      <MessageBubble
        message={{ ...baseMessage, role: "assistant", state: "interrupted" }}
        provider={provider}
        onContinue={vi.fn()}
        isLastMessage={false}
      />,
    );
    expect(screen.queryByTestId("message-recovery-card")).toBeNull();
  });

  it("disables interrupted regenerate while managed settlement is pending, but keeps continue enabled", () => {
    // Regeneration is blocked while a pending charge settles: resending mints a new clientRequestId
    // and a new hold, so the original pending would settle into a double charge. continue and resume
    // extend the partial instead and are unaffected.
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });
    render(
      <MessageBubble
        message={{
          ...baseMessage,
          role: "assistant",
          state: "interrupted",
          managedSettlementStatus: "pending",
        }}
        provider={provider}
        onContinue={vi.fn()}
        onRetry={vi.fn()}
        isLastMessage
      />,
    );

    expect(screen.queryByRole("button", { name: "regenerateBtn" })).toBeNull();
    expect(screen.getByRole("button", { name: "continueBtn" })).toBeTruthy();
  });

  it("keeps interrupted regenerate enabled once managed settlement is no longer pending", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });
    render(
      <MessageBubble
        message={{
          ...baseMessage,
          role: "assistant",
          state: "interrupted",
          managedSettlementStatus: "completed",
        }}
        provider={provider}
        onContinue={vi.fn()}
        onRetry={vi.fn()}
        isLastMessage
      />,
    );

    expect(screen.getByRole("button", { name: "regenerateBtn" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "continueBtn" })).toBeTruthy();
  });

  it("does not duplicate the generating status in the assistant header", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{ ...baseMessage, state: "generating", text: "" }}
        provider={provider}
        streamingText=""
      />,
    );

    expect(screen.getByText("Persisted Model Name")).toBeTruthy();
    expect(screen.getByTestId("typing-indicator")).toBeTruthy();
    expect(screen.queryByText("generating")).toBeNull();
  });

  it("removes delivered assistant regenerate affordances while another request is in flight", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={baseMessage}
        provider={provider}
        onRetry={vi.fn()}
        interactionLocked
      />,
    );

    expect(screen.queryByRole("button", { name: "retry" })).toBeNull();
  });

  it("shows assistant metadata actions as understandable labels instead of icon-only controls", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={baseMessage}
        provider={provider}
        conversationId="conv-1"
        onRetry={vi.fn()}
      />,
    );

    const copyButton = screen.getByRole("button", { name: "copy" });
    expect(copyButton.getAttribute("aria-label")).toBe("copy");
    expect(
      screen.getByRole("button", { name: "saveAsNote" }).textContent,
    ).toContain("saveAsNote");
    expect(screen.getByRole("button", { name: "more" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "retry" })).toBeNull();
    expect(
      screen.queryByRole("button", { name: "crosscheckAction" }),
    ).toBeNull();
  });

  it("keeps the user message context menu scoped to copy, note, and edit actions", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{ ...baseMessage, role: "user", text: "Can you repeat that?" }}
        provider={provider}
        conversationId="conv-1"
        onEditAndResend={vi.fn()}
      />,
    );

    fireEvent.contextMenu(screen.getByRole("article"));

    const items = mockHandleContextMenu.mock.calls[0]?.[1] as
      Array<{ label: string }> | undefined;
    expect(items?.map((item) => item.label).slice(0, 2)).toEqual([
      "copy",
      "saveAsNote",
    ]);
    expect(items?.map((item) => item.label)).toEqual([
      "copy",
      "saveAsNote",
      "editAndResend",
    ]);
  });

  it("does not open the whole-message context menu while text is selected inside the message", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{
          ...baseMessage,
          role: "assistant",
          text: "Selected assistant answer",
        }}
        provider={provider}
        conversationId="conv-1"
        onRetry={vi.fn()}
      />,
    );

    const article = screen.getByRole("article");
    const getSelectionSpy = vi.spyOn(window, "getSelection").mockReturnValue({
      rangeCount: 1,
      isCollapsed: false,
      anchorNode: article,
      focusNode: article,
      toString: () => "Selected assistant answer",
    } as unknown as Selection);

    fireEvent.contextMenu(article);

    expect(mockHandleContextMenu).not.toHaveBeenCalled();
    getSelectionSpy.mockRestore();
  });

  it("shows the note capture hint the first time a delivered assistant answer can be saved", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={baseMessage}
        provider={provider}
        conversationId="conv-1"
      />,
    );

    expect(mockShowToast).toHaveBeenCalledWith(
      "noteCaptureHint",
      4000,
      undefined,
      "success",
    );
    expect(mockSetPreferences).toHaveBeenCalledWith({
      hasSeenNoteCaptureHint: true,
    });
  });

  it("does not repeat the note capture hint after it has been seen", () => {
    mockHasSeenNoteCaptureHint = true;
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={baseMessage}
        provider={provider}
        conversationId="conv-1"
      />,
    );

    expect(mockShowToast).not.toHaveBeenCalled();
    expect(mockSetPreferences).not.toHaveBeenCalled();
  });

  it("loads file preview helpers lazily when opening a user attachment", async () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{
          ...baseMessage,
          role: "user",
          attachments: [fileAttachment],
        }}
        provider={provider}
      />,
    );

    screen.getByRole("button", { name: "report.pdf" }).click();

    expect(mockLoadFilePreviewUtils).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => {
      expect(mockPreviewFileAttachment).toHaveBeenCalledWith(
        expect.objectContaining({ id: "attachment-file-1", kind: "file" }),
        expect.any(Function),
        expect.any(Function),
      );
    });
  });

  it("folds multiple saved notes into one badge with a dropdown that routes to note detail", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={baseMessage}
        provider={provider}
        savedNoteRefs={[
          { id: "note-1", title: "First saved note" },
          { id: "note-2", title: "Second saved note" },
        ]}
      />,
    );

    // Several notes collapse into one chip showing the first title plus "+1", with the dropdown closed by default
    const badge = screen.getByRole("button", { name: /First saved note/ });
    expect(badge.textContent).toContain("+1");
    expect(screen.queryByRole("menuitem")).toBeNull();

    // Open the dropdown, list every note, and click the second one to jump to its detail
    fireEvent.click(badge);
    fireEvent.click(
      screen.getByRole("menuitem", { name: /Second saved note/ }),
    );
    expect(mockRouterPush).toHaveBeenCalledWith("/notes/note-2");
  });

  it('offers a user-confirmed retry without custom fields without claiming a capability rejection', () => {
    mockCreateModelDisplayLookup.mockReturnValue({ resolve: vi.fn().mockReturnValue(null) });
    const onRetryWithoutCustom = vi.fn();
    render(
      <MessageBubble
        message={{
          ...baseMessage,
          id: 'assistant-custom-failure',
          state: 'failed',
          errorTitle: 'requestFailed.title',
          errorDetail: 'ordinary provider failure',
          capabilityResults: [{ owner: 'generation', state: 'requested', source: 'custom', revision: 'runtime-r3' }],
          capabilityRecovery: {
            version: 1,
            action: 'user_confirmed_resend_without_located_setting',
            source: 'custom',
            owners: ['generation'],
            locatedPointers: [],
          },
        }}
        provider={provider}
        onRetryWithoutCustom={onRetryWithoutCustom}
        isLastMessage
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'resendWithoutSetting' }));
    expect(onRetryWithoutCustom).toHaveBeenCalledTimes(1);
  });

  // library_not_connected (never connected to any source) and needs_reauth offer the same action,
  // since for the user both mean the document source has to be reconnected before an answer can
  // be produced.
  it.each([
    ["library_needs_reauth"],
    ["library_not_connected"],
  ])(
    "offers a retry as the Library recovery action for %s",
    (errorKind) => {
      mockCreateModelDisplayLookup.mockReturnValue({
        resolve: vi.fn().mockReturnValue(null),
      });
      const onRetry = vi.fn();
      render(
        <MessageBubble
          message={{
            ...baseMessage,
            id: `assistant-${errorKind}`,
            state: "failed",
            errorTitle: "researchErrorTitle",
            errorDetail: "localized detail",
            errorKind,
          }}
          provider={provider}
          onRetry={onRetry}
          isLastMessage
        />,
      );

      fireEvent.click(screen.getByRole("button", { name: "error.retry" }));
      expect(onRetry).toHaveBeenCalledTimes(1);
    },
  );

  it("hides Library research metadata and recovery actions when the feature is disabled", () => {
    libraryFeatureFlagMock.enabled = false;
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{
          ...baseMessage,
          state: "failed",
          errorTitle: "researchErrorTitle",
          errorKind: "library_needs_reauth",
          researchSteps: [{
            tool: "library_search",
            label: "Roadmap",
            status: "completed",
          }],
          citations: [{
            url: "https://www.notion.so/roadmap",
            title: "Roadmap",
            source: "notion",
            docId: "roadmap",
          }],
        }}
        provider={provider}
        onRetry={vi.fn()}
        isLastMessage
      />,
    );

    expect(screen.queryByText("progress.complete")).toBeNull();
    expect(screen.queryByText("citationsLabel")).toBeNull();
    expect(screen.queryByText("disclaimer")).toBeNull();
    expect(screen.queryByRole("button", { name: "error.retry" })).toBeNull();
    expect(screen.getByTestId("message-recovery-card")).toBeTruthy();
  });

  it("renders library_not_searched as a static Tool Call row", () => {
    mockCreateModelDisplayLookup.mockReturnValue({ resolve: vi.fn().mockReturnValue(null) });
    render(
      <MessageBubble
        message={{ ...baseMessage, toolFallbackNotice: "library_not_searched" }}
        provider={provider}
      />,
    );

    const notice = screen.getByTestId("tool-fallback-notice");
    expect(notice.textContent).toContain("toolFallbackLibraryNotSearched");
    expect(notice.querySelector("button")).toBeNull();
    expect(notice.querySelector('[aria-expanded]')).toBeNull();
  });

  it("lets an unhandled tool card win over fallback notice and ignores web_recovered", () => {
    mockCreateModelDisplayLookup.mockReturnValue({ resolve: vi.fn().mockReturnValue(null) });
    const view = render(
      <MessageBubble
        message={{
          ...baseMessage,
          toolFallbackNotice: "library_not_searched",
          unhandledToolCalls: [{ id: "call-1", name: "weather", arguments: "{}" }],
        }}
        provider={provider}
      />,
    );

    expect(screen.getByTestId("unhandled-tool-call-card")).toBeTruthy();
    expect(screen.queryByTestId("tool-fallback-notice")).toBeNull();

    view.rerender(
      <MessageBubble
        message={{ ...baseMessage, toolFallbackNotice: "web_recovered" }}
        provider={provider}
      />,
    );
    expect(screen.queryByTestId("tool-fallback-notice")).toBeNull();
    expect(screen.queryByTestId("unhandled-tool-call-card")).toBeNull();
  });
});

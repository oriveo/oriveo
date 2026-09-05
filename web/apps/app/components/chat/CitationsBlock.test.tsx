import { render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { CitationsBlock } from "./CitationsBlock";

vi.mock("next-intl", () => ({
  useTranslations: () => (key: string, values?: { count?: number }) =>
    values?.count == null ? key : `${key}:${values.count}`,
}));

describe("CitationsBlock link safety", () => {
  it("renders only HTTPS citation destinations", () => {
    const { container } = render(
      <CitationsBlock
        citations={[
          { url: "https://www.notion.so/page", title: "Safe" },
          { url: "javascript:alert(1)", title: "Script" },
          { url: "http://internal.example/page", title: "Plain HTTP" },
        ]}
      />,
    );

    const links = Array.from(container.querySelectorAll("a"));
    expect(links).toHaveLength(1);
    expect(links[0]?.getAttribute("href")).toBe("https://www.notion.so/page");
    expect(container.textContent).not.toContain("Script");
    expect(container.textContent).not.toContain("Plain HTTP");
  });

  it("does not load provider-supplied favicon URLs", () => {
    const { container } = render(
      <CitationsBlock
        citations={[
          {
            url: "https://www.notion.so/page",
            title: "Notion",
            faviconUrl: "https://attacker.example/track",
          },
        ]}
      />,
    );

    expect(container.querySelector("img")?.getAttribute("src")).not.toContain(
      "attacker.example",
    );
  });

  it("renders a Library identity without turning its local reference into a link", () => {
    const { container } = render(
      <CitationsBlock
        citations={[
          {
            url: "library-context://notion/doc-1",
            title: "Private plan",
            docId: "doc-1",
            source: "notion",
          },
        ]}
      />,
    );

    expect(container.textContent).toContain("Private plan");
    expect(container.querySelector("a")).toBeNull();
    expect(container.querySelector('[data-library-context-ref="true"]')).toBeTruthy();
  });

  it("renders Library source, edited date, and redacted snippet without a remote favicon", () => {
    const { container } = render(
      <CitationsBlock
        citations={[
          {
            url: "https://www.notion.so/roadmap",
            title: "Roadmap",
            source: "notion",
            lastEdited: "2026-07-24T10:00:00Z",
            snippet: "Launch timing with [REDACTED_SECRET].",
          },
        ]}
      />,
    );

    expect(container.textContent).toContain("Notion");
    expect(container.textContent).toContain(
      "Launch timing with [REDACTED_SECRET].",
    );
    expect(container.querySelector("time")?.getAttribute("datetime")).toBe(
      "2026-07-24T10:00:00Z",
    );
    expect(container.querySelector("img")).toBeNull();
    expect(
      container.querySelector('[data-library-source="notion"]'),
    ).toBeTruthy();
  });
});

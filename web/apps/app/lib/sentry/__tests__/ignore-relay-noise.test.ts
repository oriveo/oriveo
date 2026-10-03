import { describe, expect, it } from "vitest";
import type { Event } from "@sentry/nextjs";
import {
  isIgnorableMcpProtectiveAbort,
  isIgnorableRelayProtectiveAbort,
  isIgnorableStreamDisconnect,
} from "../ignore-relay-noise";

function buildEvent(values: Array<{ type?: string; value?: string }>): Event {
  return { exception: { values } } as unknown as Event;
}

function buildEventWithTransaction(
  transaction: string | undefined,
  values: Array<{ type?: string; value?: string }>,
): Event {
  return { transaction, exception: { values } } as unknown as Event;
}

describe("isIgnorableRelayProtectiveAbort", () => {
  it("matches idle timeout from cause chain", () => {
    const event = buildEvent([
      { type: "Error", value: "failed to pipe response" },
      { type: "Error", value: "Relay stream idle timeout (no data for 90 seconds)" },
    ]);
    expect(isIgnorableRelayProtectiveAbort(event)).toBe(true);
  });

  it("matches total duration cap", () => {
    const event = buildEvent([
      { type: "Error", value: "Relay stream exceeded maximum duration of 600 seconds" },
    ]);
    expect(isIgnorableRelayProtectiveAbort(event)).toBe(true);
  });

  it("matches response size limit", () => {
    const event = buildEvent([
      { type: "Error", value: "Relay response exceeded the 10MB limit" },
    ]);
    expect(isIgnorableRelayProtectiveAbort(event)).toBe(true);
  });

  it("does not match unrelated relay errors", () => {
    const event = buildEvent([
      { type: "Error", value: "Relay upstream request aborted" },
      { type: "Error", value: "ECONNRESET" },
    ]);
    expect(isIgnorableRelayProtectiveAbort(event)).toBe(false);
  });

  it("does not match generic pipe errors without relay cause", () => {
    const event = buildEvent([{ type: "Error", value: "failed to pipe response" }]);
    expect(isIgnorableRelayProtectiveAbort(event)).toBe(false);
  });

  it("returns false on event without exception", () => {
    expect(isIgnorableRelayProtectiveAbort({} as Event)).toBe(false);
  });
});

describe("isIgnorableStreamDisconnect", () => {
  it("drops ECONNRESET → terminated → failed to pipe response on the chat stream route", () => {
    const event = buildEventWithTransaction("POST /api/chat/stream", [
      { type: "Error", value: "read ECONNRESET" },
      { type: "TypeError", value: "terminated" },
      { type: "Error", value: "failed to pipe response" },
    ]);
    expect(isIgnorableStreamDisconnect(event)).toBe(true);
  });

  it("drops undici terminated on the relay forward route", () => {
    const event = buildEventWithTransaction("POST /api/relay/forward", [
      { type: "TypeError", value: "terminated" },
    ]);
    expect(isIgnorableStreamDisconnect(event)).toBe(true);
  });

  it("keeps ECONNRESET on a non-stream route (avoid swallowing real failures)", () => {
    const event = buildEventWithTransaction("GET /bundled-provider-catalog", [
      { type: "Error", value: "read ECONNRESET" },
    ]);
    expect(isIgnorableStreamDisconnect(event)).toBe(false);
  });

  it("keeps a genuine 500 on the stream route (no disconnect signal in chain)", () => {
    const event = buildEventWithTransaction("POST /api/chat/stream", [
      { type: "TypeError", value: "Cannot read properties of undefined (reading 'foo')" },
    ]);
    expect(isIgnorableStreamDisconnect(event)).toBe(false);
  });

  it("does not drop a bare failed-to-pipe without a real disconnect cause", () => {
    const event = buildEventWithTransaction("POST /api/chat/stream", [
      { type: "Error", value: "failed to pipe response" },
    ]);
    expect(isIgnorableStreamDisconnect(event)).toBe(false);
  });

  it("returns false when transaction is missing", () => {
    const event = buildEventWithTransaction(undefined, [
      { type: "Error", value: "read ECONNRESET" },
    ]);
    expect(isIgnorableStreamDisconnect(event)).toBe(false);
  });
});

describe("isIgnorableMcpProtectiveAbort", () => {
  it("drops the event when an MCP protective abort appears in the cause chain", () => {
    for (const message of [
      "MCP stream idle timeout (no data for 90 seconds)",
      "MCP stream exceeded maximum duration of 600 seconds",
      "MCP response exceeded the 8MB limit",
      "MCP upstream request aborted",
    ]) {
      const event = buildEvent([
        { type: "Error", value: "failed to pipe response" },
        { type: "Error", value: message },
      ]);
      expect(isIgnorableMcpProtectiveAbort(event), message).toBe(true);
    }
  });

  it("keeps other errors on the MCP route and does not treat Relay messages as its own", () => {
    expect(isIgnorableMcpProtectiveAbort(buildEvent([{ type: "TypeError", value: "x is not a function" }]))).toBe(false);
    expect(
      isIgnorableMcpProtectiveAbort(buildEvent([{ type: "Error", value: "Relay stream idle timeout (no data for 90 seconds)" }])),
    ).toBe(false);
    expect(isIgnorableMcpProtectiveAbort(buildEvent([{ type: "Error", value: "Upstream said: MCP stream idle timeout" }]))).toBe(false);
    expect(isIgnorableMcpProtectiveAbort({} as Event)).toBe(false);
  });
});

describe("isIgnorableStreamDisconnect on the MCP forward route", () => {
  it("drops mid-stream disconnects for all three methods", () => {
    for (const transaction of ["POST /api/mcp/forward", "GET /api/mcp/forward", "DELETE /api/mcp/forward"]) {
      for (const value of ["read ECONNRESET", "terminated", "aborted"]) {
        expect(
          isIgnorableStreamDisconnect(buildEventWithTransaction(transaction, [{ type: "Error", value }])),
          `${transaction} ${value}`,
        ).toBe(true);
      }
    }
  });

  it("still reports a real 500 on the MCP route", () => {
    const event = buildEventWithTransaction("POST /api/mcp/forward", [
      { type: "TypeError", value: "Cannot read properties of undefined (reading 'foo')" },
    ]);
    expect(isIgnorableStreamDisconnect(event)).toBe(false);
  });

  it("matches aborted only as the whole string and keeps other messages containing the word", () => {
    const event = buildEventWithTransaction("POST /api/mcp/forward", [
      { type: "Error", value: "Transaction aborted by user code" },
    ]);
    expect(isIgnorableStreamDisconnect(event)).toBe(false);
  });
});

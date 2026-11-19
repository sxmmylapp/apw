import { assertEquals } from "@std/assert";
import bridgeSource from "../ext/bridge.js" with { type: "text" };

// Runs the real ext/bridge.js against stand-ins for the Apple extension globals it drives.
function load(state: string) {
  const sent: Record<string, unknown>[] = [];
  const calls: string[] = [];
  let socket: { onmessage?: (e: { data: string }) => void; send: (s: string) => void; readyState: number } | undefined;
  class FakeWS {
    static OPEN = 1;
    readyState = 1;
    onmessage?: (e: { data: string }) => void;
    onopen?: () => void;
    constructor() {
      socket = this;
    }
    send(s: string) {
      sent.push(JSON.parse(s));
    }
    close() {}
  }
  const g = {
    self: { APW_CONFIG: { port: 1, token: "t" } },
    WebSocket: FakeWS,
    g_theState: state,
    g_nativeAppPort: { onMessage: { addListener() {} }, postMessage() {} },
    g_secretSession: {},
    ChallengePIN: () => calls.push("ChallengePIN"),
    PINSet: (pin: string) => calls.push(`PINSet ${pin}`),
    connectToBackgroundNativeAppAndSetUpListeners: () => {},
    setTimeout: () => 0,
  };
  new Function(...Object.keys(g), bridgeSource)(...Object.values(g));
  const ask = (m: Record<string, unknown>) => socket!.onmessage!({ data: JSON.stringify(m) });
  return { sent, calls, ask };
}

Deno.test("a PIN sent to a paired session is ignored (a stale code used to unpair apw)", () => {
  const b = load("SessionKeySet");
  b.ask({ id: "1", cmd: 2, pin: "227621" });
  assertEquals(b.calls, []);
  assertEquals(b.sent.at(-1), { id: "1", status: 0, state: "SessionKeySet" });
});

Deno.test("a PIN with no challenge pending is refused, not fed to the SRP session", () => {
  const b = load("NotInSession");
  b.ask({ id: "1", cmd: 2, pin: "227621" });
  assertEquals(b.calls, []);
  assertEquals(b.sent.at(-1)?.status, 2);
});

Deno.test("a PIN while the helper waits for one (MSG1Set) is set", () => {
  const b = load("MSG1Set");
  b.ask({ id: "1", cmd: 2, pin: "227621" });
  assertEquals(b.calls, ["PINSet 227621"]);
});

Deno.test("auth request on a paired session does not restart pairing", () => {
  const b = load("SessionKeySet");
  b.ask({ id: "1", cmd: 2 });
  assertEquals(b.calls, []);
});

Deno.test("APW_STATUS reports the extension's pairing state", () => {
  const b = load("MSG1Set");
  b.ask({ id: "9", cmd: 4040 });
  assertEquals(b.sent.at(-1), { id: "9", status: 0, state: "MSG1Set", nativePort: true });
});

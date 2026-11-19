import { APWError, BROWSER_PID_PATH, Command, DATA_PATH, PINREAD_LABEL, SOCKET_PATH, Status } from "./const.ts";
import { type Browser, launchBrowser } from "./browser.ts";
import type { APWResponse, Message } from "./types.ts";

const REQUEST_TIMEOUT_MS = 30_000;

type ExtensionMessage = APWResponse | { token: string };

interface Pending {
  id: string;
  resolve: (value: APWResponse) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

export class ExtensionSession {
  private ws: WebSocket | null = null;
  onConnect: () => void = () => {};
  private pending: Pending | null = null;
  private chain: Promise<unknown> = Promise.resolve();

  constructor(private token: string) {}

  private rejectPending(error: Error): void {
    if (!this.pending) return;
    clearTimeout(this.pending.timer);
    this.pending.reject(error);
    this.pending = null;
  }

  accept(ws: WebSocket): void {
    if (this.ws) {
      ws.close(4001, "Already connected");
      return;
    }
    ws.addEventListener("message", (event) => {
      let message: ExtensionMessage;
      try {
        message = JSON.parse(event.data as string);
      } catch {
        ws.close(4002, "Bad JSON");
        return;
      }

      if (this.ws !== ws) {
        if (!("token" in message) || message.token !== this.token) {
          ws.close(4003, "Unauthorized");
          return;
        }
        this.ws = ws;
        console.info("[apw] extension connected");
        this.onConnect();
        return;
      }

      if (!("token" in message) && this.pending?.id === message.id) {
        const pending = this.pending;
        this.pending = null;
        clearTimeout(pending.timer);
        pending.resolve(message as APWResponse);
      }
    });

    ws.addEventListener("close", () => {
      this.ws = null;
      this.rejectPending(new Error("Extension disconnected"));
      console.info("[apw] extension disconnected");
    });
  }

  get connected(): boolean {
    return this.ws !== null;
  }

  request(message: Message): Promise<APWResponse> {
    const result = this.chain.then(() => {
      const ws = this.ws;
      if (!ws) throw new APWError(Status.INVALID_SESSION);
      return new Promise<APWResponse>((resolve, reject) => {
        const id = crypto.randomUUID();
        const timer = setTimeout(
          () => this.rejectPending(new Error("Extension response timed out")),
          REQUEST_TIMEOUT_MS,
        );
        this.pending = { id, resolve, reject, timer };
        ws.send(JSON.stringify({ ...message, id }));
      });
    });
    this.chain = result.catch(() => {});
    return result;
  }
}

async function handleCliConnection(
  conn: Deno.Conn,
  session: { request(message: Message): Promise<APWResponse> },
): Promise<void> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const buf = new Uint8Array(1024 * 64);
  let text = "";
  const send = async (response: APWResponse) => {
    try {
      // conn.write() may write only part of the buffer (macOS Unix sockets default to an 8 KB send buffer),
      // so keep writing until the whole response is out.
      const data = encoder.encode(`${JSON.stringify(response)}\n`);
      for (let offset = 0; offset < data.length;) offset += await conn.write(data.subarray(offset));
    } catch (e) {
      if ((e as { code?: string }).code !== "EPIPE") throw e;
    }
  };

  try {
    const deadline = setTimeout(() => conn.close(), REQUEST_TIMEOUT_MS);
    try {
      while (!text.includes("\n")) {
        const n = await conn.read(buf);
        if (n === null) break;
        text += decoder.decode(buf.subarray(0, n));
        if (text.length > 1024 * 1024) break;
      }
    } finally {
      clearTimeout(deadline);
    }

    try {
      const message = JSON.parse(text.split("\n", 1)[0]) as Message;
      if (typeof message.cmd !== "number") {
        throw new APWError(Status.INVALID_PARAM);
      }
      await send(await session.request(message));
    } catch (error) {
      const err = error as Error;
      await send({
        id: "",
        status: err instanceof APWError ? err.status : Status.SERVER_ERROR,
        error: err.message,
      });
    }
  } finally {
    conn.close();
  }
}

type StatusReply = {
  id: string;
  status: Status;
  error?: string;
  state?: string;
  browser?: boolean;
  extension?: boolean;
};

/** `apw status`: answered by the daemon so it can say "no browser" without asking the extension. */
export async function status(session: ExtensionSession, browserAlive: () => boolean): Promise<StatusReply> {
  const browser = browserAlive();
  if (!browser) {
    return { id: "", status: Status.INVALID_SESSION, error: "browser not running", browser, extension: false };
  }
  if (!session.connected) {
    return { id: "", status: Status.INVALID_SESSION, error: "extension not connected", browser, extension: false };
  }
  const reply = await session.request({ cmd: Command.APW_STATUS } as unknown as Message) as StatusReply;
  const state = reply.state ?? "unknown";
  return state === "SessionKeySet"
    ? { id: "", status: Status.SUCCESS, state, browser, extension: true }
    : { id: "", status: Status.INVALID_SESSION, error: `unpaired (${state})`, state, browser, extension: true };
}

const REPAIR_EVERY_MS = 15_000;
const REREAD_AFTER_MS = 60_000;

/**
 * Re-pair with no human: when the extension is unpaired, ask the helper for a code (it shows the
 * "Enable Password AutoFill" window) and start the PIN reader job, which reads the code off that window
 * and answers through the socket. No reader job => one macOS notification asking for `apw auth`.
 */
export class Repairer {
  private lastRead = 0;
  private notified = -Infinity;
  private busy = false;

  constructor(
    private session: ExtensionSession,
    private browserAlive: () => boolean,
    private startReader: () => Promise<boolean> = startPinReader,
    private notify: (text: string) => Promise<void> = notifyUser,
    private now: () => number = Date.now,
  ) {}

  async tick(): Promise<string> {
    if (this.busy) return "busy";
    this.busy = true;
    try {
      const reply = await status(this.session, this.browserAlive).catch((e) => ({
        state: undefined,
        error: String(e),
      }));
      const state = (reply as StatusReply).state;
      if (state === "SessionKeySet" || state === undefined) return state ?? "no-extension";
      if (state === "NotInSession") {
        await this.session.request({ cmd: Command.HANDSHAKE });
        console.info("[apw] unpaired: asked the helper for a pairing code");
        this.lastRead = 0;
      }
      if (this.now() - this.lastRead < REREAD_AFTER_MS) return "waiting";
      this.lastRead = this.now();
      if (await this.startReader()) {
        console.info(`[apw] started PIN reader ${PINREAD_LABEL}`);
        return "reader";
      }
      if (this.now() - this.notified > 3_600_000) {
        this.notified = this.now();
        await this.notify("apw is unpaired: run `apw auth` and type the code from 'Enable Password AutoFill'.");
      }
      return "notified";
    } finally {
      this.busy = false;
    }
  }
}

async function startPinReader(): Promise<boolean> {
  const target = `gui/${Deno.uid()}/${PINREAD_LABEL}`;
  const out = await new Deno.Command("/bin/launchctl", { args: ["kickstart", target], stdout: "null", stderr: "piped" })
    .output().catch(() => null);
  if (!out?.success) {
    console.info(
      `[apw] PIN reader ${target} not available: ${
        out ? new TextDecoder().decode(out.stderr).trim() : "launchctl failed"
      }`,
    );
  }
  return !!out?.success;
}

async function notifyUser(text: string): Promise<void> {
  console.info(`[apw] notify: ${text}`);
  await new Deno.Command("/usr/bin/osascript", {
    args: ["-e", `display notification ${JSON.stringify(text)} with title "apw needs pairing"`],
    stdout: "null",
    stderr: "null",
  }).output().catch(() => {});
}

export async function daemon(browser: Browser): Promise<void> {
  Deno.mkdirSync(DATA_PATH, { recursive: true, mode: 0o700 });
  Deno.chmodSync(DATA_PATH, 0o700);

  const token = crypto.randomUUID();
  const session = new ExtensionSession(token);

  const wsServer = Deno.serve({ hostname: "127.0.0.1", port: 0 }, (req) => {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("WebSocket upgrade required", { status: 426 });
    }
    const { socket, response } = Deno.upgradeWebSocket(req);
    session.accept(socket);
    return response;
  });

  const child = await launchBrowser(browser, { port: (wsServer.addr as Deno.NetAddr).port, token });
  console.info(`[apw] launched headless ${browser.name} (pid ${child.pid}); extension loaded.`);
  Deno.writeTextFileSync(BROWSER_PID_PATH, `${child.pid}\n`);
  let browserAlive = true;
  const cleanup = () => {
    for (const path of [SOCKET_PATH, BROWSER_PID_PATH]) {
      try {
        Deno.removeSync(path);
      } catch { /* gone */ }
    }
  };
  let stopping = false;
  const shutdown = async () => {
    stopping = true;
    try {
      child.kill("SIGTERM");
      await child.status;
    } catch { /* ignore */ }
    cleanup();
    Deno.exit(0);
  };
  for (const signal of ["SIGINT", "SIGTERM"] as const) Deno.addSignalListener(signal, shutdown);

  // Supervision: the pairing lives in the browser's native-messaging helper. If the browser dies
  // (force quit, crash), a daemon left running would look healthy to launchd while every read fails.
  // Exit instead: launchd (KeepAlive) starts a fresh apw, and the Repairer pairs it again.
  child.status.then((s) => {
    browserAlive = false;
    if (stopping) return;
    console.info(
      `[apw] browser exited (code ${s.code}${s.signal ? `, signal ${s.signal}` : ""}); exiting so launchd restarts apw`,
    );
    cleanup();
    Deno.exit(75);
  });

  try {
    Deno.removeSync(SOCKET_PATH);
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  const unixListener = Deno.listen({ transport: "unix", path: SOCKET_PATH });
  console.info(`[apw] Unix socket at ${SOCKET_PATH}`);
  await Deno.chmod(SOCKET_PATH, 0o600);

  const alive = () => browserAlive;
  const repairer = new Repairer(session, alive);
  const repair = () => repairer.tick().catch((e) => console.error(`[apw] repair: ${e}`));
  session.onConnect = () => setTimeout(repair, 2_000);
  setInterval(repair, REPAIR_EVERY_MS);

  const front = {
    request: (message: Message) =>
      message.cmd === Command.APW_STATUS ? status(session, alive) : session.request(message),
  };
  for await (const conn of unixListener) {
    handleCliConnection(conn, front).catch(console.error);
  }
}

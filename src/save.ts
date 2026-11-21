// `apw pw save`: store one login in the Passwords app with no human. Apple's helper answers a MAYBE_ADD with a
// "Save Password?" (new) or "Update Password?" (existing) alert; launchd job com.lod.apw-saveclick
// (apw-pinread --save-click) presses it the moment it is on screen. Success is the read-back, never the reply.
import { APWError, SAVECLICK_LABEL, SAVECLICK_PATH, Status } from "./const.ts";

/** What the clicker saw (written by pinread/saveclick.swift). */
export interface ClickResult {
  state: string; // pressed | no-alert | press-failed | untrusted | no-browser | expired | ready
  alert?: string;
  button?: string;
  alerts_seen?: number;
  ignored_windows?: number;
  visible_ms?: number;
  focus_lost_ms?: number;
}

export interface Clicker {
  result(): Promise<ClickResult>;
  release(): Promise<void>;
}

export interface SaveDeps {
  read(host: string, user: string): Promise<string | undefined>;
  send(host: string, user: string, password: string): Promise<void>;
  arm(host: string, user: string): Promise<Clicker>;
  sleep(ms: number): Promise<void>;
  readbackMs?: number;
}

export interface SaveReport {
  host: string;
  user: string;
  action: "saved" | "updated" | "unchanged";
  click?: ClickResult;
}

// Names with no public-suffix base domain: Apple's helper stores nothing for them.
const NO_PUBLIC_SUFFIX = ["lod", "local", "localhost", "internal", "test", "invalid", "example", "home", "lan"];

/** A bare hostname on a public suffix, lowercased; anything else throws with the reason. */
export function checkHost(raw: string): string {
  const host = raw.trim().toLowerCase();
  if (/[:/?#@\s]/.test(host)) {
    throw new APWError(
      Status.INVALID_PARAM,
      `site must be a bare hostname like example.com, not "${raw}": a URL (https://, a path or a port) saves an entry apw cannot read back`,
    );
  }
  const labels = host.split(".");
  if (labels.length < 2 || labels.some((l) => !/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/.test(l))) {
    throw new APWError(Status.INVALID_PARAM, `site "${raw}" is not a hostname like example.com`);
  }
  const tld = labels[labels.length - 1];
  if (NO_PUBLIC_SUFFIX.includes(tld)) {
    throw new APWError(
      Status.INVALID_PARAM,
      `site "${raw}" ends in .${tld}, which has no public-suffix base domain: the Passwords app stores nothing for it. Use a real domain (e.g. <app>.lappsonlinedynamics.com)`,
    );
  }
  return host;
}

/** The password piped in: exactly the bytes given, minus one trailing newline. */
export function passwordFromStdin(text: string): string {
  const pw = text.replace(/\r?\n$/, "");
  if (!pw) throw new APWError(Status.INVALID_PARAM, "empty password on stdin");
  return pw;
}

export async function savePassword(
  rawHost: string,
  user: string,
  password: string,
  deps: SaveDeps,
): Promise<SaveReport> {
  const host = checkHost(rawHost);
  if (!user) throw new APWError(Status.INVALID_PARAM, "username is required");
  if (!password) throw new APWError(Status.INVALID_PARAM, "empty password");
  const before = await deps.read(host, user);
  if (before === password) return { host, user, action: "unchanged" };

  const clicker = await deps.arm(host, user);
  let click: ClickResult;
  try {
    await deps.send(host, user, password);
    click = await clicker.result();
  } finally {
    await clicker.release();
  }
  const until = Date.now() + (deps.readbackMs ?? 10_000);
  let got = await deps.read(host, user);
  while (got !== password && Date.now() < until) {
    await deps.sleep(300);
    got = await deps.read(host, user);
  }
  if (got !== password) {
    const why = click.state === "pressed"
      ? `the ${click.button} alert was pressed but the read-back does not match`
      : `no save alert was pressed (clicker: ${click.state})`;
    throw new APWError(Status.FAILED_TO_UPDATE, `${host} / ${user} not saved: ${why}`);
  }
  return { host, user, action: before === undefined ? "saved" : "updated", click };
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

async function readJSON(path: string): Promise<ClickResult | undefined> {
  try {
    return JSON.parse(await Deno.readTextFile(path)) as ClickResult;
  } catch {
    return undefined;
  }
}

/** Arms launchd job com.lod.apw-saveclick for one save: request file, kickstart, wait for "ready". */
export async function launchdClicker(
  host: string,
  user: string,
  dir = SAVECLICK_PATH,
  label = SAVECLICK_LABEL,
): Promise<Clicker> {
  await Deno.mkdir(dir, { recursive: true, mode: 0o700 });
  const lock = `${dir}/lock`;
  try {
    await Deno.mkdir(lock);
  } catch {
    const age = Date.now() - ((await Deno.stat(lock).catch(() => null))?.mtime?.getTime() ?? 0);
    if (age < 60_000) throw new APWError(Status.GENERIC_ERROR, "another `apw pw save` is in progress; try again");
    await Deno.remove(lock).catch(() => {});
    await Deno.mkdir(lock);
  }
  const id = crypto.randomUUID();
  const out = `${dir}/${id}.json`;
  const release = async () => {
    for (const p of [`${dir}/request.json`, out]) await Deno.remove(p).catch(() => {});
    await Deno.remove(lock).catch(() => {});
  };
  try {
    await Deno.writeTextFile(
      `${dir}/request.json`,
      JSON.stringify({ id, host, user, expires: Date.now() / 1000 + 20 }),
      { mode: 0o600 },
    );
    const target = `gui/${Deno.uid()}/${label}`;
    const ks = await new Deno.Command("/bin/launchctl", {
      args: ["kickstart", "-k", target],
      stdout: "null",
      stderr: "piped",
    })
      .output();
    if (!ks.success) {
      throw new APWError(
        Status.GENERIC_ERROR,
        `launchd job ${label} is not loaded (run the apw fork's scripts/install-local.sh): ${
          new TextDecoder().decode(ks.stderr).trim()
        }`,
      );
    }
    let r: ClickResult | undefined;
    for (let i = 0; i < 250 && !r; i++) {
      r = await readJSON(out);
      if (!r) await sleep(20);
    }
    if (r?.state !== "ready") {
      const why = r?.state === "untrusted"
        ? "apw-pinread has no Accessibility grant (System Settings > Privacy & Security > Accessibility: apw-pinread ON)"
        : r?.state ?? "it did not start within 5 s (tail ~/skill-logs/apw/log.md)";
      throw new APWError(Status.GENERIC_ERROR, `the save clicker is not ready: ${why}`);
    }
  } catch (e) {
    await release();
    throw e;
  }
  return {
    async result() {
      for (let i = 0; i < 1250; i++) {
        const r = await readJSON(out);
        if (r && r.state !== "ready") return r;
        await sleep(20);
      }
      return { state: "no-result" };
    },
    release,
  };
}

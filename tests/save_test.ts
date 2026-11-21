import { assertEquals, assertRejects, assertThrows } from "@std/assert";
import {
  checkHost,
  type ClickResult,
  launchdClicker,
  passwordFromStdin,
  type SaveDeps,
  savePassword,
} from "../src/save.ts";
import { APWError } from "../src/const.ts";

const pressed: ClickResult = { state: "pressed", button: "Save Password", alert: "Save Password?", visible_ms: 40 };

/** A fake Passwords app: `store` is what a read sees; the save lands only if the clicker presses. */
function fake(store: Map<string, string>, click: ClickResult, opts: { lands?: boolean } = {}) {
  const calls: string[] = [];
  const deps: SaveDeps = {
    read: (h, u) => Promise.resolve(store.get(`${h}/${u}`)),
    send: (h, u, p) => {
      calls.push("send");
      if (click.state === "pressed" && opts.lands !== false) store.set(`${h}/${u}`, p);
      return Promise.resolve();
    },
    arm: () => {
      calls.push("arm");
      return Promise.resolve({
        result: () => Promise.resolve(click),
        release: () => {
          calls.push("release");
          return Promise.resolve();
        },
      });
    },
    sleep: () => Promise.resolve(),
    readbackMs: 0,
  };
  return { deps, calls };
}

Deno.test("checkHost: bare public hostnames pass, lowercased", () => {
  assertEquals(checkHost("PWRoute-Test.LappsOnlineDynamics.com"), "pwroute-test.lappsonlinedynamics.com");
  assertEquals(checkHost("example.com"), "example.com");
});

Deno.test("checkHost: a URL form is refused (it saves something apw cannot read)", () => {
  for (
    const bad of ["https://example.com", "http://example.com", "example.com/login", "example.com:8443", "u@example.com"]
  ) {
    assertThrows(() => checkHost(bad), APWError, "bare hostname");
  }
});

Deno.test("checkHost: .lod and other non-public suffixes are refused (nothing is stored)", () => {
  for (const bad of ["vault.lod", "app.local", "localhost", "x.test"]) assertThrows(() => checkHost(bad), APWError);
  assertThrows(() => checkHost("vault.lod"), APWError, "public-suffix");
});

Deno.test("passwordFromStdin keeps the bytes, drops one trailing newline, refuses empty", () => {
  assertEquals(passwordFromStdin("a b \n"), "a b ");
  assertEquals(passwordFromStdin("x\n\n"), "x\n");
  assertThrows(() => passwordFromStdin("\n"), APWError, "empty");
});

Deno.test("save: new entry, alert pressed, read-back matches => saved", async () => {
  const store = new Map<string, string>();
  const { deps, calls } = fake(store, pressed);
  const r = await savePassword("example.com", "u", "s3cret", deps);
  assertEquals([r.action, calls], ["saved", ["arm", "send", "release"]]);
});

Deno.test("save: existing entry with another value => updated", async () => {
  const store = new Map([["example.com/u", "old"]]);
  const { deps } = fake(store, { ...pressed, button: "Update Password", alert: "Update Password?" });
  assertEquals((await savePassword("example.com", "u", "new", deps)).action, "updated");
});

Deno.test("save: same value already stored => unchanged, no clicker armed, nothing sent", async () => {
  const store = new Map([["example.com/u", "same"]]);
  const { deps, calls } = fake(store, pressed);
  assertEquals((await savePassword("example.com", "u", "same", deps)).action, "unchanged");
  assertEquals(calls, []);
});

Deno.test("save: no alert pressed => fails, clicker released", async () => {
  const { deps, calls } = fake(new Map(), { state: "no-alert" });
  await assertRejects(
    () => savePassword("example.com", "u", "p", deps),
    APWError,
    "no save alert was pressed (clicker: no-alert)",
  );
  assertEquals(calls.at(-1), "release");
});

Deno.test("save: pressed but read-back differs => fails (exit is never 0 without the read-back)", async () => {
  const { deps } = fake(new Map(), pressed, { lands: false });
  await assertRejects(() => savePassword("example.com", "u", "p", deps), APWError, "read-back does not match");
});

Deno.test("save: refused host never arms the clicker or sends", async () => {
  const { deps, calls } = fake(new Map(), pressed);
  await assertRejects(() => savePassword("https://example.com", "u", "p", deps), APWError);
  await assertRejects(() => savePassword("vault.lod", "u", "p", deps), APWError);
  assertEquals(calls, []);
});

Deno.test("launchdClicker: a second save while one is armed is refused; the lock is released after", async () => {
  const dir = await Deno.makeTempDir();
  await Deno.mkdir(`${dir}/lock`);
  await assertRejects(() => launchdClicker("example.com", "u", dir), APWError, "in progress");
  await Deno.remove(`${dir}/lock`);
  // A job that is not loaded: refused with the install hint, nothing left behind (never the real job: -k would kill it).
  await assertRejects(
    () => launchdClicker("example.com", "u", dir, "com.lod.apw-saveclick-test-absent"),
    APWError,
    "not loaded",
  );
  const left = [...Deno.readDirSync(dir)].map((e) => e.name);
  assertEquals(left, []);
  await Deno.remove(dir, { recursive: true });
});

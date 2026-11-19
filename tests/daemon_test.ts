import { assertEquals } from "@std/assert";
import { ExtensionSession, Repairer, status } from "../src/daemon.ts";
import { Command } from "../src/const.ts";
import type { Message } from "../src/types.ts";

function fakeSession(state: string | null) {
  const sent: number[] = [];
  const s = {
    get connected() {
      return state !== null;
    },
    request(m: Message) {
      sent.push(m.cmd);
      if (m.cmd === Command.HANDSHAKE) state = "MSG1Set";
      return Promise.resolve({ id: "", status: 0, state: state ?? undefined });
    },
  } as unknown as ExtensionSession;
  return { s, sent };
}

Deno.test("status: a dead browser is reported (status 9), never 'running'", async () => {
  const { s } = fakeSession("SessionKeySet");
  const r = await status(s, () => false);
  assertEquals([r.status, (r as { error?: string }).error], [9, "browser not running"]);
});

Deno.test("status: paired => 0, unpaired => 9", async () => {
  assertEquals((await status(fakeSession("SessionKeySet").s, () => true)).status, 0);
  assertEquals((await status(fakeSession("NotInSession").s, () => true)).status, 9);
  assertEquals((await status(fakeSession(null).s, () => true)).status, 9);
});

Deno.test("repair: unpaired => ask the helper for a code, then start the PIN reader", async () => {
  const { s, sent } = fakeSession("NotInSession");
  let readers = 0;
  const r = new Repairer(s, () => true, () => Promise.resolve(++readers > 0), () => Promise.resolve());
  assertEquals(await r.tick(), "reader");
  assertEquals(sent, [Command.APW_STATUS, Command.HANDSHAKE]);
  assertEquals(readers, 1);
  assertEquals(await r.tick(), "waiting"); // window still up: no second reader within a minute
});

Deno.test("repair: paired => nothing happens", async () => {
  const { s, sent } = fakeSession("SessionKeySet");
  const r = new Repairer(s, () => true, () => Promise.reject("must not run"), () => Promise.reject("must not run"));
  assertEquals(await r.tick(), "SessionKeySet");
  assertEquals(sent, [Command.APW_STATUS]);
});

Deno.test("repair: no reader job => one notification per hour, not one per tick", async () => {
  const { s } = fakeSession("NotInSession");
  let t = 0, notes = 0;
  const r = new Repairer(s, () => true, () => Promise.resolve(false), () => Promise.resolve(void notes++), () => t);
  t = 100_000;
  await r.tick();
  t += 61_000;
  await r.tick();
  assertEquals(notes, 1);
});

import { assertEquals } from "@std/assert";

const bin = new URL("../pinread/apw-pinread", import.meta.url).pathname;
async function parse(text: string): Promise<[number, string]> {
  const out = await new Deno.Command(bin, { args: ["--parse", text] }).output();
  return [out.code, new TextDecoder().decode(out.stdout).trim()];
}

Deno.test("pinread reads the code as the helper window shows it", async () => {
  // Strings read off the live window by AX on 2026-11-19.
  assertEquals(
    await parse("Enter this verification code into the Chrome extension to enable Password AutoFill.\n227 621\nDone"),
    [0, "227621"],
  );
  assertEquals(await parse("227621"), [0, "227621"]);
});

Deno.test("pinread never takes a longer digit run as a code", async () => {
  assertEquals((await parse("System Settings…, 2 updates 1234567"))[0], 1);
});

async function label(title: string): Promise<string> {
  const out = await new Deno.Command(bin, { args: ["--window-label", title] }).output();
  return new TextDecoder().decode(out.stdout).trim();
}

Deno.test("chrome watcher keys pairing by the profile in the window title", async () => {
  // Title read off the everyday Chrome by AX on 2026-11-20.
  assertEquals(await label("LCF Admin CMS - Google Chrome - Sammy (Personal)"), "Sammy (Personal)");
  assertEquals(await label("a - Google Chrome - b - Google Chrome - HUB"), "HUB");
  assertEquals(await label("New Tab"), "");
});

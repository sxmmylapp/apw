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

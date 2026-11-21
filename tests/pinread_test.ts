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

async function classify(args: string[], env: Record<string, string> = {}): Promise<[number, string]> {
  const out = await new Deno.Command(bin, { args: ["--classify-alert", ...args], env }).output();
  return [out.code, new TextDecoder().decode(out.stdout).trim()];
}
// Read off Apple's live helper alerts by AX on 2026-11-20; strings from the helper's en.lproj/Localizable.strings.
const SECURELY =
  "Securely store your password in the Passwords app so it’s filled automatically the next time you need it.";
const ours = { SC_HOST: "pwroute-test.lappsonlinedynamics.com", SC_USER: "build-test1" };
const update = (u: string, d: string) => `Do you want to update the password saved for “${u}” on “${d}”?`;

Deno.test("save clicker presses only the save button of Apple's save/update alert", async () => {
  assertEquals(await classify(["alert", "Save Password?", SECURELY, "--", "Save Password", "Not Now"], ours), [
    0,
    "Save Password",
  ]);
  // Measured: the update alert names the user and the base domain (88 chars for build-test1).
  assertEquals(update("build-test1", "lappsonlinedynamics.com").length, 88);
  assertEquals(
    await classify([
      "alert",
      update("build-test1", "lappsonlinedynamics.com"),
      SECURELY,
      "--",
      "Update Password",
      "Not Now",
    ], ours),
    [0, "Update Password"],
  );
  assertEquals(
    await classify(
      ["alert", update("build-test1", "pwroute-test.lappsonlinedynamics.com"), "--", "Update Password"],
      ours,
    ),
    [0, "Update Password"],
  );
});

Deno.test("save clicker leaves every other helper window alone", async () => {
  const no = async (args: string[]) => assertEquals((await classify(args, ours))[0], 1);
  // The pairing-code window, a non-alert, a save alert without its button (no default-button fallback).
  await no(["", "Enable Password AutoFill", "227 621", "--", "Done"]);
  await no(["", "Save Password?", "--", "Save Password"]);
  await no(["alert", "Save Password?", "--", "Not Now"]);
  await no(["alert", "Delete Password?", "--", "Delete", "Cancel"]);
  await no(["alert", "Save Password?x", "--", "Save Password"]);
});

Deno.test("save clicker refuses an update alert for another account or site", async () => {
  const no = async (args: string[]) => assertEquals((await classify(args, ours))[0], 1);
  await no(["alert", update("someone", "lappsonlinedynamics.com"), "--", "Update Password"]);
  await no(["alert", update("build-test1", "example.com"), "--", "Update Password"]);
  await no(["alert", update("build-test1", "dynamics.com"), "--", "Update Password"]); // not a dot-boundary suffix
  await no([
    "alert",
    "Do you want to update the password saved on “lappsonlinedynamics.com”?",
    "--",
    "Update Password",
  ]);
  await no(["alert", update("build-test1", "lappsonlinedynamics.com"), "--", "Not Now"]);
  await no(["alert", "Save Password?", "Saving for “someone”", "--", "Save Password"]);
});

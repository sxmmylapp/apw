import { Command, Input, Select } from "./deps.ts";
import { daemon } from "./daemon.ts";
import { ApplePasswordManager } from "./client.ts";
import { BROWSERS, installedBrowsers } from "./browser.ts";
import { readConfig, writeConfig } from "./config.ts";
import { APWError, Status, VERSION } from "./const.ts";
import type { PasswordEntry, Payload } from "./types.ts";
import { launchdClicker, passwordFromStdin, savePassword } from "./save.ts";

const client = new ApplePasswordManager();

const printSuccess = () => console.log(JSON.stringify({ status: Status.SUCCESS }));

function printResult(payload: Payload, table: boolean): void {
  const entries = payload.Entries.map((entry) => {
    if ("USR" in entry) {
      return {
        username: entry.USR,
        domain: entry.sites[0],
        ...(entry.customTitle && { title: entry.customTitle }),
        ...(entry.PWD !== "Not Included" && { password: entry.PWD }),
        ...(entry.sites && { sites: entry.sites }),
        ...(entry.highLevelDomain && { highLevelDomain: entry.highLevelDomain }),
      };
    } else {
      return {
        username: entry.username,
        domain: entry.domain,
        ...(entry.source && { source: entry.source }),
        ...(entry.code && { code: entry.code }),
      };
    }
  });
  if (table) {
    console.table(entries);
  } else {
    console.log(JSON.stringify({ results: entries, status: Status.SUCCESS }));
  }
}

const otp = new Command()
  .description("Interactively list accounts/OTPs.")
  .globalOption("-t, --table", "Output as a table.")
  .globalOption("-j, --json", "Output as JSON.")
  .action(async ({ json }: { json?: boolean }) => {
    await client.checkReady();
    const action: string = await Select.prompt({
      message: "Choose an action: ",
      options: ["list OTPs", "get OTPs"],
    });
    const url = await Input.prompt({ message: "Enter URL: ", minLength: 1 });
    if (action === "list OTPs") {
      printResult(await client.listOTPForURL(url), !json);
    } else if (action === "get OTPs") {
      printResult(await client.getOTPForURL(url), !json);
    }
  })
  .command("get", "Get an OTP for a website.")
  .arguments("<url:string>")
  .action(async ({ table, json }: { table?: boolean; json?: boolean }, url: string) => {
    printResult(await client.getOTPForURL(url), !!table && !json);
  })
  .command("list", "List available OTPs for a website.")
  .arguments("<url:string>")
  .action(async ({ table, json }: { table?: boolean; json?: boolean }, url: string) => {
    printResult(await client.listOTPForURL(url), !!table && !json);
  });

const pw = new Command()
  .description("Interactively manage accounts/passwords.")
  .globalOption("-t, --table", "Output as a table.")
  .globalOption("-j, --json", "Output as JSON.")
  .action(async ({ json }: { json?: boolean }) => {
    await client.checkReady();
    const action: string = await Select.prompt({
      message: "Choose an action: ",
      options: ["list accounts", "get password"],
    });
    const url = await Input.prompt({ message: "Enter URL: ", minLength: 1 });
    if (action === "list accounts") {
      printResult(await client.getLoginNamesForURL(url), !json);
    } else if (action === "get password") {
      const accounts = await client.getLoginNamesForURL(url);
      if (!accounts.Entries.length) {
        console.log("No accounts found.");
        return;
      }
      const options = [
        { name: "All", value: "" },
        ...accounts.Entries
          .filter((e): e is PasswordEntry => "USR" in e)
          .map((e) => ({ name: `${e.USR} (${e.sites[0]})`, value: e.USR })),
      ];
      const username = options.length === 2
        ? options[1].value
        : await Select.prompt({ message: "Select account:", options });
      printResult(await client.getPasswordForURL(url, username), !json);
    }
  })
  .command("get", "Get a password for a website.")
  .arguments("<url:string> [username:string]")
  .action(async ({ table, json }: { table?: boolean; json?: boolean }, url: string, username?: string) => {
    printResult(await client.getPasswordForURL(url, username), !!table && !json);
  })
  .command("list", "List available accounts for a website.")
  .arguments("<url:string>")
  .action(async ({ table, json }: { table?: boolean; json?: boolean }, url: string) => {
    printResult(await client.getLoginNamesForURL(url), !!table && !json);
  })
  .command(
    "save",
    'Create or update a login; password on stdin only: print -rn -- "$V" | apw pw save <host> <user>. ' +
      "<host> is a bare hostname (example.com). Exit 0 only when the read-back matches.",
  )
  .option("--stdin", "Accepted for compatibility; the password is always read from stdin.")
  .arguments("<host:string> <username:string>")
  .action(async (_options: { stdin?: boolean }, host: string, username: string) => {
    if (Deno.stdin.isTerminal()) {
      throw new APWError(
        Status.INVALID_PARAM,
        'the password is read from stdin only: print -rn -- "$V" | apw pw save <host> <user>',
      );
    }
    const password = passwordFromStdin(await new Response(Deno.stdin.readable).text());
    const report = await savePassword(host, username, password, {
      read: async (h, u) => {
        try {
          const p = await client.getPasswordForURL(h, u);
          return (p.Entries.find((e) => "USR" in e && e.USR === u) as PasswordEntry | undefined)?.PWD;
        } catch (e) {
          if (e instanceof APWError && e.status === Status.NO_RESULTS) return undefined;
          throw e;
        }
      },
      send: (h, u, p) => client.saveAccountForURL(h, u, p),
      arm: (h, u) => launchdClicker(h, u),
      sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    });
    const { click, ...rest } = report;
    console.log(JSON.stringify({
      status: Status.SUCCESS,
      ...rest,
      ...(click && {
        alert: click.alert,
        alerts_seen: click.alerts_seen,
        visible_ms: click.visible_ms,
        focus_lost_ms: click.focus_lost_ms,
      }),
    }));
  });

const start = new Command()
  .description("Start APW and choose a managed browser.")
  .option("-b, --browser <browser:string>", "Browser to use (auto, chromium, chrome-beta, chrome, brave, or edge).")
  .action(async (options: { browser?: string }) => {
    const browsers = installedBrowsers();
    if (!browsers.length) {
      const hints = BROWSERS.map(({ name, brewCask }) => `  brew install --cask ${brewCask}  # ${name}`).join("\n");
      throw new APWError(Status.GENERIC_ERROR, `No supported browser found. Install one:\n${hints}`);
    }
    const saved = readConfig().browser ?? "auto";
    let selected: string;
    if (options.browser) {
      selected = options.browser.toLowerCase();
    } else if (Deno.stdin.isTerminal()) {
      selected = (await Select.prompt({
        message: "Browser:",
        default: saved,
        options: ["auto", ...browsers.map(({ id }) => id)],
      })).toLowerCase();
    } else {
      selected = saved;
    }
    if (selected !== saved) writeConfig({ browser: selected });
    const browser = selected === "auto"
      ? browsers[0]
      : browsers.find(({ id, name }) => id === selected || name.toLowerCase() === selected);
    if (!browser) {
      throw new APWError(Status.INVALID_PARAM, `Unsupported browser: ${selected}`);
    }
    await daemon(browser);
  });

const auth = new Command()
  .description("Authenticate CLI with daemon.")
  .action(async () => {
    await client.requestChallenge();
    const pin = await Input.prompt({
      message: "Enter PIN: ",
      minLength: 6,
      maxLength: 6,
    });
    await client.verifyChallenge(pin);
    printSuccess();
  })
  .command("request", "Request a challenge from the daemon.")
  .action(async () => {
    await client.requestChallenge();
    printSuccess();
  })
  .command("response", "Respond to a challenge from the daemon.")
  .option("-p, --pin <pin>", "challenge-response pin.", { required: true })
  .action(async (options: { pin: string }) => {
    await client.verifyChallenge(options.pin);
    printSuccess();
  });

const statusCmd = new Command()
  .description("Is apw paired? Exit 0 when the browser, extension and pairing are all up, else 9.")
  .action(async () => {
    const { id: _id, ...reply } = await client.status() as unknown as Record<string, unknown>;
    console.log(JSON.stringify(reply));
  });

try {
  await new Command()
    .name("apw")
    .version(`v${VERSION}`)
    .description("🔑 a CLI for Apple Passwords 🔒")
    .command("auth", auth)
    .command("pw", pw)
    .command("otp", otp)
    .command("start", start)
    .command("status", statusCmd)
    .parse(Deno.args);
} catch (error: unknown) {
  let status = Status.GENERIC_ERROR;
  let msg = "Unknown Error";
  if (error instanceof APWError || error instanceof Error) {
    status = error instanceof APWError ? error.status : status;
    msg = error.message;
  }
  console.error(JSON.stringify({ error: msg, status, results: [] }));
  Deno.exit(status);
}

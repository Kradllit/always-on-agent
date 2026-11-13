// Build and flash the badge whenever the main branch moves on GitHub.
//   bun ci/flash-on-push.ts
// Runs on the laptop the badge is plugged into (the Rust ESP toolchain, esptool, gh and Bun
// installed, `gh` signed in). Every ten seconds it asks GitHub for the head of main. A new commit is checked out
// into ci/work (a clone of its own, so nobody's working copy is touched), built with that
// commit's build.sh, flashed (the app only: the badge's settings stay), and the
// badge's start-up is watched for 40 seconds. The result lands on the commit as a status
// named "badge": building, flashed and started, build failed, or crashed at start. A build
// failure or a crash also gets a commit comment with the compiler's errors or the crash line.
//
// It asks GitHub rather than being called by a webhook: a webhook needs a public door into
// this laptop, and a ten-second wait buys not having one.
//
// When several commits land during a build, only the newest is built next.
// Env: BADGE_BRANCH (main), BADGE_POLL_S (10), BADGE_LOCAL_ENV (local.env beside the repo's
// build script: the Wi-Fi built into the firmware; never in git).
import { $ } from "bun";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync, globSync } from "node:fs";
import { join, resolve } from "node:path";

const repo = resolve(import.meta.dir, "..");
const work = join(repo, "ci/work");
const logs = join(repo, "ci/logs");
const stateFile = join(repo, "ci/state.json");
const branch = process.env.BADGE_BRANCH || "main";
const pollMs = (Number(process.env.BADGE_POLL_S) || 10) * 1000;
const localEnv = process.env.BADGE_LOCAL_ENV || join(repo, "local.env");
const bootWatchMs = 40_000;
mkdirSync(logs, { recursive: true });

const log = (line: string) => {
  const text = `${new Date().toTimeString().slice(0, 8)} ${line}`;
  console.log(text);
  appendFileSync(join(logs, "watcher.log"), text + "\n");
};
const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));

const origin = (await $`git -C ${repo} remote get-url origin`.text()).trim();
const slug = origin.replace(/^.*github\.com[:/]/, "").replace(/\.git$/, "");

// What must never reach GitHub: the server address's secret part and the local settings' values.
const hidden = existsSync(localEnv)
  ? [...readFileSync(localEnv, "utf8").matchAll(/^[A-Z_]+=(.+)$/gm)]
      .map((m) => m[1].replace(/^(['"])(.*)\1$/, "$2"))
      .filter((v) => v.length >= 6)
  : [];
function safe(text: string): string {
  let out = text.replace(/(\/ota\/)[^/\s"']+/g, "$1<hidden>").replaceAll(process.env.HOME || "\0", "~");
  for (const value of hidden) out = out.replaceAll(value, "<hidden>");
  return out;
}

async function status(sha: string, state: "pending" | "success" | "failure" | "error", description: string) {
  log(`${sha.slice(0, 7)} ${state}: ${description}`);
  await $`gh api repos/${slug}/statuses/${sha} -f state=${state} -f context=badge -f description=${safe(description).slice(0, 140)}`
    .quiet().nothrow();
}
async function comment(sha: string, body: string) {
  await $`gh api repos/${slug}/commits/${sha}/comments -f body=${safe(body).slice(0, 60000)}`.quiet().nothrow();
}

async function head(): Promise<string | null> {
  const out = await $`git ls-remote ${origin} refs/heads/${branch}`.quiet().nothrow();
  return out.exitCode === 0 ? out.text().split(/\s/)[0] || null : null;
}
const port = () => globSync("/dev/cu.usbmodem*")[0] as string | undefined;

async function build(sha: string): Promise<boolean> {
  if (!existsSync(join(work, ".git"))) await $`git clone --quiet ${origin} ${work}`;
  await $`git -C ${work} fetch --quiet origin ${branch}`;
  // Whatever a build left changed in the tracked files goes; the build folders stay (ignored).
  await $`git -C ${work} checkout --quiet --force ${sha}`;
  const buildLog = join(logs, `${sha.slice(0, 7)}.build.log`);
  const started = Date.now();
  // Through zsh, which does the redirect: Bun's own shell refuses this one.
  const run = Bun.spawn(["zsh", "-c", 'exec zsh "$1" > "$2" 2>&1', "build", join(work, "build.sh"), buildLog],
    { env: { ...process.env, BADGE_LOCAL_ENV: localEnv }, stdio: ["ignore", "ignore", "ignore"] });
  const exitCode = await run.exited;
  const took = Math.round((Date.now() - started) / 1000);
  if (exitCode === 0 && existsSync(join(work, "build/badge.bin"))) {
    log(`${sha.slice(0, 7)} built in ${took} s`);
    return true;
  }
  const lines = readFileSync(buildLog, "utf8").split("\n");
  // The compiler's errors with the lines that say where; failing that, the log's end.
  const errors = lines.filter((l) => /^error|^\s+--> |^\s*\d* *\| |FAILED:|undefined reference/.test(l)).slice(0, 60);
  const shown = (errors.length ? errors : lines.slice(-40)).map((l) => l.replaceAll(work + "/", ""));
  await status(sha, "failure", `build failed after ${took} s: ${shown[0]?.trim() || "see the comment"}`);
  await comment(sha, "The badge build failed; nothing was flashed.\n\n```\n" + shown.join("\n") + "\n```");
  return false;
}

// Flash the app and watch the start. Returns the crash lines, if it crashed.
async function flash(sha: string, device: string): Promise<{ ok: boolean; why: string[] }> {
  const idf = `source ${join(repo, "ci/idf-env.sh")}`;
  await $`pkill -f serial-log.py`.quiet().nothrow(); // the log recorder holds the port
  await sleep(1000);
  const bin = join(work, "build/badge.bin");
  const flashLog = join(logs, `${sha.slice(0, 7)}.flash.log`);
  // No reset from esptool: the recorder below restarts the badge once. Two restarts close
  // together have frozen the badge before.
  const wrote = await $`zsh -c ${`${idf} && python -m esptool --chip esp32s3 -p ${device} -b 921600 --after no-reset write-flash 0x20000 ${bin} > ${flashLog} 2>&1`}`
    .nothrow();
  if (wrote.exitCode !== 0) return { ok: false, why: ["esptool could not write the firmware (see ci/logs on the laptop)"] };
  const serialLog = join(logs, "serial.log");
  const from = existsSync(serialLog) ? readFileSync(serialLog).length : 0;
  // The recorder keeps running after this script moves on: it is the badge's log on the laptop.
  Bun.spawn(["zsh", "-c", `${idf} && exec python ${join(repo, "ci/serial-log.py")} --reset ${device} >> ${serialLog} 2>&1`],
    { stdio: ["ignore", "ignore", "ignore"] }).unref();
  await sleep(bootWatchMs);
  const seen = readFileSync(serialLog).subarray(from).toString("utf8").split("\n");
  const bad = seen.filter((l) => /Guru Meditation|abort\(\) was called|Backtrace:|panicked at|Task watchdog got triggered|safe mode:|crash guard: .*crash\(es\)/.test(l));
  if (bad.length) return { ok: false, why: bad.slice(0, 6).map((l) => l.replace(/^\S+ /, "")) };
  if (!seen.some((l) => l.includes("basecamp badge, build"))) return { ok: false, why: ["the badge did not print its start line after the flash"] };
  return { ok: true, why: [] };
}

let done: string = existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, "utf8")).sha : "";
log(`watching ${slug}@${branch} every ${pollMs / 1000} s; last flashed ${done ? done.slice(0, 7) : "nothing yet"}`);

while (true) {
  const sha = await head();
  if (!sha || sha === done) { await sleep(pollMs); continue; }
  try {
    await status(sha, "pending", "building the firmware");
    const built = await build(sha);
    if (built) {
      let waited = false;
      let newer = false;
      while (!port()) {
        if (!waited) await status(sha, "pending", "built; waiting for the badge on USB");
        waited = true;
        await sleep(pollMs);
        const now = await head();
        if (now && now !== sha) { newer = true; break; }
      }
      if (newer) {
        await status(sha, "error", "built but not flashed: a newer commit arrived while the badge was unplugged");
      } else {
        await status(sha, "pending", "flashing the badge (its screen stands still for about 35 s)");
        const result = await flash(sha, port()!);
        if (result.ok) await status(sha, "success", "flashed; the badge started without a crash");
        else {
          await status(sha, "failure", `flashed, then: ${result.why[0]}`);
          await comment(sha, "The badge was flashed with this commit and did not start cleanly:\n\n```\n" + result.why.join("\n") + "\n```");
        }
      }
    }
  } catch (error) {
    await status(sha, "error", `the build laptop hit an error: ${String(error).slice(0, 100)}`);
  }
  // Failed or not, this commit is dealt with: the next push is what gets built.
  done = sha;
  writeFileSync(stateFile, JSON.stringify({ sha, at: new Date().toISOString() }));
}

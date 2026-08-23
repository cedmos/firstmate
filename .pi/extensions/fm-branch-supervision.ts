// Firstmate supervision branch for Pi (docs/pi-supervision-branch.md).
//
// A persistent second AgentSession - the supervision BRANCH - inside the same
// pi process as the captain's MAIN session. The watcher extension offers each
// actionable wake here (lib/fm-branch-dispatch.ts); the branch handles it with
// real tools and reports through the fm_branch_report custom tool, which
// writes the durable outcome store FIRST (bin/fm-branch-outcome.sh) and then
// merges an append-only note to main's tail. Main's captain/assistant dialog
// is mirrored into the branch as read-only fm-main-mirror context at main's
// turn_end. Pi-only by construction: this file lives in .pi/extensions, so no
// other harness ever loads it, and a home that disables it (config/
// pi-supervision-branch = off) or runs away mode keeps today's wake-to-main
// behavior untouched.
//
// Prefix stability (the cache contract, owner: bin/fm-branch-prompt.sh
// header): the branch's system prompt is the generator's byte-stable output,
// the tool set is BRANCH_TOOL_NAMES in that fixed order on every spawn, and
// one shared per-home prompt_cache_key is set for branch requests in a
// before_provider_request hook - main keeps Pi's default per-session key.
// Wakes, mirrored dialog, and merge notes are all appends at a tail.
//
// Failure direction: every path that cannot reach a working branch falls back
// to delivering the wake to MAIN exactly as before the branch existed - a
// broken branch degrades to today's behavior, never to a lost wake.
import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createAgentSession,
  createBashToolDefinition,
  DefaultResourceLoader,
  getAgentDir,
  SessionManager,
  type AgentSession,
  type ExtensionAPI,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import {
  FM_BRANCH_DISPATCH_EVENT,
  type BranchDispatchOffer,
} from "./lib/fm-branch-dispatch.ts";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const configFile = join(config, "pi-supervision-branch");
const afkFlag = join(state, ".afk");
const sessionsDir = join(state, "branch-session");
const sessionPointer = join(state, ".branch-session");
const mirrorCursorFile = join(state, ".branch-mirror-cursor");
const promptScript = join(fmRoot, "bin", "fm-branch-prompt.sh");
const outcomeScript = join(fmRoot, "bin", "fm-branch-outcome.sh");
const leaseScript = join(fmRoot, "bin", "fm-lease.sh");
const loadedMarker = join(state, ".pi-branch-extension-loaded");
const branchGenerationFile = join(state, ".pi-branch-generation");
const pendingWakesDir = join(state, "branch-pending-wakes");
const ackReceiptsDir = join(state, "branch-ack-receipts");

// Same tool set in the same order on every request (part of the cached
// prefix). "bash" resolves to the customTools override below, which injects
// the branch actor identity deterministically into every shell command.
const BRANCH_TOOL_NAMES = ["read", "bash", "fm_branch_report"] as const;

// One shared prompt_cache_key per home for ALL branch sessions, derived only
// from the home path so it survives restarts; main keeps its own session key.
const branchCacheKey = `fm-branch-${createHash("sha256").update(fmHome).digest("hex").slice(0, 24)}`;

const MIRROR_MESSAGE_CAP = 4000;

type MirrorItem = { tag: "captain" | "main"; text: string };
type MirrorCursor = { file: string; index: number };
type Verdict = "routine" | "captain";
type LockOwnership = "owned" | "other" | "missing";

const scriptEnv = {
  ...process.env,
  FM_HOME: fmHome,
  FM_ROOT_OVERRIDE: fmRoot,
  FM_STATE_OVERRIDE: state,
  FM_CONFIG_OVERRIDE: config,
};

function branchEnabled(): boolean {
  let value = "";
  try {
    value = readFileSync(configFile, "utf8").trim();
  } catch {
    return true; // absent = enabled for every Pi home
  }
  return value === "" || value === "on";
}

function afkActive(): boolean {
  return existsSync(afkFlag);
}

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function textOfContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        const p = part as { type?: string; text?: string };
        return p && p.type === "text" && typeof p.text === "string" ? p.text : "";
      })
      .filter((piece) => piece.length > 0)
      .join("\n");
  }
  return "";
}

// Operational injections (watcher wakes, away-supervisor escalations, launch
// briefs) are fleet machinery, not captain dialog; the report's volume
// analysis counts them apart from dialog, and mirroring them would feed the
// branch its own supervision traffic back. Current injections start with the
// U+2063 operational prefix; the plain legacy form starts with FIRSTMATE.
function isOperationalUserText(text: string): boolean {
  return text.startsWith("⁣") || /^FIRSTMATE[ _]/.test(text);
}

function capMirrorText(text: string): string {
  if (text.length <= MIRROR_MESSAGE_CAP) return text;
  return `${text.slice(0, MIRROR_MESSAGE_CAP)}\n[mirror truncated at ${MIRROR_MESSAGE_CAP} characters]`;
}

function readMirrorCursor(): MirrorCursor {
  try {
    const parsed = JSON.parse(readFileSync(mirrorCursorFile, "utf8")) as Partial<MirrorCursor>;
    if (typeof parsed.file === "string" && typeof parsed.index === "number" && parsed.index >= 0) {
      return { file: parsed.file, index: Math.floor(parsed.index) };
    }
  } catch {
    // Absent or torn cursor: re-mirror the current main session from its
    // start. Idempotent context, so over-mirroring is safe; dropping is not.
  }
  return { file: "", index: 0 };
}

function writeMirrorCursor(cursor: MirrorCursor): void {
  mkdirSync(state, { recursive: true });
  writeFileSync(mirrorCursorFile, `${JSON.stringify(cursor)}\n`);
}

type ReadonlyEntries = {
  getSessionFile(): string | undefined;
  getEntries(): Array<{ type: string }>;
};

// Collect main's not-yet-mirrored captain/assistant dialog from its session
// entries (durable, so a restart replays from the same source). The in-memory
// anchor stops the next turn_end from re-collecting the same entries, while
// the DURABLE cursor advances only after the batch was actually delivered
// into the branch (flushMirror), so a crash between collect and delivery
// re-mirrors rather than drops - over-mirroring is idempotent context.
type MirrorCollectionState = {
  collectAnchor: MirrorCursor | null;
  pendingCursor: MirrorCursor | null;
};

function collectMainDialog(sessionManager: ReadonlyEntries, state: MirrorCollectionState): MirrorItem[] {
  const file = sessionManager.getSessionFile() ?? "";
  const entries = sessionManager.getEntries();
  const anchor = state.collectAnchor ?? readMirrorCursor();
  const start = anchor.file === file ? Math.min(anchor.index, entries.length) : 0;
  const items: MirrorItem[] = [];
  for (const entry of entries.slice(start)) {
    if (entry.type !== "message") continue;
    const message = (entry as { message?: { role?: string; content?: unknown } }).message;
    if (!message) continue;
    if (message.role !== "user" && message.role !== "assistant") continue;
    const text = textOfContent(message.content).trim();
    if (!text) continue;
    if (message.role === "user" && isOperationalUserText(text)) continue;
    items.push({ tag: message.role === "user" ? "captain" : "main", text: capMirrorText(text) });
  }
  state.collectAnchor = { file, index: entries.length };
  state.pendingCursor = state.collectAnchor;
  return items;
}

export default function (pi: ExtensionAPI) {
  let branch: AgentSession | null = null;
  let branchBroken = "";
  let mainStreaming = false;
  let shuttingDown = false;
  let ownershipActivated = false;
  let generationToken = randomUUID();
  let pendingWakeCounter = 0;
  let activeWake: { reportedWakeSequences: Set<number>; mergedWakeSequences: Set<number> } | null = null;
  let activeBranchTools = 0;
  let branchToolWaiters: Array<() => void> = [];
  const mergedOutcomeSequences = new Set<number>();
  const receiptedOutcomeSequences = new Set<number>();
  // Serializes branch work: mirror appends and wake turns run strictly in
  // dispatch order, one at a time (the branch runs drain -> handle -> ack
  // serially by design).
  let branchChain: Promise<void> = Promise.resolve();
  const pendingMirror: MirrorItem[] = [];
  const mirrorCollection: MirrorCollectionState = { collectAnchor: null, pendingCursor: null };

  function markLoaded(): boolean {
    if (lockOwnership() !== "owned") return false;
    try {
      const lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
      mkdirSync(state, { recursive: true });
      process.env.FM_PI_BRANCH_GENERATION = generationToken;
      writeFileSync(loadedMarker, `${process.pid}\n${lockPid}\n${generationToken}\n`);
      writeFileSync(branchGenerationFile, `${generationToken}\n`);
      return true;
    } catch {
      return false;
    }
  }

  function beginBranchTool(): void {
    activeBranchTools += 1;
  }

  function endBranchTool(): void {
    activeBranchTools -= 1;
    if (activeBranchTools !== 0) return;
    const waiters = branchToolWaiters;
    branchToolWaiters = [];
    for (const resolveWaiter of waiters) resolveWaiter();
  }

  function waitForBranchTools(): Promise<void> {
    if (activeBranchTools === 0) return Promise.resolve();
    return new Promise((resolveWaiter) => branchToolWaiters.push(resolveWaiter));
  }

  function releaseBranchLeases(): boolean {
    if (lockOwnership() !== "owned") return false;
    try {
      const result = spawnSync("bash", [leaseScript, "release-actor", "--actor", "branch"], {
        cwd: fmRoot,
        encoding: "utf8",
        env: { ...scriptEnv, FM_SUPERVISION_ACTOR: "branch" },
      });
      return result.status === 0;
    } catch {
      return false;
    }
  }

  function runOutcomeScript(args: string[]): { ok: boolean; stdout: string; detail: string } {
    try {
      const result = spawnSync("bash", [outcomeScript, ...args], {
        cwd: fmRoot,
        encoding: "utf8",
        env: scriptEnv,
      });
      if (result.status === 0) return { ok: true, stdout: (result.stdout || "").trim(), detail: "" };
      return {
        ok: false,
        stdout: "",
        detail: `fm-branch-outcome.sh exited ${result.status ?? "none"}: ${(result.stderr || "").trim()}`,
      };
    } catch (error) {
      return { ok: false, stdout: "", detail: error instanceof Error ? error.message : String(error) };
    }
  }

  // Append-only merge into main. The store row is already durable when this
  // runs; the note is a cache of it at main's tail. Delivery modes per the
  // design: routine+idle appends now with no turn, routine+busy appends after
  // the captain's next prompt, captain-relevant appends and triggers exactly
  // one turn (queued as a follow-up while main is busy).
  function mergeIntoMain(seq: string, task: string, verdict: Verdict, summary: string): void {
    const note = `⎇ branch merged [${verdict}] ${task}: ${summary}`;
    const message = {
      customType: "fm-branch-merge",
      content: note,
      display: true,
      details: { outcomeSeq: Number(seq) },
    };
    if (verdict === "captain") {
      pi.sendMessage(message, { triggerTurn: true, deliverAs: "followUp" });
    } else if (mainStreaming) {
      pi.sendMessage(message, { deliverAs: "nextTurn" });
    } else {
      pi.sendMessage(message, {});
    }
  }

  function markDeliveredOutcomes(sessionManager: ReadonlyEntries): void {
    const delivered = new Set<number>();
    for (const entry of sessionManager.getEntries()) {
      if (entry.type !== "message") continue;
      const message = (
        entry as {
          message?: { role?: string; customType?: string; details?: { outcomeSeq?: unknown } };
        }
      ).message;
      if (message?.role !== "custom" || message.customType !== "fm-branch-merge") continue;
      const seq = message.details?.outcomeSeq;
      if (typeof seq === "number" && Number.isInteger(seq) && seq > 0) delivered.add(seq);
    }
    for (const seq of [...delivered].sort((a, b) => a - b)) {
      if (receiptedOutcomeSequences.has(seq)) continue;
      const marked = runOutcomeScript(["mark-delivered", "--seq", String(seq)]);
      if (marked.ok) receiptedOutcomeSequences.add(seq);
    }
  }

  const reportTool: ToolDefinition = {
    name: "fm_branch_report",
    label: "Report supervision outcome",
    description:
      "Record the outcome of one handled fleet event: write it durably to the outcome store, then merge an append-only note into the captain-facing main conversation. verdict captain surfaces it to the captain in one turn; verdict routine merges silently.",
    parameters: Type.Object({
      task: Type.String({ description: "The task id the event belongs to (or 'fleet' for fleet-wide events)" }),
      verdict: Type.Union([Type.Literal("routine"), Type.Literal("captain")], {
        description: "captain only for what a human must see; routine otherwise",
      }),
      summary: Type.String({
        description:
          "One or two sentences in captain outcome language; include the full https:// PR URL when a PR is involved",
      }),
      wake: Type.Optional(Type.String({ description: "The wake reason line this outcome answers" })),
      wakeSequence: Type.Optional(
        Type.Number({ description: "The drained wake row sequence, or 0 when the drain presented no queue row" }),
      ),
    }),
    execute: async (_toolCallId, params) => {
      const task = String((params as { task: unknown }).task || "").trim();
      const verdictRaw = String((params as { verdict: unknown }).verdict || "");
      const summary = String((params as { summary: unknown }).summary || "").trim();
      const wake = String((params as { wake?: unknown }).wake ?? "").trim();
      const wakeSequenceRaw = (params as { wakeSequence?: unknown }).wakeSequence;
      const wakeSequence =
        typeof wakeSequenceRaw === "number" && Number.isInteger(wakeSequenceRaw) && wakeSequenceRaw >= 0
          ? wakeSequenceRaw
          : null;
      if (!task || !summary || (verdictRaw !== "routine" && verdictRaw !== "captain")) {
        return {
          content: [{ type: "text", text: "invalid report: task, verdict (routine|captain), and summary are required" }],
          details: undefined,
          isError: true,
        };
      }
      if (activeWake && wakeSequence === null) {
        return {
          content: [{ type: "text", text: "invalid report: wakeSequence is required for an active supervision wake" }],
          details: undefined,
          isError: true,
        };
      }
      const wakeState = activeWake;
      if (wakeState && wakeSequence !== null) {
        if (wakeState.reportedWakeSequences.has(wakeSequence)) {
          return {
            content: [{ type: "text", text: `duplicate report: wakeSequence ${wakeSequence} was already recorded` }],
            details: undefined,
            isError: true,
          };
        }
        wakeState.reportedWakeSequences.add(wakeSequence);
      }
      const verdict = verdictRaw as Verdict;
      const appendArgs = ["append", "--task", task, "--verdict", verdict, "--summary", summary, "--result-record"];
      if (wake) appendArgs.push("--wake", wake);
      if (wakeSequence !== null) appendArgs.push("--wake-seq", String(wakeSequence));
      beginBranchTool();
      const appended = runOutcomeScript(appendArgs);
      try {
        if (!appended.ok) {
          if (wakeState && wakeSequence !== null) wakeState.reportedWakeSequences.delete(wakeSequence);
          return {
            content: [{ type: "text", text: `outcome store append failed (nothing merged): ${appended.detail}` }],
            details: undefined,
            isError: true,
          };
        }
        const separator = appended.stdout.indexOf("\t");
        const status = separator > 0 ? appended.stdout.slice(0, separator) : "";
        let stored: { seq?: unknown; task?: unknown; verdict?: unknown; summary?: unknown };
        try {
          stored = JSON.parse(separator > 0 ? appended.stdout.slice(separator + 1) : "") as typeof stored;
        } catch {
          if (wakeState && wakeSequence !== null) wakeState.reportedWakeSequences.delete(wakeSequence);
          return {
            content: [{ type: "text", text: "outcome store returned an invalid append result" }],
            details: undefined,
            isError: true,
          };
        }
        const storedSeq = typeof stored.seq === "number" && Number.isInteger(stored.seq) ? stored.seq : 0;
        const storedTask = typeof stored.task === "string" ? stored.task : "";
        const storedVerdict = stored.verdict === "routine" || stored.verdict === "captain" ? stored.verdict : null;
        const storedSummary = typeof stored.summary === "string" ? stored.summary : "";
        if (
          !storedSeq ||
          !storedTask ||
          !storedVerdict ||
          !storedSummary ||
          !["new", "existing-unread", "existing-delivered"].includes(status)
        ) {
          if (wakeState && wakeSequence !== null) wakeState.reportedWakeSequences.delete(wakeSequence);
          return {
            content: [{ type: "text", text: "outcome store returned an invalid append result" }],
            details: undefined,
            isError: true,
          };
        }
        if (status !== "existing-delivered" && !mergedOutcomeSequences.has(storedSeq)) {
          mergeIntoMain(String(storedSeq), storedTask, storedVerdict, storedSummary);
          mergedOutcomeSequences.add(storedSeq);
        }
        if (wakeState && wakeSequence !== null) wakeState.mergedWakeSequences.add(wakeSequence);
        return {
          content: [{ type: "text", text: `recorded seq ${storedSeq} and merged [${storedVerdict}] into main` }],
          details: undefined,
        };
      } finally {
        endBranchTool();
      }
    },
  };

  async function createBranch(): Promise<AgentSession> {
    const prompt = spawnSync("bash", [promptScript], {
      cwd: fmRoot,
      encoding: "utf8",
      env: scriptEnv,
      maxBuffer: 4 * 1024 * 1024,
    });
    if (prompt.status !== 0 || !prompt.stdout || prompt.stdout.length < 1024) {
      throw new Error(
        `fm-branch-prompt.sh did not produce a usable branch prompt (status=${prompt.status ?? "none"}): ${(prompt.stderr || "").trim()}`,
      );
    }
    mkdirSync(sessionsDir, { recursive: true });
    let sessionManager: SessionManager | null = null;
    try {
      const recorded = readFileSync(sessionPointer, "utf8").trim();
      if (recorded && existsSync(recorded)) {
        sessionManager = SessionManager.open(recorded, sessionsDir);
      }
    } catch {
      sessionManager = null;
    }
    if (!sessionManager) {
      sessionManager = SessionManager.create(fmRoot, sessionsDir);
    }
    // The branch loads no project resources at all: extensions off (so it can
    // never spawn its own branch), skills/context files off (they vary per
    // home and would destabilize the byte-stable prefix). Its whole standing
    // context is the generator's prompt.
    const loader = new DefaultResourceLoader({
      cwd: fmRoot,
      agentDir: getAgentDir(),
      noExtensions: true,
      noSkills: true,
      noPromptTemplates: true,
      noThemes: true,
      noContextFiles: true,
      systemPrompt: prompt.stdout,
      extensionFactories: [
        {
          name: "fm-branch-cache-key",
          factory: (branchPi: ExtensionAPI) => {
            branchPi.on("before_provider_request", (event) => {
              const payload = event.payload;
              // Only providers whose request already carries Pi's default
              // per-session prompt_cache_key get the shared per-home override;
              // any other provider payload passes through untouched.
              if (payload && typeof payload === "object" && "prompt_cache_key" in payload) {
                return { ...(payload as Record<string, unknown>), prompt_cache_key: branchCacheKey };
              }
            });
          },
        },
      ],
    });
    await loader.reload();
    const bashTool = createBashToolDefinition(fmRoot, {
      spawnHook: (context) => ({
        ...context,
        env: {
          ...context.env,
          ...scriptEnv,
          FM_SUPERVISION_ACTOR: "branch",
          FM_LEASE_HOLDER_PID: String(process.pid),
          FM_LEASE_GENERATION: generationToken,
        },
      }),
    });
    const executeBash = bashTool.execute.bind(bashTool);
    bashTool.execute = async (...args) => {
      beginBranchTool();
      try {
        return await executeBash(...args);
      } finally {
        endBranchTool();
      }
    };
    const created = await createAgentSession({
      cwd: fmRoot,
      sessionManager,
      resourceLoader: loader,
      tools: [...BRANCH_TOOL_NAMES],
      customTools: [bashTool as unknown as ToolDefinition, reportTool],
    });
    try {
      writeFileSync(sessionPointer, `${sessionManager.getSessionFile()}\n`);
    } catch {
      // Pointer write failure only costs cross-restart session reuse.
    }
    return created.session;
  }

  async function ensureBranch(): Promise<AgentSession> {
    if (branch) return branch;
    if (branchBroken) throw new Error(branchBroken);
    try {
      branch = await createBranch();
      return branch;
    } catch (error) {
      branchBroken = error instanceof Error ? error.message : String(error);
      throw error;
    }
  }

  async function flushMirror(session: AgentSession): Promise<void> {
    while (pendingMirror.length > 0) {
      const item = pendingMirror[0];
      await session.sendCustomMessage(
        { customType: "fm-main-mirror", content: `[${item.tag}] ${item.text}`, display: false },
        {},
      );
      // Remove only after the append succeeded, so a failure retries the same
      // item in order instead of dropping it.
      pendingMirror.shift();
    }
    if (mirrorCollection.pendingCursor) {
      writeMirrorCursor(mirrorCollection.pendingCursor);
      mirrorCollection.pendingCursor = null;
    }
  }

  async function fallbackToMain(message: string, detail: string): Promise<void> {
    const body = `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. (Supervision branch unavailable, falling back to main: ${detail})`;
    let content = body;
    try {
      // Marked operational like every watcher injection, so the wake is never
      // mistaken for captain input (away-mode return semantics, mirror filter).
      content = encodeFirstmateOperationalInput("watcher", body);
    } catch {
      // An encoding failure must not lose the wake; deliver it unmarked.
    }
    await pi.sendUserMessage(content, { deliverAs: "followUp" });
  }

  function persistAcceptedWake(message: string): string {
    mkdirSync(pendingWakesDir, { recursive: true });
    const id = `${process.pid}-${Date.now()}-${++pendingWakeCounter}`;
    const finalPath = join(pendingWakesDir, `${id}.json`);
    const temporaryPath = join(pendingWakesDir, `.${id}.tmp`);
    writeFileSync(temporaryPath, `${JSON.stringify({ message })}\n`, { flag: "wx" });
    renameSync(temporaryPath, finalPath);
    return finalPath;
  }

  function clearAcceptedWake(path: string): void {
    try {
      unlinkSync(path);
    } catch {}
  }

  function clearAckReceipts(): void {
    let names: string[];
    try {
      names = readdirSync(ackReceiptsDir);
    } catch {
      return;
    }
    for (const name of names) {
      try {
        unlinkSync(join(ackReceiptsDir, name));
      } catch {}
    }
  }

  function consumeMatchingAckReceipt(mergedWakeSequences: Set<number>): boolean {
    let names: string[];
    try {
      names = readdirSync(ackReceiptsDir);
    } catch {
      return false;
    }
    let matched = false;
    for (const name of names) {
      const path = join(ackReceiptsDir, name);
      try {
        const sequences = readFileSync(path, "utf8")
          .split(/\s+/)
          .filter(Boolean)
          .map(Number);
        const receiptSequences = new Set(sequences);
        if (
          sequences.length > 0 &&
          receiptSequences.size === mergedWakeSequences.size &&
          sequences.every((sequence) => Number.isInteger(sequence) && mergedWakeSequences.has(sequence))
        ) {
          matched = true;
        }
        unlinkSync(path);
      } catch {}
    }
    return matched;
  }

  function replayAcceptedWakes(): void {
    if (lockOwnership() !== "owned") return;
    let names: string[];
    try {
      names = readdirSync(pendingWakesDir).filter((name) => name.endsWith(".json")).sort();
    } catch {
      return;
    }
    branchChain = branchChain.then(async () => {
      for (const name of names) {
        const path = join(pendingWakesDir, name);
        try {
          const parsed = JSON.parse(readFileSync(path, "utf8")) as { message?: unknown };
          if (typeof parsed.message !== "string") continue;
          await fallbackToMain(parsed.message, "accepted wake recovered after supervision session shutdown");
          clearAcceptedWake(path);
        } catch {}
      }
    });
  }

  function activateOwnership(): boolean {
    if (shuttingDown || lockOwnership() !== "owned") return false;
    if (ownershipActivated) return markLoaded();
    if (!markLoaded()) return false;
    const leasesReleased = releaseBranchLeases();
    replayAcceptedWakes();
    ownershipActivated = leasesReleased;
    return ownershipActivated;
  }

  function enqueueWake(message: string, pendingPath: string, acceptedGeneration: string): void {
    branchChain = branchChain
      .then(async () => {
        if (
          shuttingDown ||
          acceptedGeneration !== generationToken ||
          !ownershipActivated ||
          lockOwnership() !== "owned"
        ) {
          throw new Error("supervision session shut down before handling the accepted wake");
        }
        const session = await ensureBranch();
        await flushMirror(session);
        const wakeState = {
          reportedWakeSequences: new Set<number>(),
          mergedWakeSequences: new Set<number>(),
        };
        clearAckReceipts();
        activeWake = wakeState;
        try {
          await session.prompt(
            `FIRSTMATE SUPERVISION WAKE: ${message}\n\nHandle this per your operating procedure and finish with fm_branch_report.`,
          );
          if (wakeState.mergedWakeSequences.size === 0) {
            throw new Error("supervision branch completed without a durable outcome report");
          }
          if (!consumeMatchingAckReceipt(wakeState.mergedWakeSequences)) {
            throw new Error("supervision branch completed without acknowledging its reported wake batch");
          }
          clearAcceptedWake(pendingPath);
        } finally {
          if (activeWake === wakeState) activeWake = null;
        }
      })
      .catch(async (error: unknown) => {
        if (
          shuttingDown ||
          acceptedGeneration !== generationToken ||
          !ownershipActivated ||
          lockOwnership() !== "owned"
        ) return;
        try {
          await fallbackToMain(message, error instanceof Error ? error.message : String(error));
          clearAcceptedWake(pendingPath);
        } catch {}
      });
  }

  function enqueueMirrorFlush(): void {
    if (!branch || pendingMirror.length === 0) return;
    branchChain = branchChain
      .then(async () => {
        if (shuttingDown || !branch || !ownershipActivated || lockOwnership() !== "owned") return;
        await flushMirror(branch);
      })
      .catch(() => {
        // Mirror items stay queued in pendingMirror on failure; the next wake
        // or flush retries them in order.
      });
  }

  pi.events?.on?.(FM_BRANCH_DISPATCH_EVENT, (data) => {
    const offer = data as BranchDispatchOffer;
    if (!offer || typeof offer.accept !== "function") return;
    if (!activateOwnership()) return;
    if (!branchEnabled()) return;
    if (afkActive()) return; // the away daemon owns supervision while afk
    if (branchBroken) return; // fail back to today's wake-to-main path
    let pendingPath: string;
    try {
      pendingPath = persistAcceptedWake(offer.message);
    } catch {
      return;
    }
    const acceptedGeneration = generationToken;
    offer.accept();
    enqueueWake(offer.message, pendingPath, acceptedGeneration);
  });

  pi.on?.("agent_start", () => {
    mainStreaming = true;
  });
  pi.on?.("agent_end", () => {
    mainStreaming = false;
  });
  pi.on?.("agent_settled", () => {
    mainStreaming = false;
  });

  // Mirror at main's turn_end: collect the new captain/assistant dialog into
  // the volatile queue, then deliver it through the serialized chain so it
  // lands before any later wake. The durable cursor advances only in
  // flushMirror after the complete pending batch reaches the branch.
  pi.on?.("turn_end", (_event, ctx) => {
    if (!activateOwnership() || !branchEnabled()) return;
    try {
      markDeliveredOutcomes(ctx.sessionManager);
      pendingMirror.push(...collectMainDialog(ctx.sessionManager, mirrorCollection));
    } catch {
      return;
    }
    enqueueMirrorFlush();
  });

  // Pi emits session_shutdown for ordinary same-process replacements (/new,
  // /resume, /fork, reload) as well as terminal quit, exactly as the watcher
  // extension documents. Shutdown quiesces this generation and releases the
  // branch session; a replacement session_start re-arms, and the next wake
  // reopens the persistent branch from its recorded pointer. Terminal quit
  // simply never fires another session_start.
  pi.on?.("session_start", (_event, ctx) => {
    shuttingDown = false;
    branchBroken = "";
    ownershipActivated = false;
    generationToken = randomUUID();
    if (!activateOwnership()) return;
    markDeliveredOutcomes(ctx.sessionManager);
  });

  pi.on?.("session_shutdown", async (_event, ctx) => {
    shuttingDown = true;
    pendingMirror.length = 0;
    mirrorCollection.collectAnchor = null;
    mirrorCollection.pendingCursor = null;
    const stillOwnsLock = lockOwnership() === "owned";
    if (stillOwnsLock) markDeliveredOutcomes(ctx.sessionManager);
    generationToken = randomUUID();
    if (stillOwnsLock) markLoaded();
    if (branch) {
      try {
        branch.dispose();
      } catch {
        // Already gone.
      }
      branch = null;
    }
    await waitForBranchTools();
    if (stillOwnsLock) releaseBranchLeases();
    ownershipActivated = false;
  });

  pi.registerTool?.({
    name: "fm_branch_outcomes",
    label: "Read supervision branch outcomes",
    description:
      "Read the durable outcome store of the supervision branch: what fleet events it handled, each verdict, and each summary. Use when the captain asks what happened in the fleet.",
    promptSnippet: "Read what the supervision branch handled (durable outcome store).",
    parameters: Type.Object({
      recent: Type.Optional(Type.Number({ description: "How many most-recent outcomes to read (default 20)" })),
    }),
    execute: async (_toolCallId, params) => {
      const recentRaw = (params as { recent?: unknown }).recent;
      const recent = typeof recentRaw === "number" && recentRaw >= 1 ? String(Math.floor(recentRaw)) : "20";
      const listed = runOutcomeScript(["list", "--recent", recent]);
      if (!listed.ok) {
        return {
          content: [{ type: "text", text: `could not read the outcome store: ${listed.detail}` }],
          details: undefined,
          isError: true,
        };
      }
      return {
        content: [{ type: "text", text: listed.stdout || "(no branch outcomes recorded)" }],
        details: undefined,
      };
    },
  });

  pi.registerMessageRenderer?.("fm-branch-merge", (message, _options, theme) => {
    return new Text(theme.fg("customMessageText", textOfContent(message.content)), 0, 0);
  });

  markLoaded();
}

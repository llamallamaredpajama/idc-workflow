// ─────────────────────────────────────────────────────────────────────────────
// VENDORED from pi-harnesses · upstream path: extensions/review-orchestrator.ts
// Upstream license: MIT © 2026 IndyDevDan — preserved verbatim in
//   runtime/pi/LICENSE-pi-harnesses (no-edit). See repo-root ATTRIBUTIONS.md.
// Vendored into idc-workflow for the Phase-8 Pi runtime (issue #27, unit B1).
// Upstream source preserved byte-for-byte below; IDC-local additions are marked
// with an "IDC-LOCAL" banner comment.
// ─────────────────────────────────────────────────────────────────────────────

import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { applyExtensionDefaults } from "./themeMap.ts";
import {
  INACTIVITY_TIMEOUT_MS,
  MAX_PARALLEL_REVIEWERS,
  MAX_RETRIES_PER_REVIEWER,
  MIN_RETRY_BUDGET_MS,
  OVERALL_TIMEOUT_MS,
  buildReviewerPiArgs,
  buildReviewPacket,
  consolidateReviewFindings,
  formatRunSummary,
  isRetryableReviewerFailure,
  latestRunSummariesFromDisk,
  makeReviewEvent,
  parseReviewCommandArgs,
  previewReviewPacket,
  renderReviewReport,
  resolveRunOutcome,
  reviewersForRiskTier,
  safeRunSlug,
  timeoutForReviewer,
  validateReviewerOutput,
  type ReviewerOutput,
} from "./review-orchestrator-core.ts";

type WorkerResult = {
  reviewer: string;
  ok: boolean;
  output?: ReviewerOutput;
  error?: string;
  durationMs: number;
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  costUsd?: number;
  stopReason?: string;
};

const PROMPT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "profiles", "cross-cutting", "review", "reviewers");

export default function reviewOrchestrator(pi: ExtensionAPI) {
  pi.registerFlag("review-workers", {
    description: "Maximum parallel review workers",
    type: "string",
    default: String(MAX_PARALLEL_REVIEWERS),
  });

  pi.on("session_start", (_event, ctx) => {
    applyExtensionDefaults(import.meta.url, ctx);
    if (ctx.hasUI) ctx.ui.setStatus("review-orchestrator", "review orchestrator ready");
  });

  pi.registerCommand("review-diff", {
    description: "Build and run a structured review for a local diff: /review-diff [--base origin/main] [--head HEAD] [--dry-run] [--packet-only] [--topic <slug>]",
    handler: async (args, ctx) => {
      const parsed = withFlagDefaults(pi, parseReviewCommandArgs(args));
      const topic = parsed.topic ?? "local-review";
      if (parsed.dryRun) {
        const preview = previewReviewPacket({ cwd: ctx.cwd, base: parsed.base, head: parsed.head, topic, request: args });
        emit(ctx, pi, [
          `review-diff dry-run`,
          `base/head: ${parsed.base}...${parsed.head}`,
          `planned packet root: ${preview.packetRoot}`,
          `planned report: ${preview.reportPath}`,
          `risk tier: ${preview.riskTier}`,
          `changed file count: ${preview.fileCount}`,
          `sensitive: ${preview.sensitive}`,
          `reviewers: ${reviewersForRiskTier(preview.riskTier).join(", ")}`,
          `no packet written and no worker child processes launched`,
        ].join("\n"));
        return;
      }
      await runReview({ pi, ctx, base: parsed.base, head: parsed.head, topic, request: args, pr: parsed.pr, post: parsed.post, packetOnly: parsed.packetOnly, workers: parsed.workers });
    },
  });

  pi.registerCommand("review-pr", {
    description: "Build and run a structured review for a GitHub PR: /review-pr <number> [--post] [--dry-run] [--packet-only]",
    handler: async (args, ctx) => {
      const parsed = withFlagDefaults(pi, parseReviewCommandArgs(args));
      if (!parsed.pr) {
        emit(ctx, pi, "Usage: /review-pr <number> [--post] [--dry-run] [--packet-only]");
        return;
      }
      const meta = await readPrMetadata(pi, ctx.cwd, parsed.pr);
      if ("error" in meta) {
        emit(ctx, pi, `Cannot resolve PR #${parsed.pr}: ${meta.error}`);
        return;
      }
      const base = parsed.base === "origin/main" && meta.baseRefName ? `origin/${meta.baseRefName}` : parsed.base;
      const head = parsed.head === "HEAD" && meta.headRefName ? `origin/${meta.headRefName}` : parsed.head;
      const topic = parsed.topic ?? `pr-${parsed.pr}-${safeRunSlug(meta.title || "review")}`;
      const request = [meta.title, meta.body, args].filter(Boolean).join("\n\n");
      if (parsed.dryRun) {
        const preview = previewReviewPacket({ cwd: ctx.cwd, base, head, topic, request, pr: parsed.pr });
        emit(ctx, pi, [
          `review-pr dry-run #${parsed.pr}`,
          `base/head: ${base}...${head}`,
          `planned packet root: ${preview.packetRoot}`,
          `planned report: ${preview.reportPath}`,
          `risk tier: ${preview.riskTier}`,
          `changed file count: ${preview.fileCount}`,
          `post review: ${parsed.post}`,
          `no packet written and no worker child processes launched`,
        ].join("\n"));
        return;
      }
      await runReview({ pi, ctx, base, head, topic, request, pr: parsed.pr, post: parsed.post, packetOnly: parsed.packetOnly, workers: parsed.workers });
    },
  });

  pi.registerCommand("review-status", {
    description: "List latest .pi/review/runs with risk, verdict, report, duration, and reviewer counts",
    handler: async (_args, ctx) => {
      emit(ctx, pi, formatRunSummary(latestRunSummariesFromDisk(ctx.cwd)));
    },
  });
}

async function runReview(input: { pi: ExtensionAPI; ctx: ExtensionCommandContext; base: string; head: string; topic: string; request: string; pr?: number; post?: boolean; packetOnly?: boolean; workers?: number }) {
  const { pi, ctx } = input;
  const started = Date.now();
  const packet = buildReviewPacket({ cwd: ctx.cwd, base: input.base, head: input.head, topic: input.topic, request: input.request, pr: input.pr });
  appendEvent(ctx.cwd, packet.packetRoot, makeReviewEvent({ runId: packet.runId, phase: "packet", level: "info", event: "review_run_started", message: "review run started" }));
  const reviewers = reviewersForRiskTier(packet.manifest.riskTier);
  const workerResults = input.packetOnly ? [] : await runWorkers({ ctx, packetRoot: packet.packetRoot, reviewers, runId: packet.runId, workers: input.workers });
  const outputs = workerResults.filter((result): result is WorkerResult & { output: ReviewerOutput } => result.ok && !!result.output).map((result) => result.output);
  const consolidated = consolidateReviewFindings(outputs);
  const reviewerSucceeded = workerResults.filter((result) => result.ok).length;
  const reviewerFailed = workerResults.filter((result) => !result.ok).length;
  // A run without every reviewer's accepted output fails closed and never posts approval.
  const outcome = resolveRunOutcome({ packetOnly: Boolean(input.packetOnly), reviewerCount: reviewers.length, acceptedCount: outputs.length, findings: consolidated.findings });
  const verdict = outcome.verdict;
  const findingsLine = `${consolidated.findings.length} consolidated finding(s) from ${outputs.length}/${reviewers.length} reviewer(s).`;
  let summary: string;
  if (input.packetOnly) summary = "Packet-only run; no reviewer child processes launched. Verdict fails closed.";
  else if (!outcome.complete) summary = `${outcome.incompleteReason}; verdict fails closed. ${findingsLine}`;
  else summary = findingsLine;
  const report = renderReviewReport({
    topic: input.topic,
    base: input.base,
    head: input.head,
    riskTier: packet.manifest.riskTier,
    verdict,
    summary,
    findings: consolidated.findings,
    testGaps: consolidated.testGaps,
    reviewerResults: workerResults.map((result) => ({ reviewer: result.reviewer, verdict: result.output?.verdict ?? (result.ok ? "pass" : "failed"), findingCount: result.output?.findings.length ?? 0, durationMs: result.durationMs })),
    surfacesCleared: consolidated.surfacesCleared,
    telemetry: {
      durationMs: Date.now() - started,
      reviewerSucceeded,
      reviewerFailed,
      costUsd: workerResults.reduce((sum, result) => sum + (result.costUsd ?? 0), 0),
    },
    packetRoot: packet.packetRoot,
  });
  const reportAbs = resolve(ctx.cwd, packet.manifest.reportPath);
  mkdirSync(dirname(reportAbs), { recursive: true });
  writeFileSync(reportAbs, report, "utf8");
  writeJson(resolve(ctx.cwd, packet.packetRoot, "coordinator.json"), {
    schemaVersion: 1,
    verdict,
    durationMs: Date.now() - started,
    reviewerSucceeded,
    reviewerFailed,
    findings: consolidated.findings,
  });
  appendEvent(ctx.cwd, packet.packetRoot, makeReviewEvent({ runId: packet.runId, phase: "report", level: "info", event: "report_written", message: `wrote ${packet.manifest.reportPath}` }));

  let postNote: string | undefined;
  if (input.post && input.pr) {
    if (!outcome.complete) {
      appendEvent(ctx.cwd, packet.packetRoot, makeReviewEvent({ runId: packet.runId, phase: "pr", level: "warning", event: "pr_review_skipped", message: `not posting PR review #${input.pr}: ${outcome.incompleteReason}` }));
      postNote = `NOT posted to PR #${input.pr}: ${outcome.incompleteReason}.`;
    } else {
      const posted = await postPrReview(pi, ctx.cwd, input.pr, verdict, reportAbs, packet.runId, packet.packetRoot);
      postNote = posted ? `PR review posted to #${input.pr}.` : `WARNING: failed to post PR review #${input.pr} — see ${packet.packetRoot}/events.jsonl.`;
    }
  }
  appendEvent(ctx.cwd, packet.packetRoot, makeReviewEvent({ runId: packet.runId, phase: "complete", level: "info", event: "review_run_completed", message: `review completed with ${verdict}` }));
  emit(ctx, pi, [`Review complete: ${verdict}`, postNote, `Report: ${packet.manifest.reportPath}`, `Packet: ${packet.packetRoot}`].filter(Boolean).join("\n"));
}

async function runWorkers(input: { ctx: ExtensionCommandContext; packetRoot: string; reviewers: string[]; runId: string; workers?: number }): Promise<WorkerResult[]> {
  const results: WorkerResult[] = [];
  const requestedWorkers = Number.isFinite(input.workers) ? Number(input.workers) : MAX_PARALLEL_REVIEWERS;
  const concurrency = Math.max(1, Math.min(MAX_PARALLEL_REVIEWERS, requestedWorkers, input.reviewers.length));
  const overallDeadline = Date.now() + OVERALL_TIMEOUT_MS;
  let next = 0;
  const heartbeat = setInterval(() => {
    const complete = results.length;
    if (input.ctx.hasUI) input.ctx.ui.setStatus("review-orchestrator", `review: ${complete}/${input.reviewers.length} reviewers complete`);
  }, 30_000);
  try {
    await Promise.all(new Array(concurrency).fill(null).map(async () => {
      while (next < input.reviewers.length) {
        const reviewer = input.reviewers[next++];
        results.push(await runWorkerWithRetry(input.ctx.cwd, input.packetRoot, reviewer, input.runId, overallDeadline));
      }
    }));
  } finally {
    clearInterval(heartbeat);
    if (input.ctx.hasUI) input.ctx.ui.setStatus("review-orchestrator", undefined);
  }
  return results;
}

async function runWorkerWithRetry(cwd: string, packetRoot: string, reviewer: string, runId: string, overallDeadline: number): Promise<WorkerResult> {
  let last: WorkerResult | undefined;
  for (let attempt = 0; attempt <= MAX_RETRIES_PER_REVIEWER; attempt++) {
    const remainingMs = overallDeadline - Date.now();
    if (remainingMs <= 0) {
      last = { reviewer, ok: false, error: `overall review budget exhausted (${OVERALL_TIMEOUT_MS}ms)`, durationMs: 0 };
      appendEvent(cwd, packetRoot, makeReviewEvent({ runId, phase: "worker", level: "error", event: "reviewer_failed", message: `${reviewer} failed: ${last.error}`, reviewer, durationMs: 0 }));
      return last;
    }
    appendEvent(cwd, packetRoot, makeReviewEvent({ runId, phase: "worker", level: "info", event: "reviewer_started", message: `${reviewer} started`, reviewer, attempt }));
    last = await runWorker(cwd, packetRoot, reviewer, { runId, timeoutMs: Math.min(timeoutForReviewer(reviewer), remainingMs) });
    if (last.ok) {
      appendEvent(cwd, packetRoot, makeReviewEvent({ runId, phase: "worker", level: "info", event: "reviewer_completed", message: `${reviewer} completed`, reviewer, durationMs: last.durationMs, findingCount: last.output?.findings.length ?? 0, stopReason: last.stopReason }));
      return last;
    }
    if (attempt < MAX_RETRIES_PER_REVIEWER && isRetryableReviewerFailure(last.error ?? "") && overallDeadline - Date.now() > MIN_RETRY_BUDGET_MS) {
      appendEvent(cwd, packetRoot, makeReviewEvent({ runId, phase: "worker", level: "warning", event: "reviewer_retry", message: `${reviewer} retrying: ${last.error}`, reviewer, attempt }));
      continue;
    }
    appendEvent(cwd, packetRoot, makeReviewEvent({ runId, phase: "worker", level: "error", event: "reviewer_failed", message: `${reviewer} failed: ${last.error}`, reviewer, durationMs: last.durationMs }));
    return last;
  }
  return last ?? { reviewer, ok: false, error: "worker did not start", durationMs: 0 };
}

// Exported for tests: the stub-pi suites drive this directly via PATH overrides.
export async function runWorker(cwd: string, packetRoot: string, reviewer: string, options?: { runId?: string; timeoutMs?: number; inactivityMs?: number }): Promise<WorkerResult> {
  const started = Date.now();
  const jsonlPath = resolve(cwd, packetRoot, "reviewers", `${reviewer}.jsonl`);
  const jsonPath = resolve(cwd, packetRoot, "reviewers", `${reviewer}.json`);
  mkdirSync(dirname(jsonlPath), { recursive: true });
  const args = buildReviewerPiArgs({ packetRoot, reviewer, promptRoot: PROMPT_ROOT, model: process.env.PI_REVIEW_WORKER_MODEL, thinking: process.env.PI_REVIEW_WORKER_THINKING });
  const result = await runPiJson(cwd, args, jsonlPath, {
    timeoutMs: options?.timeoutMs ?? timeoutForReviewer(reviewer),
    inactivityMs: options?.inactivityMs ?? INACTIVITY_TIMEOUT_MS,
  });
  const fail = (error: string): WorkerResult => ({ reviewer, ok: false, error, durationMs: Date.now() - started, stopReason: result.stopReason });
  const stderrNote = result.stderr.trim() ? `: ${result.stderr.trim().slice(0, 500)}` : "";
  if (result.spawnError) return fail(`pi spawn failed: ${result.spawnError}`);
  if (result.killedBy) return fail(result.killedBy);
  if (result.exitCode !== 0) return fail(`pi exited ${result.exitCode}${stderrNote}`);
  const finalText = result.finalText.trim();
  if (!finalText) return fail(`pi produced no reviewer output${stderrNote}`);
  let parsed: ReviewerOutput;
  try {
    parsed = JSON.parse(finalText) as ReviewerOutput;
  } catch (error: any) {
    const incomplete = result.stopReason === "length" ? " (length stop reason, incomplete json)" : "";
    return fail(`invalid JSON reviewer output${incomplete}: ${error?.message ?? error}`);
  }
  const validation = validateReviewerOutput(parsed, { expectedReviewer: reviewer });
  if (!validation.valid) return fail(`schema-invalid reviewer output: ${validation.reason}`);
  try {
    writeJson(jsonPath, parsed);
  } catch (error: any) {
    // The in-memory output is still usable; record the persistence failure instead of
    // discarding an already-validated review.
    appendEvent(cwd, packetRoot, makeReviewEvent({ runId: options?.runId ?? "unknown", phase: "worker", level: "warning", event: "reviewer_artifact_write_failed", message: `${reviewer} output not persisted: ${error?.message ?? error}`, reviewer }));
  }
  return { reviewer, ok: true, output: parsed, durationMs: Date.now() - started, stopReason: result.stopReason, ...result.usage };
}

type PiRunResult = {
  finalText: string;
  stopReason?: string;
  usage: Partial<WorkerResult>;
  exitCode: number | null;
  stderr: string;
  spawnError?: string;
  killedBy?: string;
};

function runPiJson(cwd: string, args: string[], jsonlPath: string, limits: { timeoutMs: number; inactivityMs: number }): Promise<PiRunResult> {
  return new Promise((resolvePromise) => {
    const proc = spawn("pi", args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let buffer = "";
    let stderr = "";
    let finalText = "";
    let stopReason: string | undefined;
    let killedBy: string | undefined;
    let rawAppendBroken = false;
    let done = false;
    const usage: Partial<WorkerResult> = {};
    const kill = (reason: string) => {
      killedBy = reason;
      proc.kill("SIGKILL");
    };
    const deadline = setTimeout(() => kill(`timeout after ${limits.timeoutMs}ms`), limits.timeoutMs);
    let inactivity: ReturnType<typeof setTimeout> | undefined;
    const armInactivity = () => {
      clearTimeout(inactivity);
      inactivity = setTimeout(() => kill(`inactivity timeout after ${limits.inactivityMs}ms`), limits.inactivityMs);
    };
    armInactivity();
    const clearTimers = () => {
      clearTimeout(deadline);
      clearTimeout(inactivity);
    };
    const appendRaw = (chunk: string) => {
      if (rawAppendBroken) return;
      try {
        writeFileSync(jsonlPath, chunk, { flag: "a" });
      } catch {
        // Transcript persistence is best-effort; never let a disk failure inside a
        // stream handler crash the host session or wedge this promise.
        rawAppendBroken = true;
      }
    };
    const processLine = (line: string) => {
      if (!line.trim()) return;
      try {
        const event = JSON.parse(line);
        const message = event.message;
        if (event.type === "message_end" && message?.role === "assistant") {
          finalText = textFromMessage(message) || finalText;
          stopReason = message.stopReason ?? stopReason;
          const msgUsage = message.usage ?? {};
          usage.inputTokens = (usage.inputTokens ?? 0) + (msgUsage.input ?? 0);
          usage.outputTokens = (usage.outputTokens ?? 0) + (msgUsage.output ?? 0);
          usage.cacheReadTokens = (usage.cacheReadTokens ?? 0) + (msgUsage.cacheRead ?? 0);
          usage.cacheWriteTokens = (usage.cacheWriteTokens ?? 0) + (msgUsage.cacheWrite ?? 0);
          usage.costUsd = (usage.costUsd ?? 0) + (msgUsage.cost?.total ?? 0);
        }
      } catch {
        // Raw child output is preserved in jsonl; malformed lines do not crash the orchestrator.
      }
    };
    proc.stdout.on("data", (data) => {
      // After an early kill-resolve, orphaned grandchildren can keep the pipe alive;
      // ignore their output instead of re-arming timers and parsing discarded lines.
      if (done) return;
      armInactivity();
      const text = data.toString();
      appendRaw(text);
      buffer += text;
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) processLine(line);
    });
    proc.stderr.on("data", (data) => {
      if (done) return;
      stderr += data.toString();
    });
    const finish = (result: PiRunResult) => {
      if (done) return;
      done = true;
      clearTimers();
      resolvePromise(result);
    };
    proc.on("close", (code) => {
      if (buffer.trim()) processLine(buffer);
      finish({ finalText, stopReason, usage, exitCode: code, stderr, killedBy });
    });
    // A killed child's orphaned grandchildren can hold the stdio pipes open, so "close"
    // may never fire; once we killed it, "exit" is the completion signal.
    proc.on("exit", () => {
      if (killedBy) finish({ finalText, stopReason, usage, exitCode: null, stderr, killedBy });
    });
    proc.on("error", (error) => {
      finish({ finalText: "", usage: {}, exitCode: null, stderr, spawnError: error.message });
    });
  });
}

function textFromMessage(message: any): string {
  const content = message?.content;
  if (!Array.isArray(content)) return "";
  return content.filter((part) => part?.type === "text").map((part) => part.text ?? "").join("\n");
}

function appendEvent(cwd: string, packetRoot: string, event: Record<string, unknown>) {
  const file = resolve(cwd, packetRoot, "events.jsonl");
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, `${JSON.stringify(event)}\n`, { flag: "a" });
}

function writeJson(path: string, value: unknown) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function emit(ctx: ExtensionCommandContext, pi: ExtensionAPI, content: string) {
  if (ctx.hasUI) ctx.ui.notify(content.split("\n")[0] || content, "info");
  pi.sendMessage({ customType: "review-orchestrator", content, display: true });
}

function withFlagDefaults(pi: ExtensionAPI, parsed: ReturnType<typeof parseReviewCommandArgs>) {
  // CLI flags arrive as strings (registerFlag supports only boolean | string).
  const workersFromFlag = Number(pi.getFlag?.("review-workers"));
  return {
    ...parsed,
    workers: parsed.workers ?? (Number.isFinite(workersFromFlag) ? workersFromFlag : undefined),
  };
}

type PrMetadata = { title?: string; body?: string; baseRefName?: string; headRefName?: string };

async function readPrMetadata(pi: ExtensionAPI, cwd: string, pr: number): Promise<PrMetadata | { error: string }> {
  const result = await pi.exec("gh", ["pr", "view", String(pr), "--json", "title,body,baseRefName,headRefName"], { cwd, timeout: 10_000 });
  if (result.code !== 0) return { error: `gh pr view failed (exit ${result.code}): ${(result.stderr || result.stdout).trim().slice(0, 300)}` };
  try {
    return JSON.parse(result.stdout || "{}") as PrMetadata;
  } catch (error: any) {
    return { error: `gh pr view returned invalid JSON: ${error?.message ?? error}` };
  }
}

async function postPrReview(pi: ExtensionAPI, cwd: string, pr: number, verdict: string, reportAbs: string, runId: string, packetRoot: string): Promise<boolean> {
  // IDC-LOCAL: any FAIL-rung verdict (FAIL or FAIL-BLOCKED) requests changes; only PASS/PASS-WITH-NITS approve.
  const requestChanges = verdict === "FAIL" || verdict === "FAIL-BLOCKED";
  const args = ["pr", "review", String(pr), requestChanges ? "--request-changes" : "--approve", "--body-file", reportAbs];
  const result = await pi.exec("gh", args, { cwd, timeout: 30_000 });
  const ok = result.code === 0;
  appendEvent(cwd, packetRoot, makeReviewEvent({
    runId,
    phase: "pr",
    level: ok ? "info" : "error",
    event: ok ? "pr_review_posted" : "pr_review_post_failed",
    message: ok ? `posted PR review #${pr}` : `failed to post PR review #${pr}: ${result.stderr || result.stdout}`,
  }));
  return ok;
}

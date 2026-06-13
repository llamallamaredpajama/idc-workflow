// Phase 8 smoke helper (F6): the VENDORED Pi review core must emit the IDC verdict ladder.
//
// The IDC validator (scripts/idc_review_verdict_check.py) is the source of truth for the
// verdict enum: {PASS, PASS-WITH-NITS, FAIL, FAIL-BLOCKED}, with blocker→FAIL-BLOCKED,
// major→FAIL, minor/nit→PASS-WITH-NITS, none→PASS. The vendored core's verdictForFindings()
// must produce exactly those strings (NOT the upstream "FAIL/BLOCKED"), so a Pi review report
// is a valid automerge gate.
//
// Usage: bun phase8-pi-review-verdict.ts <outdir>
//   - asserts the per-severity ladder (exit 1 on any mismatch)
//   - writes <outdir>/blocker.json and <outdir>/major.json — verdict docs whose `verdict`
//     field is produced BY THE CORE — for the bash wrapper to validate with the Python checker.

import { verdictForFindings, resolveRunOutcome } from "../../runtime/pi/extensions/review-orchestrator-core.ts";
import { writeFileSync } from "node:fs";

const outdir = process.argv[2];
if (!outdir) {
  console.error("usage: bun phase8-pi-review-verdict.ts <outdir>");
  process.exit(2);
}

let bad = 0;
const check = (name: string, got: string, expect: string) => {
  const ok = got === expect;
  if (!ok) bad++;
  console.log(`${ok ? "ok  " : "MISS"} ${name}: got=${got} expect=${expect}`);
};

// (1) per-findings ladder — the core fix
check("blocker", verdictForFindings([{ severity: "blocker" }]), "FAIL-BLOCKED");
check("major", verdictForFindings([{ severity: "major" }]), "FAIL");
check("blocker+major", verdictForFindings([{ severity: "major" }, { severity: "blocker" }]), "FAIL-BLOCKED");
check("minor", verdictForFindings([{ severity: "minor" }]), "PASS-WITH-NITS");
check("nit", verdictForFindings([{ severity: "nit" }]), "PASS-WITH-NITS");
check("none", verdictForFindings([]), "PASS");

// (2) incomplete / packet-only runs must still be a VALID enum value (hard-block rung), never
//     the upstream "FAIL/BLOCKED" which the validator rejects outright.
const VALID = new Set(["PASS", "PASS-WITH-NITS", "FAIL", "FAIL-BLOCKED"]);
const inc = resolveRunOutcome({ packetOnly: false, reviewerCount: 3, acceptedCount: 2, findings: [] });
check("incomplete-run-enum-valid", String(VALID.has(inc.verdict)), "true");
check("incomplete-run", inc.verdict, "FAIL-BLOCKED");
const pkt = resolveRunOutcome({ packetOnly: true, reviewerCount: 1, acceptedCount: 1, findings: [] });
check("packet-only", pkt.verdict, "FAIL-BLOCKED");

// (3) end-to-end: emit verdict docs whose `verdict` is produced by the core, for the Python
//     validator to accept (proves the core's enum is validator-compatible + consistent).
const finding = (dimension: string, severity: string) => ({
  dimension,
  severity,
  confidence: 0.9,
  evidence: `vendored-core ${severity} finding for validator round-trip`,
  attack: `exercise the ${dimension} weakness`,
  unblock: `resolve the ${severity} ${dimension} issue`,
  fingerprint: `${dimension}:${severity}:fixture`,
});
const blocker = finding("security", "blocker");
const major = finding("protocol", "major");
writeFileSync(`${outdir}/blocker.json`, JSON.stringify({ verdict: verdictForFindings([blocker]), findings: [blocker] }, null, 2));
writeFileSync(`${outdir}/major.json`, JSON.stringify({ verdict: verdictForFindings([major]), findings: [major] }, null, 2));

if (bad > 0) {
  console.error(`${bad} verdict mismatch(es) — the Pi core does not emit the IDC ladder`);
  process.exit(1);
}
console.log("all vendored-core verdicts match the IDC ladder");

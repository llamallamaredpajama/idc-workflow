# Part 4b (V-AUTH) — sandbox e2e receipt

Driver: `codex exec --cd <install sandbox> --dangerously-bypass-approvals-and-sandbox` against candidate
plugin /Users/jeremy/dev/proj/idc-workflow-p4b @ 12e323f, filesystem backend. Capture:
/Users/jeremy/dev/sandbox/_idc-observability/run-vauth-e2e.txt. This is the receipt the work order requires
because V-AUTH changes how builds run — a green smoke suite alone is not sufficient proof.

## The four points — held, in the gate's own words

1. **Write BEFORE claim → DENIED.** `"action `write` is not in the live authorization."`
   (the build entry mint is read-only-until-claim, as designed).
2. **Write AFTER claim, INSIDE the contract's touch → ALLOWED** (twice).
   `"mutation is inside the live authorization boundary"`.
3. **Write OUTSIDE touch → DENIED at mutation time.**
   `"`web/idc-vauth-demo.txt` is outside the live authorization boundary (scripts)."`
   Plus deny-beats-allow: `"`scripts/legacy/blocked.txt` is inside the live authorization's off-limits set (scripts/legacy)."`
4. **After finish → DENIED again.** `"action `write` is not in the live authorization."`
   Run report: "HELD — post-finish authorization retired and writes denied again. Live-contract pointer retired: YES."

Transition journal (the real artifact the run left): records `claim` then `close` — the ticket went through
the full lifecycle and closed.

## Hook-fidelity caveat
Claude Code hooks do not fire inside Codex. This proves the SCRIPTS + playbook behave end to end and the gate's
`evaluate` returns the right allow/deny at each stage; it does not exercise the Claude hook spine. The mint is
driven by the same scripts a hook would call.

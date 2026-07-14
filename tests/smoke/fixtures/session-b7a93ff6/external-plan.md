# External execution plan

This sanitized fixture describes a complete program. Drive is the foundation; every other unit names
its declared prerequisites. It contains no private path, URL, credential, or unrelated plan prose.

## Drive — Foundation

Dependencies: none.

## B1 — Bootstrap lane one

Dependencies: Drive.

**B2 — Bootstrap lane two**

Dependencies: Drive.

1. U0 — Establish the baseline

Dependencies: Drive.

## U1 — Prepare the first capability

Dependencies: U0 and B1.

## U2 — Prepare the second capability

Dependencies: U0 and B2.

## U3 — Join the bootstrap lanes

Dependencies: U1 and U2.

## U4 — Add the primary workflow

Dependencies: U3.

## U5 — Add the verification workflow

Dependencies: U4.

## U6 — Add recovery behavior

Dependencies: U4 and U5.

## U7 — Exercise the integrated program

Dependencies: U6.

## U8 — Complete the rollout proof

Dependencies: U7.

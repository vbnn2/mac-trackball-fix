# Repository instructions

## Scroll work

Before diagnosing, designing, or changing scrolling behavior, read
[`Helper/Core/Scroll/SCROLL_REGRESSION_LOG.md`](Helper/Core/Scroll/SCROLL_REGRESSION_LOG.md) in full.

For every material scroll fix:

1. Preserve the invariants and previously accepted behavior documented there.
2. Check current telemetry before attributing a perceived delay to the queue, animator, display link, target app, or
   hardware.
3. Run the regression matrix relevant to the change; do not validate only the symptom being fixed.
4. Append a dated entry describing the symptom, evidence, root cause, change, verification, and remaining tradeoffs.
5. Do not restore a rejected approach without new captured evidence and an explanation of why its previous failure
   mode no longer applies.

The regression ledger is the canonical history for this fork's scroll tuning. Older scroll notes remain useful
background, but the ledger takes precedence when they conflict.

# Scroll replay fixtures

These sanitized JSON Lines files preserve physical-input evidence for the TB800
ring rewrite. They intentionally omit application titles, pointer coordinates,
device serial numbers, and other private context.

The Phase 2 replay runner will consume these record kinds:

- `metadata`: fixture identity, capture source, and scenario.
- `session`: reset/idle/target/config/display boundaries.
- `input`: timestamped physical reports and captured CG fields.
- `legacy-observation`: measured behavior from the frozen engine.
- `expected`: engine-independent invariants for future replay.

Unknown fields are `null`; fixtures must not invent missing telemetry.

`rawUnits` uses the canonical CGEvent direction convention after the observed
TB800 axis-polarity normalization. `hidElementUnits` may additionally preserve
the descriptor's unnormalized integer when it is available.

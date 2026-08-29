# RPG Scenario Contract v1

The RPG contract is a local, deterministic data format. It defines state and
rule inputs only; persistence, UI, narrative generation, and rule execution are
outside this contract.

## Package shape

An `RpgScenario` contains:

- `schemaVersion`: contract schema version. Version 1 is currently supported.
- `metadata`: stable scenario ID, display name, package version, author, and
  tags.
- `initialSeed`: the seed from which deterministic execution starts.
- `compatibility`: minimum/maximum engine versions and required capabilities.
- `protectedFields`: state paths that narrative-derived patches cannot change.
- definitions for attributes, items, actors, locations, quests, and actions.
- `initialState`: all deterministic inputs needed to start or resume execution.

IDs start with a letter and contain only letters, digits, `_`, or `-`. IDs are
stable addresses and must not be reused for a different definition in a later
package version.

## Runtime state

`RpgRuntimeState` persists the scenario ID/version, turn, random generator
state, consumed roll count, attributes, variables, inventory, relationships,
clock, location, quests, cooldowns, and event history. Re-serializing a state
does not regenerate its seed or any other deterministic input.

Snapshot metadata records the branch, optional parent snapshot, turn, random
state, consumed roll count, creation time, and an optional state hash. This is
the minimum ownership information needed by future rollback and branch storage.

## Declarative rules

Conditions use an `operator`, a state `path`, and a JSON value, or combine
nested conditions with `all`, `any`, and `not`. Effects use a closed
`RpgEffectType` enum. There are no callbacks, expressions, source code, or
script hooks in either contract.

Dice use canonical `NdM`, `NdM+K`, or `NdM-K` notation. Examples are `1d20`,
`2d6+3`, and `4d8-1`.

Recognized state paths include:

- `attributes.<attributeId>` and `variables.<variableId>`
- `inventory.<itemId>.quantity`
- `relationships.<actorId>.score`
- `quests.<questId>.status` and `quests.<questId>.stageId`
- `cooldowns.<actionId>`
- `turn`, `locationId`, `clock.*`, and `random.*`

References in conditions, effects, runtime state, and cooldowns must resolve to
definitions in the same scenario package.

## Protected mutations

The default protected fields include random generator inputs, turn, inventory,
quests, cooldowns, and event history. Every proposed `RpgStatePatch` declares
whether it comes from the rule engine or narrative. Validate narrative patches
with `RpgScenarioValidator.validatePatch`; an effect whose state path overlaps a
protected field is rejected. Applications must not apply an unvalidated patch
from LLM output.

## Validation

Run `RpgScenarioValidator.validate` after decoding a package and before making
it available to the engine. Each issue contains a machine-readable `code`, a
JSON-like `path`, and an actionable `message`. `throwIfInvalid` is available for
callers that prefer exception-based control flow.

The contract intentionally models JSON only. A future YAML importer must parse
YAML into the same JSON-shaped values and run this validator; it must not add
language-specific tags or executable objects.

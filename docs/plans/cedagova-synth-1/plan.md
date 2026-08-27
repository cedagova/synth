# Implementation Plan: Synth: native macOS high-quality MusicXML player with per-line synth/instrument sound assignment

- Planning issue: https://github.com/cedagova/synth/issues/1
- Planning PR: PLANNING-TODO
- Status: In progress
- Root classification: PLANNING-TODO
- Delivery topology: PLANNING-TODO
- Planner: Planning lead (Claude Fable 5, implementation-planning-lead)
- Started: 2026-08-27

<!-- For a product-definition input, record its exact PR URL and reviewed head
here and preserve its requirements, decisions, evidence, assumptions, brief,
and native product parent throughout the plan. -->

## Pinned baselines

| Repository | Baseline |
| --- | --- |
| `cedagova/synth` | `63f1313b767a0cefdccae7a91daf1e86bfede1d9` |

## Preserved objective and boundaries

PLANNING-TODO

## Classification

PLANNING-TODO — classify the root and every descendant. Classification
deterministically selects the fast-leaf or full-publication path.

## Current-state evidence

PLANNING-TODO — cite only enough pinned evidence to support classification and
the selected direction.

## Selected implementation direction

PLANNING-TODO — describe system-level HOW, not files, algorithms, prototypes,
or a detailed test harness.

<!--
For DECOMPOSE, EFFORT, or INCREMENTAL, add the full-path sections required by the contract:
Architecture decisions; Execution graph and waves; Interfaces and ownership;
Risks and rabbit holes; Migration, rollout, recovery, and rollback.
Do not add them to a fast leaf merely to make the document longer.

When ROOT must preserve a native dependency on an independently planned root,
add the optional `External prerequisite manifest` level-two section before the
issue publication manifest. Use columns `Key | Blocked row | Title | Required
state | Issue | Planning plan`; keys are `EXT###`, Blocked row is `ROOT`, and
Required state is `CLOSED`. Omit the entire section otherwise. External issues
are descriptors only and never become publication rows or children.

When this plan roots a former DEFERRED increment and must preserve its one
completed immediate predecessor from the exact approved outer INCREMENTAL plan,
add a separate `Inherited predecessor manifest` level-two section. Use columns
`Key | Blocked row | Title | Required state | Issue | Outer root | Outer
planning plan | Planning head`; use one `INH###` key, `ROOT`, `CLOSED`, and the
approved full lowercase outer-plan SHA. This edge must already exist and is
read-only. Do not use this descriptor for an ordinary self-rooted external
prerequisite or as an exception flag on `EXT###`.
-->

## Issue publication manifest

Replace or extend this table. Keys are stable within this plan. Use `Pending`
for unpublished issues during review. `Delivery` is `None` except on executable
GROUP increments and TRACKING roots. `Blocked by` contains comma-separated keys
or `None`.

| Key | Kind | Parent | Repository | Title | Delivery | Blocked by | Issue |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ROOT | LEAF | None | cedagova/synth | Synth: native macOS high-quality MusicXML player with per-line synth/instrument sound assignment | None | None | https://github.com/cedagova/synth/issues/1 |

## Acceptance coverage

PLANNING-TODO — map every root acceptance condition to one or more manifest
keys and call out gaps or overlaps.

## Validation and feedback

PLANNING-TODO

## Assumptions and open questions

PLANNING-TODO — state `None` when resolved. For each material owner decision,
record the same concise Owner decision brief shown to the owner: concrete
problem and impact; facts versus assumptions; two or three viable options with
behavior, benefit, risk or cost, reversibility, and execution impact;
recommended option and reason; blocked nodes or acceptance outcomes; and the
exact reply needed to continue.

## Satisfaction proof

PLANNING-TODO — for `ALREADY_SATISFIED`, include the three required disposition
lines and map every acceptance condition to pinned evidence and concrete
verification. Otherwise state that implementation work remains.

## Publication verification

PLANNING-TODO — record structural validation and native GitHub graph
verification. Exact-head approval remains in the native PR review, not here.

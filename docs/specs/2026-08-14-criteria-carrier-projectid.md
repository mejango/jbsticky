# Criteria travel in `split.projectId`, not `split.lockedUntil`

**Date:** 2026-08-14
**Status:** Approved design, pre-implementation
**Supersedes:** the `lockedUntil` channel described in `2026-08-12-sticky-distributor-design.md` and
referenced by `2026-08-13-criteria-window-generalization.md`. The encoding itself
(`minWeeks * 1000 + maxWeeks`), the window math, validation, and every claim-side rule are unchanged —
only the field the number arrives in changes.
**Lands on:** the open PR (`sticky-distributor`, mejango/jbsticky#1), before merge.

## Why

Two reasons, one of them a capability the current design cannot offer at all.

**Locked criteria splits become possible.** `lockedUntil` is the field core uses to make a split
immutable. Carrying criteria there forces a choice: a split can be genuinely time-locked or
criteria-carrying, never both. Moving criteria to `projectId` frees `lockedUntil` for its real job, and
`_isLockedSplitIncluded` (`JBSplits.sol:386`) already requires a replacement split to preserve
`projectId` alongside `percent`, `hook`, `beneficiary`, and `preferAddToBalance`. A locked criteria
split therefore freezes both its share and its window — a project can commit "10% of reserved issuance
to deposits aged 4 to 8 weeks, unchangeable for a year" as one immutable promise.

**The failure mode improves.** If a split's `hook` is ever cleared, the priority chain
(`hook > projectId > beneficiary`) resolves differently under each scheme:

- Criteria in `lockedUntil`: `projectId` is 0, so payouts fall through to `beneficiary` — the sticky
  token contract, which has no rescue path. Silent, permanent loss.
- Criteria in `projectId`: the pay-a-project branch runs. With no terminal for that token the
  distribution reverts loudly (`JBMultiTerminal_RecipientProjectTerminalNotFound`); with one, funds
  reach a live project, misrouted but recoverable in principle.

## Why the field is free

`split.projectId` is read only in the `else` branch after the hook check, on both distribution paths:
`JBMultiTerminal.sol:389` and `JBController.sol:1184`. When a split has a hook, neither path reads it.
`JBSplits._setSplitsOf` validates only percent rules and locked-split preservation — no existence check
— so any value stores intact. The field is `uint64` (`JBSplits.sol:326`), comfortably above the
`520520` ceiling.

Note the safety guarantee changes character. `lockedUntil` was safe *numerically* (values below 520521
are 1970-era timestamps core can never act on). `projectId` is safe *structurally* (hook priority means
the field is never read). Structural is the stronger of the two while a hook is set, since it holds for
any value rather than only small ones — and a hook being set is the premise of the split doing anything
for this system at all.

`projectId == 0` already means "no project", which aligns exactly with `groupId == 0` meaning the
everyone-pool. The default case needs no special handling.

## Changes

**Contract** (`src/JBStickyDistributor.sol`), one line of logic:

```
uint256 criteria = context.split.projectId;
uint256 groupId = _isValidGroup(criteria) ? criteria : 0;
```

Everything downstream is untouched. `_isValidGroup`, `_criteriaWindowFor`, `_windowTotalStake`,
`_windowStakeOf`, the encoding, and all validation stay exactly as they are.

**Natspec** on `processSplitWith` needs rewriting, not editing. The existing text argues from
`lockedUntil`'s inert timestamp range; the argument is now hook priority. The neighbouring "why not
`context.groupId`" clause stays correct and keeps its reasoning (a group-lookup key is fixed by the
distribution path and shared across a group's splits), but must no longer imply `projectId` is
unavailable.

**Tests.** Every split-path test moves the criteria value from `lockedUntil` to `projectId`, with
assertions unchanged. Two new cases:

1. **Locked criteria split** — the capability this change exists for. Configure a split with a real
   future `lockedUntil` AND criteria in `projectId`; confirm the criteria pot is funded (not the
   everyone-pool) and that core rejects a rewrite dropping or shortening the lock
   (`JBSplits_PreviousLockedSplitsNotIncluded`).
2. **Stale-carrier fallback** — a split carrying criteria in `lockedUntil` and nothing in `projectId`
   funds the everyone-pool without reverting, exactly like any other invalid value.

**Docs.** ADMINISTRATION's split recipe and encoding section name `projectId` as the carrier; the
"cannot be both locked and criteria-carrying" trade is removed and replaced with the locked-criteria
recipe. ARCHITECTURE's overload section is rewritten around hook priority rather than inert timestamps,
retaining the display caveat below. USER_JOURNEYS follows.

**Display caveat to document.** A tool that renders a split's destination without checking `hook` first
will show "pays project 4008" — plausible-looking wrong information, where the old scheme showed an
obviously-inert 1970 date. Such tools are already wrong today, since `hook` takes priority regardless.
`revnet.money`'s `splitRouting` resolves hook first and is correct; `juicebox.money`'s splits editor
already treats `projectId` as an optional rider on hook splits. Sweeping juicescan and juicy.vision is
a follow-up in those repos, not this PR.

## Production readiness (same pass)

`package.json` pins `@bananapus/core-v6` and `@bananapus/distributor-v6` as `file:` links to sibling
working trees, so an artifact build is not reproducible. Sibling packages in this monorepo pin npm
versions (`"@bananapus/core-v6": "^1.0.0"` in nana-buyback-hook-v6 and univ4-lp-split-hook-v6,
`^1.0.2` in defifa); both dependencies are published (core 1.2.0, distributor 1.0.0). Move to npm
version pins and verify the suite still builds and passes against the published code. If the published
versions lack something the local trees have, stop and report — publishing is a separate decision, not
something to work around by keeping the `file:` link.

## Out of scope

The encoding, window math, and claim rules (unchanged). Weighted curves. Absolute-epoch cohorts.
Webclient sweeps in other repos.

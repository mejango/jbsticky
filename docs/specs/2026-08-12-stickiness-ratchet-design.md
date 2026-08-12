# The Stickiness Ratchet — NAV entry + the stock exit curve (pure PvP)

Status: design chosen by jango 2026-08-12 ("remove the time aspect and simply
make it pvp"; stock curve kept — "exit-aggregators being ok"), pending final
spec review.
Visual companion: https://claude.ai/code/artifact/9662e86a-4635-4684-ae14-9a576ad661d4

## Goal

Fix the one defect in today's deployed sticky mechanism — par minting lets
newcomers skim accumulated backing — so that:

1. Every entrant, at any time, faces identical terms: instant round-trip
   `X(1−T)` (marginal size), entrant proportion `X/(σ+X)` of the pool.
2. Every unwind's toll aggregates to those who stay, so a stayer's value per
   staked token grows past 1 — driven purely by others exiting, never by time.
3. As long as no one exits, nothing moves.
4. `1 sticky = 1 staked` is intentionally broken; sticky tokens become NAV shares.

There is deliberately **no time component**. Stickiness is a war of attrition:
the bonus rate is the rate of others leaving first. The exit side keeps the
stock quadratic curve: bulk exits are partial dissolutions and are discounted
by design — exit-aggregators welcome.

## Definitions

- `σ` — surplus: staked tokens held by the project's terminal (no payouts or
  fund access exist, so surplus == balance).
- `S` — sticky share supply (18-dec project token).
- `ρ = σ/S` — backing per share. Starts at 1, monotonically non-decreasing.
- `T` — toll, out of `JBConstants.MAX_CASH_OUT_TAX_RATE` (10_000). The only
  per-project parameter.
- `dec` — staked token decimals.

## Mechanism

### Entry (NAV mint)

`beforePayRecordedWith` returns:

```
weight = S == 0 ? 1e18 : mulDiv(S, 10**dec, σ)
```

so `mint = X·S/σ` shares (terminal computes `amount·weight/10^dec`). `σ` and `S`
are read pre-record, so the entrant's share of the post-pay pool is exactly
`X/(σ+X)`. Entries leave `ρ` unchanged.

Bootstrap: `S == 0` mints 1:1 (18-dec normalized).

### Exit (the stock curve, untouched)

The exit side is today's deployed system, byte for byte. The toll `T` is the
eternal ruleset's `cashOutTaxRate` (already the deploy param);
`beforeCashOutRecordedWith` passes everything through unchanged (already does);
`JBCashOuts.cashOutFrom` prices the reclaim:

```
reclaim = shares·ρ · ((MAX − T) + T·shares/S) / MAX
```

A lone (marginal) defector pays the full toll; a whole-pool exit reclaims
everything (the `count >= supply` branch, line 42 — dissolution is the curve's
endpoint, not a special case); everything between is a **partial dissolution,
discounted in proportion** — batched exits, exit-aggregators, and buy-outs are
welcome by design (jango: the toll prices unilateral defection; cooperation is
not defection).

**Fee policy (jango, 2026-08-12)**: a sticky using a stickiness bonus keeps the
standard protocol fee — stock behavior: the terminal charges 2.5% on the full
reclaim whenever the effective tax rate is non-zero, dissolution included.
`T = 0` wrappers are fee-free (`feeFreeSurplusOf` is always 0 for sticky
projects — no payouts occur).

**Deployer note**: `T == MAX` makes every reclaim 0 (`JBCashOuts.cashOutFrom`
early-returns before the full-supply branch, line 39) — a permanent one-way
vault. Keep the existing `≤ MAX` validation but document that `MAX` bricks
even dissolution.

Tranches, LIFO consumption, and transfer restamping are untouched — they remain
streak accounting for votes and distributor rewards, with no role in the money
path.

### Ratchet dynamics

Taxed exits reclaim less than pro-rata while burning full shares, so `ρ` steps
up on every taxed exit and is never reduced. Closed forms for the
many-small-exits regime (each marginal exit pays the full toll — the regime
where stayers gain most; batched exits are partial dissolutions and leave less
behind):

```
ρ(F)  = (1−F)^−T                    F = cumulative churn since a holder's entry
net   = ρ(1−T)(1−f)                 f = 2.5% protocol fee (T > 0), marginal exit
F*    = 1 − ((1−T)(1−f))^(1/T)      break-even churn (marginal exits)
```

`F*` ≈ 70–90% depending on `T`. The fee also floors sensible tolls: stayers
gain at most `T` per exit while the protocol always takes `f`, so `T` should
sit well above 2.5% (as `T → f`, `F* → 1`). **Patience alone never makes a
holder whole — only others' defection does.** Confirmed by design: the game
rewards outlasting, not waiting. Corollaries: memoryless (every entrant faces
the identical forward game) and timing-sniper-proof (entering right before an
exodus buys nothing — NAV in, same toll out).

## Invariants (test targets)

1. **Uniform entrant terms**: pay `X` then immediately unwind all minted shares
   → reclaim `X·((1−T) + T·m/S')` gross (the curve at the entrant's own size),
   `= X(1−T)` for marginal size, independent of prior pool history — NAV entry
   removes history from the price; the curve grades only by size, as on any
   stock project. Sole entrant reclaims `X` gross (dissolution endpoint).
2. **Entrant proportion**: after paying `X`, `mint/(S+mint) == X/(σ+X)`.
3. **Monotone ρ**: no sequence of pays/unwinds/transfers decreases `σ·1e18/S`.
4. **Fee policy**: every `T > 0` cashout emits the standard 2.5% protocol fee
   on the full reclaim; `T = 0` cashouts never emit one. (Stock behavior —
   asserts the ratchet didn't disturb it.)
5. **Dissolution completeness**: a full-supply unwind reclaims exactly `σ` —
   the terminal holds zero after. (The curve's endpoint; stock behavior.)
6. **Curve convexity**: splitting an exit into pieces pays MORE total toll than
   one batched exit — the bulk discount exists and is monotone in size. (Stock
   behavior, kept by choice.)
7. **Time invariance**: warping time between entry and exit changes nothing in
   the money path (streaks change; reclaim does not).

## Contract changes

| Where | Change |
|---|---|
| `JBStickyHook.beforePayRecordedWith` | return NAV weight instead of `context.weight` — **the one change** |
| `JBStickyHook.beforeCashOutRecordedWith` | **unchanged** — stock curve passes through |
| `JBStickyDeployer.deployStickyFor` | **unchanged** — `cashOutTaxRate` is already the toll param |
| `JBStickyHook` | new views `backingOf(projectId)`, `unwindPreviewOf(projectId, count)` |
| Tranche/streak machinery | untouched |
| Core protocol | none |

Notes:

- `beforePayRecordedWith` context lacks surplus/supply; the hook reads
  `terminal.STORE().balanceOf(terminal, projectId, stakedToken)` and
  `TOKENS.totalSupplyOf(projectId)` (both pre-record). It stays `view`; all
  state writes remain in the after-hooks, as today.
- Decimals: shares are 18-dec, `σ` is `dec`-dec. `weight = mulDiv(S, 10**dec, σ)`
  keeps the terminal's `amount·weight/10^dec` correct for any `dec`.
- Update the deployer/hook natspec that says nonzero tax makes unwinds
  non-1:1 — with NAV entry the whole system is NAV-denominated.

## Deliberate positions

- **Coordinated exits are cheap on purpose.** Aggregators, buy-outs, group
  wind-downs all grade smoothly toward free dissolution on the curve. The toll
  prices unilateral defection; cooperation is not defection.
- **Bootstrap windfall accepted.** Exits never strand residue, so `S=0, σ>0`
  arises only from donations into an empty pool; the next entrant mints 1:1 and
  captures it. Rare, bounded, zero code.
- **Rounding favors stayers.** Mints round down, reclaims round down; all dust
  accrues to ρ and the dissolution sweep takes even the dust.

## Option: quadratic stickiness reward distribution (√duration)

Status: deploy-time option on the PvP core; on/off/split decision open.

The PvP core is identical in both modes (stock exit curve, dissolution
endpoint, standard fee policy). The option changes where the curve's withheld
toll goes. Default mode: it melts into per-share backing, pro-rata and
age-blind (NAV entry, as specced above). Option mode: it accrues to an explicit
bonus pool `B`, paid out by the distributor per epoch, claimed by

```
weight = shares · √( min(held, U) / U )
```

where `U` is the option's tuning horizon — the hold time that earns full
weight 1, per project. Below `U`, hold-time ratios follow the √ rule (held 4×
as long → 2× the weight; 16d vs 4d → 2:1). At `U`, weight tops out: veterans
past the horizon are equals, so the patience race has a finish line and a
newcomer reaches exact fair share once they've held for `U`.

**Why the cap is the knob**: claims are normalized (`w/W`), and an uncapped
`√(held/unit)` scales every holder by the same constant — a pure unit is
cosmetic (16d:4d is 2:1 in any unit). The horizon breaks that scale-invariance
and is the only real dial: 1 week ≈ a sprint that quickly flattens to pro-rata;
1 year keeps early stakers ahead for a long season. It also bounds
ancient-tranche dominance.

Time never creates value in either mode — `B` only grows on exits — under the
option it divides what defectors left behind. Exits price via the stock curve
as always (protocol fee as usual); what the curve withholds accrues to `B`
instead of pro-rata backing; dissolution takes principal + `B` in full.

- **1 sticky = 1 staked holds in this mode**: age-0 weight is 0, so entrants
  can't touch `B` regardless of mint price — NAV entry is unnecessary;
  principal stays 1:1 and the bonus rides on top. Entrant terms stay uniform
  (`X(1−T)`).
- **Stronger sniper resistance** than pro-rata (enter-before-exodus captures ~0
  of `B`); **weaker memorylessness** (entrants inherit the pool's bonus
  landscape); "nothing moves without exits" softens to "no *value* moves" —
  relative claims on a static `B` drift with time.
- **Implementation fork**: the leaver's own weight is cheap (own tranches,
  already timestamped). The global total `W` is not: `Σ s·√(min(held,U)/U)`
  does not decompose into on-chain accumulators (uncapped integer exponents
  would, via power sums, but neither √ nor the cap does) — so the option lives
  in the distributor layer (per-epoch snapshots, where streak rewards already
  live). Exit hook keeps principal + toll identically in both modes; the
  distributor pays `B` by capped-√duration weight per epoch.
- **Guard**: while total weight is 0, claims wait. A toll *split* (part
  pro-rata, part to `B`) is the one-parameter generalization between modes.
- **Fan-out model** (artifact Fig 2): with average-weight leavers, the option
  leaves aggregate flows identical to pro-rata — the pro-rata round-trip is the
  option's *average*. Individual round-trips spread around it by relative
  weight `w/w̄ = √(tenure ratio)`: `reclaim/stake = (1 + (w/w̄)(ρ−1))(1−T)`,
  so a fresh entrant sits at `1−T` and a 4×-tenure holder (weight 2×) breaks
  even at roughly two-thirds the churn pro-rata needs.

## Webclient / downstream

- `weight` is no longer constant 1e18 — anything deriving mint previews from
  the ruleset weight must call the hook path (`previewPayFor`-style) or the new
  views.
- Sticky balances are shares, not staked-token amounts; UI shows
  `balance × backingOf()` for value and `unwindPreviewOf` for exit quotes
  (`quote = count·ρ·(1−T)`, or full σ on dissolution).
- Votes (soulbound token) are share-denominated: proportional at entry, frozen
  thereafter.

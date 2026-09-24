# Style Guide

Sticky follows the [Juicebox V6 style guide](https://github.com/Bananapus/nana-core-v6/blob/feff600654aee6fb1747dded692f18068b2230a6/STYLE_GUIDE.md). The workspace's `nana-core-v6` is the canonical source for Solidity layout, named arguments, complete NatSpec, comments, formatting, and repository conventions.

Use the same language in source, documentation, and the client: deposits issue **Sticky shares**, **backing** belongs to those shares after excluding orphaned funds, a **tranche** records the age of a deposit, and a **streak** records uninterrupted positive ownership. State the cash out curve, fee treatment, and rounding limits when describing redemption. A tranche's age and a holder's streak are distinct from the distributor's balance snapshot.

Describe current behavior in source comments. Keep historical findings and validation results in review reports. Link to the document that owns a topic instead of copying its full instructions.

For Foundry v1.8.1, a justified `forge-lint: disable-next-line` applies to single-line checks. Multiline expressions and modifiers require the narrowly scoped `forge-lint: disable-next-item` directive because the line directive does not cover their full source span. Keep either directive on its own line immediately before the affected item, with the justification in a separate prose comment.

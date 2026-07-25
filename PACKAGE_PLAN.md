# paper_ex_polymarket Package Plan

Status: optional future adapter package.

Purpose: connect `paper_ex` to the `polymarket` SDK.

This package should only be built once `paper_ex` and `polymarket` have stable enough
surfaces to connect cleanly.

## Responsibilities

- Implement `PaperEx.Adapter` for Polymarket.
- Fetch order books through `polymarket`.
- Convert Polymarket books to `PaperEx.MarketSnapshot`.
- Resolve YES/NO token IDs from Polymarket market metadata.
- Provide prediction-market P&L defaults.
- Provide Polymarket fee model helpers.
- Simulate common Polymarket order styles:
  - FOK book walk
  - FAK partial fill
  - passive GTC pending/fill/cancel lifecycle
- Provide examples for using `paper_ex` with Polymarket.

## Non-Responsibilities

- Generic paper trading engine internals.
- Low-level CLOB signing.
- Bot strategy decisions.
- Bot persistence, scheduling, dashboard, or Telegram.

## Open Questions

- Should this be a separate Hex package or examples inside `paper_ex` / `polymarket` first?
- How much Polymarket execution policy belongs here versus in the bot?
- Should passive GTC lifecycle helpers be generic enough to move down into `paper_ex`?


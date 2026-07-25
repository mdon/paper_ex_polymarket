# paper_ex_polymarket — Polymarket Adapter For paper_ex

This is a later package, not an immediate implementation target.

Build it only after `paper_ex` and `polymarket` have stable enough APIs to connect
cleanly.

## Role

Adapter package connecting generic `paper_ex` to Polymarket market data and resolution
semantics.

## Responsibilities

- Implement `PaperEx.Adapter` for Polymarket.
- Fetch order books through `polymarket`.
- Convert Polymarket order books to `PaperEx.MarketSnapshot`.
- Resolve YES/NO token IDs from market metadata.
- Provide prediction-market P&L defaults.
- Provide Polymarket fee model helpers.
- Provide examples for using `paper_ex` with Polymarket.

## Non-Responsibilities

- Generic paper trading internals.
- Low-level CLOB signing.
- Bot strategy decisions.
- Bot persistence, scheduling, dashboard, Telegram, or guardrails.

## Extraction Rule

Start as examples or app-local adapter code if necessary. Promote to a Hex package only
when the adapter surface is stable and clearly useful outside the bot.


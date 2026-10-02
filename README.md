# PaperExPolymarket

Adapter between `paper_ex` (generic paper trading) and `polymarket_sdk`
(the Polymarket SDK). Translates Polymarket CLOB order books, market
metadata, and trade activity into the normalized `paper_ex` domain
so callers can simulate **or** live-mirror Polymarket trading with
the generic paper engine.

This package is:

- An **adapter / translation layer**, not a trading bot.
- The **only** package that bridges `paper_ex` and `polymarket_sdk`.
- Free of strategy decisions, dashboards, persistence, scheduling,
  Telegram, and live trading.

## How the packages relate

```
paper_ex                     # generic engine, no Polymarket dep
   ^
   | PaperEx.Adapter behaviour
   |
paper_ex_polymarket          # this package — adapter
   |
   v uses polymarket_sdk shapes (CLOB books, Gamma, Data, RTDS)
polymarket_sdk               # Polymarket SDK: CLOB, Gamma, Data, RTDS, CTF
```

A consumer wires up:

1. `polymarket_sdk` for the live API surface they care about (often
   just order-book fetches, plus Gamma discovery and Data-API account
   data).
2. `paper_ex_polymarket` to translate (1) into the structs `paper_ex`
   understands.
3. `paper_ex` to simulate orders, hold portfolio state, and record
   execution attempts.

## Status — 0.3.0

Implemented:

- `PaperExPolymarket.Adapter` — implements every `PaperEx.Adapter`
  callback (required and optional).
- `PaperExPolymarket.Market` — token id ↔ `PaperEx.Instrument`.
- `PaperExPolymarket.OrderBook` — CLOB `/book` body ↔ `PaperEx.MarketSnapshot`.
- `PaperExPolymarket.Execution` — Polymarket-flavored fill simulator
  (FAK for market orders, GTC for limit orders), with budget-walking
  semantics for `:market :amount` and strict numeric/timestamp
  parsing.
- `PaperExPolymarket.ActivityMapper` — Data-API / RTDS trade event ↔ `PaperEx.Fill`.
- `PaperExPolymarket.Fees` — the CLOB v2 taker fee (`:fee_rate`, by market
  category via `rate_for/1`) or a flat `:fee_bps`; zero by default.
- `PaperExPolymarket.LiveMirror` — live-mirror flows:
  `simulate_intent/4`, `mirror_actual_fill/4`, `record_pending/3`,
  `resolve_pending/4` (`:filled` / `:cancelled`).
- `PaperExPolymarket.Snapshot` — convenience that composes
  instrument resolution + book normalization, with an injectable
  fetcher (`from_clob_book/3`, `fetch_order_book_snapshot/3`).
- Hand-authored fixture set under `test/fixtures/` plus
  `PaperExPolymarket.Fixtures` loader used by fixture-backed
  integration tests.
- Wiring for `PaperEx.Engine`'s opt-in `:pending_remainder` policy
  on partial `:limit` fills.
- **148 tests** total covering CLOB-book conversion against realistic
  multi-level payloads, market normalization, activity-event mapping,
  fill simulation across every combination of `:market` / `:limit` /
  `:buy` / `:sell` / partial / missed / limit-not-crossed paths,
  end-to-end `PaperEx.Engine.apply_order/4` through the adapter, the
  full live-mirror pending → filled / cancelled lifecycle,
  pending-remainder integration through the adapter, amount-based
  short guard through the adapter, the `Snapshot` convenience layer
  (function + MFA fetchers, error pass-through, malformed inputs),
  and bounded reason-code mapping for malformed payloads.

Not implemented (deferred to future versions):

- A built-in price-history loader. Callers pass snapshots in.
- Auto-fetching CLOB market metadata via `polymarket_sdk`. Callers
  pass metadata in.
- Polymarket FAK partial-remainder lifecycle (`:pending` for the
  unfilled remainder of a market order).

## Quick start — research-mode simulation

```elixir
alias PaperEx.{Engine, Order, Portfolio}
alias PaperExPolymarket.Adapter

# 1. Resolve a Polymarket instrument from a CLOB market payload.
clob_market = %{
  "condition_id" => "0xabc",
  "question" => "Will X happen by Y?",
  "market_slug" => "x-y",
  "minimum_tick_size" => "0.01",
  "token_id" => "111",
  "tokens" => [
    %{"token_id" => "111", "outcome" => "Yes"},
    %{"token_id" => "222", "outcome" => "No"}
  ]
}

{:ok, instrument} = Adapter.normalize_instrument(clob_market)

# 2. Get a CLOB /book body (the shape polymarket_sdk's order-book
#    endpoint returns) and turn it into a normalized snapshot.
clob_book = %{
  "market" => "0xabc",
  "asset_id" => "111",
  "bids" => [%{"price" => "0.53", "size" => "100"}],
  "asks" => [%{"price" => "0.55", "size" => "100"}]
}

{:ok, snapshot} = Adapter.normalize_snapshot(clob_book, instrument)

# 3. Apply an order through the generic engine.
portfolio = Portfolio.new(starting_balance: 1_000.0)

order =
  Order.new(
    market_id: "111",
    side: :buy,
    order_type: :market,
    size: 10,
    id: "order-1"
  )

{portfolio, execution} =
  Engine.apply_order(portfolio, order, snapshot, adapter: Adapter)

execution.status        # => :filled
execution.fill_price    # => 0.55
hd(portfolio.positions) # => %PaperEx.Position{shares: 10, side: :buy, ...}
```

## Live-mirror flows

`PaperExPolymarket.LiveMirror` exposes four functions covering the
operationally interesting cases. Each preserves the **execution
attempt ledger** so misses, skips, and pending lifecycle events are
first-class — not absorbed into "no trade".

### Mirror an intent against the current book

```elixir
alias PaperExPolymarket.LiveMirror

{portfolio, ex} = LiveMirror.simulate_intent(portfolio, order, snapshot)
ex.metadata.mode  # => :live_mirror
```

### Record an actual exchange fill on the mirror

```elixir
trade_event = %{
  "asset" => "111",
  "side" => "BUY",
  "size" => "5",
  "price" => "0.55",
  "transactionHash" => "0xdead"
}

{portfolio, ex} =
  LiveMirror.mirror_actual_fill(portfolio, order, trade_event, instrument)

ex.status              # => :filled
ex.metadata.source     # => :actual_fill
ex.metadata.raw_event  # => trade_event
```

### Track a resting GTC order across its lifecycle

```elixir
# Step 1 — place an order (e.g., via polymarket_sdk) and immediately
#          record a :pending execution on the mirror.
{portfolio, pending} =
  LiveMirror.record_pending(portfolio, order, id: "pend-1")

# Step 2a — when an actual fill arrives, resolve the pending into a
#           :filled and update portfolio cash/positions.
{portfolio, filled} =
  LiveMirror.resolve_pending(portfolio, "pend-1", :filled,
    order: order,
    instrument: instrument,
    trade_event: trade_event
  )

# Step 2b — or, if the order is cancelled, resolve it into a
#           :cancelled execution. State otherwise unchanged.
{portfolio, cancelled} =
  LiveMirror.resolve_pending(portfolio, "pend-1", :cancelled,
    reason: :cancelled_by_exchange
  )
```

Both lifecycle paths preserve the original `:pending` ledger entry
plus the new `:filled` or `:cancelled` entry — so a downstream
analyst can reconstruct the whole story from the
`Portfolio.executions` field alone.

## Non-goals

- Not a bot. No Phoenix, no Ecto, no Oban, no Telegram, no LiveView.
- Not a strategy framework. No copy-trading, no surge logic, no BTC
  arb, no stink-bid stencils.
- Not a substitute for `polymarket_sdk`. Live signing, balance
  checks, and order placement stay in `polymarket_sdk`.
- Not a market-data fetcher. Callers pass snapshots and metadata in;
  this package never opens a socket.

## Hex publishability

Until `paper_ex` and `polymarket_sdk` are published on Hex, this
package declares path deps and `mix hex.build` will fail with an
explanatory error. That is intentional. (Set `HEX_BUILD=1` to switch
the workspace path deps to Hex requirements once both are published.)

## License

MIT.

# Changelog

## 0.4.0 - 2026-10-01

### Added

- **The CLOB v2 taker fee, modelled.** `PaperExPolymarket.Fees.fee/2` accepts
  `:fee_rate` and charges `shares × rate × price × (1 - price)` — the
  protocol's match-time, category-based fee curve. `maker: true` charges
  nothing (makers pay 0 in v2). `Fees.rate_for/1` returns the taker rate for
  a market category (`:crypto` 0.07, `:sports` 0.05,
  `:finance`/`:politics`/`:mentions`/`:tech` 0.04,
  `:economics`/`:culture`/`:weather`/`:other` 0.05, `:geopolitics`/`:world`
  0.0); an unknown category gets the "other" rate rather than zero.
  A mid-priced crypto taker pays about 3.5% of notional, which is more than
  most thin paper edges — P&L computed at zero fee is optimistic.

### Changed

- The `Fees` moduledoc no longer says v2 charges no trade-time fees. v2
  removed `feeRateBps` from the signed order; it did not remove fees.

Nothing changes for existing callers: with neither `:fee_rate` nor `:fee_bps`
the fee is still zero, and `:fee_bps` behaves as before.

## 0.3.2 - 2026-07-25

### Fixed

- **Live CLOB book timestamps in milliseconds.** `OrderBook.from_clob_book/2`
  treated a string `"timestamp"` as Unix **seconds**, but the live
  `/book` endpoint sends **milliseconds** as a string (e.g.
  `"1781577793787"`) — `DateTime.from_unix!/1` then raised
  `invalid Unix time` and crashed the consuming snapshotter (and, in
  the reference bot, the whole app on boot). The string path now
  applies the same ms-vs-seconds heuristic as the integer path, and a
  malformed timestamp falls back to `DateTime.utc_now/0` instead of
  raising. Surfaced by a real paper-trading run; 2 regression tests.

## 0.3.1 (unreleased)

### Added

- Integration test for `PaperEx.Engine.advance_pending/3` flowing
  through `PaperExPolymarket.Adapter`: a limit pending created by
  the adapter is resolved by a fresh snapshot end-to-end, and a
  non-crossing fresh snapshot leaves the pending in place with no
  ledger churn.
- No adapter code change — `advance_pending/3` is generic in the
  engine and consumes the adapter's existing `simulate_fill/3`.

## 0.3.0 (unreleased)

### Added

- `PaperExPolymarket.Snapshot` — convenience module closing the
  loop from a Polymarket CLOB `/book` response to a
  `PaperEx.MarketSnapshot`:
  - `from_clob_book/3` — normalize an already-fetched body for a
    token id, `{:token_id, …}` tuple, or pre-resolved
    `PaperEx.Instrument`.
  - `fetch_order_book_snapshot/3` — same, with an **injected**
    fetcher (1-arity function or `{module, function, args}` tuple).
    The package never owns network IO; fetchers are caller-supplied.
- 18 new tests covering: fixture-backed conversion, token-id /
  tuple / instrument refs, malformed inputs returning bounded
  reason codes (`:polymarket_invalid_market_payload`,
  `:polymarket_invalid_book`), function and MFA fetcher success
  paths, error pass-through, instrument_opts forwarding.

### Notes

- This module exists in `paper_ex_polymarket` rather than
  `polymarket` to preserve the dependency direction: `polymarket`
  stays upstream of paper packages. Any helper returning
  `PaperEx.MarketSnapshot` belongs here or in `polymarket_bot`.

## 0.2.0 (unreleased)

### Added

- Hand-authored CLOB/Data-API fixture set under
  `test/fixtures/` (`clob_market.json`, `clob_book.json`,
  `data_api_trade.json`) modeling realistic Polymarket payload
  shapes from the v1 bot's observed responses. See
  `test/fixtures/README.md` for the shape rationale.
- `PaperExPolymarket.Fixtures` — test-support helper for loading
  the fixture set (not compiled into the library).
- 28 new fixture-backed integration tests exercising
  `Market.from_clob_market/2`, `OrderBook.from_clob_book/2`,
  `Adapter.normalize_instrument/1`,
  `Adapter.normalize_snapshot/2`,
  `Adapter.normalize_fill/2`, and `Execution.simulate_fill/3`
  against the realistic payload shapes. Covers happy paths,
  malformed payloads (non-map instrument, missing book keys,
  partial-parse prices, partial-parse timestamps, zero-size
  levels) and the bounded-reason-code contract.
- 6 new pending-integration tests verifying that the
  `:pending_remainder` policy added to `PaperEx.Engine` flows
  cleanly through the Polymarket adapter, that market FAK partials
  never record `:pending`, and that
  `Engine.cancel_pending/3` and
  `LiveMirror.record_pending/3` coexist without colliding.

### Notes

- No code change to `PaperExPolymarket.Adapter` was required: the
  pending-remainder policy is implemented generically in
  `PaperEx.Engine` and the adapter's `simulate_fill/3` already
  returns the `{:ok, :partial, fills}` shape the engine consumes.

## 0.1.0 (unreleased)

Initial scaffold of the Polymarket adapter for `paper_ex`.

### Added

- `PaperExPolymarket` top-level module with `version/0` and moduledoc
  explaining the adapter package role and non-goals.
- `PaperExPolymarket.Market` — token id ↔ `PaperEx.Instrument`
  conversion, including outcome label/index lookup against CLOB
  `"tokens"` lists and tick-size parsing.
- `PaperExPolymarket.OrderBook` — CLOB `/book` body ↔
  `PaperEx.MarketSnapshot`. Parses string-encoded prices/sizes,
  filters zero-size levels, surfaces malformed payloads as
  `:invalid_book`.
- `PaperExPolymarket.ActivityMapper` — Data-API and RTDS trade event ↔
  `PaperEx.Fill`. Enforces instrument id match, parses second-/ms-
  precision timestamps, surfaces maker/taker liquidity hints.
- `PaperExPolymarket.Execution` — Polymarket-flavored fill simulator
  (`:market` orders modeled as FAK, `:limit` modeled as GTC).
  Walks the book, produces `:filled` / `:partial` /
  `:missed` outcomes with bounded reason codes
  (`:no_liquidity`, `:limit_not_crossed`).
- `PaperExPolymarket.Fees` — bps-based fee helper for take-fee
  modeling via `adapter_opts: [fee_bps: <bps>]`. Defaults to zero.
- `PaperExPolymarket.Adapter` — implements every `PaperEx.Adapter`
  callback. Returns bounded Polymarket-tagged reason atoms
  (`:polymarket_invalid_market_payload`, `:polymarket_invalid_book`,
  `:polymarket_invalid_trade_payload`,
  `:polymarket_instrument_mismatch`) on top of the generic engine
  codes from `PaperEx.ReasonCodes.engine_codes/0`.
- `PaperExPolymarket.LiveMirror` — live-mirror lifecycle helpers:
  - `simulate_intent/4` — engine apply with `:mode = :live_mirror`.
  - `mirror_actual_fill/4` — record an observed exchange trade as a
    `:filled` execution.
  - `record_pending/3` — record a resting `:pending` execution.
  - `resolve_pending/4` — move a pending into `:filled` or
    `:cancelled`, preserving both ledger entries.
- 71 tests covering: CLOB market normalization, CLOB book parsing
  (happy + malformed + zero-size), activity-event mapping (BUY /
  SELL / liquidity / ms timestamps / instrument mismatch / zero
  size / non-numeric), fill simulation across `:market` / `:limit`
  / `:buy` / `:sell` / partial / missed / limit-not-crossed paths,
  adapter behaviour conformance, end-to-end
  `PaperEx.Engine.apply_order/4` through the adapter, fee
  application via `adapter_opts`, full live-mirror pending →
  filled / cancelled lifecycle, and live-mirror ledger preservation
  for misses and skips that never produced a position.

### Deferred

- Auto-fetching CLOB market metadata via `polymarket_clob`. Callers
  pass metadata in.
- Polymarket FAK partial-remainder lifecycle (`:pending` execution
  for the unfilled remainder of a market order).
- A built-in price-history loader.

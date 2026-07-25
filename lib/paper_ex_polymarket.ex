defmodule PaperExPolymarket do
  @moduledoc """
  Adapter between `PaperEx` (the generic paper-trading engine) and
  Polymarket, via the `polymarket_sdk` package.

  This package is a **translation layer**: it glues the venue-agnostic
  `paper_ex` engine to Polymarket's CLOB books, market metadata, and
  trade activity so callers can simulate — or live-mirror — Polymarket
  trading with the generic engine.

  ## Modules

    * `PaperExPolymarket.Adapter` — the `PaperEx.Adapter` behaviour
      implementation the engine drives; delegates to the modules below.
    * `PaperExPolymarket.Market` — Polymarket market metadata / token id
      into `PaperEx.Instrument`.
    * `PaperExPolymarket.OrderBook` — a CLOB `/book` body into a
      `PaperEx.MarketSnapshot`.
    * `PaperExPolymarket.Execution` — Polymarket-flavored fill simulator
      (FAK for market orders, GTC for limit orders) over a snapshot.
    * `PaperExPolymarket.ActivityMapper` — a Data-API / RTDS trade event
      into a `PaperEx.Fill` for live-mirror reconciliation.
    * `PaperExPolymarket.Fees` — a bps-based fee helper.
    * `PaperExPolymarket.Snapshot` — convenience composer (instrument
      resolution + book normalization) with an injectable fetcher.
    * `PaperExPolymarket.LiveMirror` — live-mirror flows built on
      `PaperEx.Engine`.

  It is **not** a trading bot: no Phoenix, no Ecto, no Oban, no
  Telegram, no LiveView, no strategy logic, no live order placement.
  Live signing and order submission stay in the Polymarket SDK / CLOB
  layer.

  ## Money convention

  Prices, sizes, and fees are plain floats throughout (no `Decimal`,
  no tick/lot rounding), matching the `paper_ex` `Fill` /
  `MarketSnapshot` structs. See the package `README.md` for the
  bigger-picture relationship diagram and non-goals.
  """

  @doc """
  Returns the package version, derived from the loaded application's
  `:vsn`.
  """
  @spec version() :: String.t()
  def version, do: Application.spec(:paper_ex_polymarket, :vsn) |> to_string()
end

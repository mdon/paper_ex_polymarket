defmodule PaperExPolymarket.Fees do
  @moduledoc """
  Polymarket fee helpers for paper trading — modelling the **CLOB v2** taker fee.

  ## What changed with the new API (CLOB v2 / CTF Exchange v2)

  The fee model *moved*; it did not disappear. In the **old** CLOB each signed
  order carried a `feeRateBps` field — a flat basis-points rate the client
  fetched per token from the legacy `/fee-rate` endpoint (still present as
  `PolymarketClob.API.MarketData.get_fee_rate/2`, labelled "legacy") and embedded
  in the on-chain order. **CLOB v2 removed `feeRateBps` from the order entirely**
  — the v2 order the client signs has no fee field at all (verified against the
  `py-clob-client-v2` parity fixtures: salt / maker / signer / tokenId /
  makerAmount / takerAmount / side / signatureType / timestamp / metadata /
  builder / expiration — no fee). Instead, fees are **set by the protocol and
  applied at match time**, on a category-based price curve:

      fee = shares × feeRate × price × (1 - price)     (in USDC, taker only)

  So "no `feeRateBps` in the order" does **not** mean "no fees" — a common
  misread. v2 charges match-time protocol fees; they are simply not
  client-specified. Makers pay **0** and instead receive a daily rebate (15–25%
  of collected taker fees).

  The `price × (1 - price)` term peaks at `price = 0.5` (0.25) and vanishes at
  the extremes. Verified against Polymarket's published max-fee-per-100-shares
  table at p = 0.5: crypto `100 × 0.07 × 0.25 = $1.75`, sports `$1.25`,
  finance/politics `$1.00`.

  ## Category taker rates

      crypto                                     0.07
      sports                                     0.05
      finance / politics / mentions / tech       0.04
      economics / culture / weather / other      0.05
      geopolitics (world events)                 0.00  (fee-free)

  Unknown categories default to the **"other" catch-all rate (0.05)** — Polymarket
  files uncategorised markets under "Other", and for research it is safer to
  slightly over-state fees than to silently assume zero.

  ## Why it matters (research)

  A **taker** buying mid-priced crypto pays ~1.75¢/share ≈ **3.5% of notional** —
  larger than most thin paper "edges", so paper P&L computed at zero fee is
  systematically optimistic. Model it by passing `:fee_rate` (from `rate_for/1`)
  and optionally `:maker` in `:adapter_opts`. The adapter is offline: it applies
  the caller's stated fee assumption deterministically rather than fetching live
  market fee metadata.

  Modes, chosen by opts (checked in order):

    * `:fee_rate` — the CLOB v2 price-curved taker fee above; `maker: true` → 0.
    * `:fee_bps` — a flat basis-points fee (`size × price × bps`), kept for
      backward compatibility / worst-case modelling.
    * neither → **zero** (the previous default; existing callers unchanged).
  """

  alias PaperEx.Fill

  # CLOB v2 taker fee rates by market category. Makers always pay 0.
  @fee_rates %{
    crypto: 0.07,
    sports: 0.05,
    finance: 0.04,
    politics: 0.04,
    mentions: 0.04,
    tech: 0.04,
    economics: 0.05,
    culture: 0.05,
    weather: 0.05,
    other: 0.05,
    geopolitics: 0.0,
    world: 0.0
  }

  @other_rate 0.05

  @doc """
  CLOB v2 taker fee rate for a market `category` atom. Unknown categories fall
  back to the "other" catch-all rate (#{@other_rate}), not zero.
  """
  @spec rate_for(atom()) :: float()
  def rate_for(category) when is_atom(category), do: Map.get(@fee_rates, category, @other_rate)

  @doc """
  Fee in quote currency (USDC) for a `Fill`, from an opts keyword.

    * `:fee_rate` present → `shares × rate × price × (1 - price)` (CLOB v2 taker
      fee); `maker: true` → `0.0`.
    * else `:fee_bps` → flat `size × price × bps / 10_000`.
    * else → `0.0`.

  Raises `ArgumentError` on a negative/non-numeric `:fee_rate` or `:fee_bps` — a
  negative fee would silently *improve* PnL (the engine applies the fee via a
  struct update that bypasses `Fill`'s non-negative validation).
  """
  @spec fee(Fill.t(), keyword()) :: number()
  def fee(%Fill{} = fill, opts) do
    case Keyword.fetch(opts, :fee_rate) do
      {:ok, rate} ->
        if Keyword.get(opts, :maker, false) do
          0.0
        else
          r = validate_nonneg!(:fee_rate, rate)
          fill.size * r * fill.price * (1.0 - fill.price)
        end

      :error ->
        bps = validate_nonneg!(:fee_bps, Keyword.get(opts, :fee_bps, 0))
        fill.size * fill.price * bps / 10_000
    end
  end

  defp validate_nonneg!(_key, n) when is_number(n) and n >= 0, do: n

  defp validate_nonneg!(key, other) do
    raise ArgumentError, "#{inspect(key)} must be a non-negative number, got: #{inspect(other)}"
  end
end

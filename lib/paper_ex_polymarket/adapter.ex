defmodule PaperExPolymarket.Adapter do
  @moduledoc """
  `PaperEx.Adapter` implementation for Polymarket.

  This is the entry point the generic `PaperEx.Engine` uses when
  configured with `adapter: PaperExPolymarket.Adapter`. The adapter
  delegates to four sibling modules:

    * `PaperExPolymarket.Market` — `normalize_instrument/1` reads a
      CLOB market metadata payload (`%{"token_id" => …, "market" =>
      …, "tokens" => …}`) and produces a `PaperEx.Instrument`.
      A simpler `{:token_id, "…"}` tuple is also accepted for tests.
    * `PaperExPolymarket.OrderBook` — `normalize_snapshot/2` reads a
      CLOB `/book` body and an `Instrument`, producing a normalized
      `PaperEx.MarketSnapshot`.
    * `PaperExPolymarket.ActivityMapper` — `normalize_fill/2` reads a
      Data-API or RTDS trade event and produces a `PaperEx.Fill` for
      live-mirror reconciliation.
    * `PaperExPolymarket.Execution` — `simulate_fill/3` walks the
      snapshot per Polymarket's FAK (market) / GTC (limit) defaults.

  Fees default to zero. Pass `fee_bps: <bps>` in `:adapter_opts` to
  apply a take-fee for stress-testing.

  ## Bounded reason codes

  The adapter declares its bounded reason set in `reason_codes/0`.
  In addition to the generic engine codes from
  `PaperEx.ReasonCodes.engine_codes/0`, Polymarket-specific codes
  include `:polymarket_invalid_market_payload` (market payload was
  malformed), `:polymarket_invalid_book` (book payload was malformed),
  `:polymarket_invalid_trade_payload` (trade event was malformed —
  bad side/size/price/timestamp or not a map), and
  `:polymarket_instrument_mismatch` (live-mirror fill arrived for the
  wrong token). Every failure returned by `normalize_fill/2` /
  `normalize_snapshot/2` / `normalize_instrument/1` is one of these
  bounded codes — the underlying `ActivityMapper` / `OrderBook` /
  `Market` atoms never leak through.
  """

  @behaviour PaperEx.Adapter

  alias PaperEx.ReasonCodes

  alias PaperExPolymarket.{ActivityMapper, Execution, Fees, Market, OrderBook}

  @doc """
  See `c:PaperEx.Adapter.normalize_instrument/1`. Accepts CLOB market
  payloads with a `"token_id"` / `:token_id` field, a bare token id
  string, or a `{:token_id, "…"}` tuple.
  """
  @impl true
  def normalize_instrument(%{} = clob_market) do
    case clob_market do
      %{"token_id" => token_id} when is_binary(token_id) ->
        Market.from_clob_market(token_id, clob_market)

      %{token_id: token_id} when is_binary(token_id) ->
        Market.from_clob_market(token_id, clob_market)

      _other ->
        {:error, :polymarket_invalid_market_payload}
    end
  end

  def normalize_instrument({:token_id, token_id}) when is_binary(token_id),
    do: Market.from_token_id(token_id)

  def normalize_instrument(token_id) when is_binary(token_id),
    do: Market.from_token_id(token_id)

  def normalize_instrument(_other), do: {:error, :polymarket_invalid_market_payload}

  @doc """
  See `c:PaperEx.Adapter.normalize_snapshot/2`. Accepts a CLOB
  `/book` body map; returns `{:error, :polymarket_invalid_book}` for
  malformed payloads.
  """
  @impl true
  def normalize_snapshot(%{} = clob_book, %PaperEx.Instrument{} = inst) do
    case OrderBook.from_clob_book(clob_book, inst) do
      {:ok, snap} -> {:ok, snap}
      {:error, :invalid_book} -> {:error, :polymarket_invalid_book}
    end
  end

  def normalize_snapshot(_other, _inst), do: {:error, :polymarket_invalid_book}

  @doc """
  See `c:PaperEx.Adapter.normalize_fill/2`. Maps a Polymarket
  Data-API or RTDS trade event into a `PaperEx.Fill`.

  All `ActivityMapper` failures are remapped into the bounded
  `reason_codes/0` set so nothing untagged escapes:

    * an asset/instrument identity mismatch becomes
      `{:error, :polymarket_instrument_mismatch}`;
    * any malformed trade content (bad side, size, price, or
      timestamp) becomes `{:error, :polymarket_invalid_trade_payload}`.
  """
  @impl true
  def normalize_fill(%{} = payload, %PaperEx.Instrument{} = inst) do
    case ActivityMapper.from_trade(payload, inst) do
      {:ok, fill} -> {:ok, fill}
      {:error, :instrument_mismatch} -> {:error, :polymarket_instrument_mismatch}
      {:error, _malformed} -> {:error, :polymarket_invalid_trade_payload}
    end
  end

  def normalize_fill(_other, _inst), do: {:error, :polymarket_invalid_trade_payload}

  @doc """
  See `c:PaperEx.Adapter.simulate_fill/3`. Delegates to
  `PaperExPolymarket.Execution.simulate_fill/3`.
  """
  @impl true
  def simulate_fill(%PaperEx.Order{} = order, %PaperEx.MarketSnapshot{} = snap, opts) do
    Execution.simulate_fill(order, snap, opts)
  end

  @doc """
  See `c:PaperEx.Adapter.fee/2`. Delegates to
  `PaperExPolymarket.Fees.fee/2` — applies `:fee_bps` (basis points)
  from `opts`. Defaults to zero.
  """
  @impl true
  def fee(%PaperEx.Fill{} = fill, opts), do: Fees.fee(fill, opts)

  @doc """
  See `c:PaperEx.Adapter.reason_codes/0`. Returns generic engine
  codes plus Polymarket-tagged ones.
  """
  @impl true
  def reason_codes do
    ReasonCodes.engine_codes() ++
      [
        :polymarket_invalid_market_payload,
        :polymarket_invalid_book,
        :polymarket_invalid_trade_payload,
        :polymarket_instrument_mismatch
      ]
  end
end

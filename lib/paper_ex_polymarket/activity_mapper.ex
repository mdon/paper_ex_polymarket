defmodule PaperExPolymarket.ActivityMapper do
  @moduledoc """
  Translation between Polymarket Data-API activity / trade events and
  `PaperEx.Fill`.

  Used for **live-mirror reconciliation**: when a real Polymarket
  trade is observed (via the RTDS stream or the Data API
  `/activity` endpoint), the mirror layer turns it into a `Fill` so
  the paper engine can compare what *did* happen against what its
  simulation said would happen.

  ## Input shapes

  Two well-known shapes are supported:

    * Data API `/activity` events with `"type" => "TRADE"`, fields
      `"asset"`, `"side"`, `"size"`, `"price"`, `"timestamp"`,
      `"transactionHash"`, optional `"outcome"`, `"outcomeIndex"`,
      `"pseudonym"`, `"proxyWallet"`.
    * RTDS trade payloads from the global feed, structurally
      identical to the above. Any map carrying an asset token id
      (`"asset"`, or the fallbacks `"asset_id"` / `"token_id"`) plus
      `"side"`, `"size"`, and `"price"` parses.

  ## Side mapping

  Polymarket strings `"BUY"` / `"SELL"` map to `:buy` / `:sell`. Any
  other side string yields `{:error, :invalid_side}`.

  ## Errors

  `from_trade/2` is total — it returns `{:error, atom()}` (never
  raises) for any bad input:

    * `:instrument_mismatch` — the event's asset token id is missing,
      nil, non-binary, or does not equal the instrument id.
    * `:invalid_side` — `"side"` is not `"BUY"` / `"SELL"`.
    * `:zero_size` — `"size"` is zero (`PaperEx.Fill` requires
      `size > 0`).
    * `:invalid_number` — `"size"` / `"price"` is non-numeric, a
      partial-parse string, or negative. Price zero is accepted
      (`PaperEx.Fill` allows `price >= 0`).
    * `:invalid_timestamp` — an integer `"timestamp"` outside the
      Unix second/millisecond ranges, or a non-integer/non-string
      timestamp (float, map, …). A garbage numeric-*string* timestamp
      instead falls back to the current time.
  """

  alias PaperEx.{Fill, Instrument}

  @doc """
  Maps a Polymarket trade payload onto a `PaperEx.Fill` for the
  given `instrument`.

  The event's asset token id (`"asset"`, falling back to `"asset_id"`
  / `"token_id"`) MUST equal the instrument's `:id`; a missing, nil,
  non-binary, or differing asset yields `{:error, :instrument_mismatch}`.
  See the module `Errors` section for the full `{:error, atom()}` set.
  """
  @spec from_trade(map(), Instrument.t()) :: {:ok, Fill.t()} | {:error, atom()}
  def from_trade(%{} = payload, %Instrument{id: id} = inst) do
    with :ok <- check_asset(payload, id),
         {:ok, side} <- parse_side(payload["side"]),
         {:ok, size} <- parse_size(payload["size"]),
         {:ok, price} <- parse_price(payload["price"]),
         {:ok, timestamp} <- parse_timestamp(payload["timestamp"]) do
      {:ok,
       Fill.new(
         size: size,
         price: price,
         side: side,
         fee: 0,
         liquidity: liquidity_hint(payload),
         timestamp: timestamp,
         metadata: %{
           instrument_id: inst.id,
           tx_hash: payload["transactionHash"],
           outcome: payload["outcome"],
           outcome_index: payload["outcomeIndex"],
           pseudonym: payload["pseudonym"],
           proxy_wallet: payload["proxyWallet"],
           raw_event: payload
         }
       )}
    end
  end

  # Enforce instrument identity: the event's asset (token id) must
  # equal the instrument's id. The asset is read from "asset", falling
  # back to "asset_id" / "token_id". A missing, nil, non-binary, or
  # differing asset is a wrong-instrument event and MUST NOT apply as a
  # fill — this is a live-mirror reconciliation adapter, so a silent
  # allow-through would double-book the wrong token.
  defp check_asset(payload, id) do
    case event_asset(payload) do
      asset when is_binary(asset) and asset == id -> :ok
      _ -> {:error, :instrument_mismatch}
    end
  end

  defp event_asset(payload) do
    payload["asset"] || payload["asset_id"] || payload["token_id"]
  end

  defp parse_side("BUY"), do: {:ok, :buy}
  defp parse_side("SELL"), do: {:ok, :sell}
  defp parse_side(_), do: {:error, :invalid_side}

  # Size must be strictly positive (`PaperEx.Fill` requires `size > 0`).
  defp parse_size(v), do: parse_number(v, :size)

  # Price may be zero (`PaperEx.Fill` allows `price >= 0`); only a
  # negative or non-numeric price is rejected.
  defp parse_price(v), do: parse_number(v, :price)

  defp parse_number(n, kind) when is_number(n), do: classify_number(n, kind)

  # Strict: the whole string must parse as a float. `"12abc"` /
  # `"0.5x"` / `"  1.0"` / `"1.0 "` all fail. Tolerating partial
  # parses risks silently swallowing exchange-side schema drift.
  defp parse_number(s, kind) when is_binary(s) do
    case Float.parse(s) do
      {n, ""} -> classify_number(n, kind)
      _ -> {:error, :invalid_number}
    end
  end

  defp parse_number(_, _kind), do: {:error, :invalid_number}

  defp classify_number(n, :size) when n > 0, do: {:ok, n / 1}
  defp classify_number(n, :size) when n == 0, do: {:error, :zero_size}
  defp classify_number(n, :price) when n >= 0, do: {:ok, n / 1}
  defp classify_number(_n, _kind), do: {:error, :invalid_number}

  # Returns `{:ok, DateTime.t()}` or `{:error, :invalid_timestamp}`.
  # Total: never raises, so the `from_trade/2` `{:error, atom()}`
  # contract holds for every input.
  defp parse_timestamp(nil), do: {:ok, DateTime.utc_now()}

  # Integer timestamps: values > 1e12 are milliseconds. Only the two
  # ranges `DateTime.from_unix/1` accepts (seconds and milliseconds)
  # are valid; anything else (including the gap that would make
  # `from_unix!` RAISE) yields `{:error, :invalid_timestamp}`.
  defp parse_timestamp(ts) when is_integer(ts) do
    cond do
      ts > 1_000_000_000_000 -> from_unix(div(ts, 1000))
      true -> from_unix(ts)
    end
  end

  # Strict: timestamp strings must parse fully. `"1700000000abc"`
  # falls back to `DateTime.utc_now/0` rather than silently
  # truncating to a valid prefix.
  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {n, ""} -> parse_timestamp(n)
      _ -> {:ok, DateTime.utc_now()}
    end
  end

  # Total for all other input (floats, maps, etc.): the `@spec`
  # promises `{:error, atom()}`, never a raise.
  defp parse_timestamp(_other), do: {:error, :invalid_timestamp}

  defp from_unix(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_timestamp}
    end
  end

  defp liquidity_hint(%{"liquidityType" => "MAKER"}), do: :maker
  defp liquidity_hint(%{"liquidityType" => "TAKER"}), do: :taker
  defp liquidity_hint(_), do: nil
end

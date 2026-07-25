defmodule PaperExPolymarket.OrderBook do
  @moduledoc """
  Translation between Polymarket CLOB order book payloads and
  `PaperEx.MarketSnapshot`.

  A CLOB `/book` response looks like:

      %{
        "market" => "0x…",          # condition id
        "asset_id" => "12345…",     # token id
        "bids" => [%{"price" => "0.53", "size" => "100"}, …],
        "asks" => [%{"price" => "0.55", "size" => "80"},  …],
        "timestamp" => "1700000000",
        "tick_size" => "0.01",
        …
      }

  Prices and sizes arrive as decimal strings; this module parses them
  into floats (matching `polymarket_clob`'s float-first policy — see
  Decision 6 in the workspace `DECISIONS.md`).

  ## Sort order

  `PaperEx.MarketSnapshot.best_bid/best_ask` take the list head, so
  the head must be the BEST level (bids descending, asks ascending).
  The live CLOB `/book` returns levels best price **last** (bids
  ascending, asks descending), so this module re-sorts explicitly:
  bids high→low and asks low→high. The sort is independent of the
  venue's ordering, so a re-ordered payload still normalizes
  correctly.
  """

  alias PaperEx.MarketSnapshot

  @doc """
  Builds a `PaperEx.MarketSnapshot` from a CLOB book body for the
  given instrument.

  Returns `{:error, :invalid_book}` if the payload is missing the
  required `"bids"` / `"asks"` keys or if any level fails to parse.
  """
  @spec from_clob_book(map(), PaperEx.Instrument.t()) ::
          {:ok, MarketSnapshot.t()} | {:error, :invalid_book}
  def from_clob_book(%{"bids" => raw_bids, "asks" => raw_asks} = body, %PaperEx.Instrument{id: id}) do
    with {:ok, bids} <- parse_levels(raw_bids),
         {:ok, asks} <- parse_levels(raw_asks) do
      {:ok,
       MarketSnapshot.new(
         instrument_id: id,
         # `MarketSnapshot.best_bid/best_ask` take the list head, so
         # the head must be the BEST level. The live CLOB `/book`
         # returns bids ascending and asks descending (best price
         # last), so sort explicitly: bids high→low, asks low→high.
         # Independent of the venue's ordering.
         bids: Enum.sort_by(bids, &elem(&1, 0), :desc),
         asks: Enum.sort_by(asks, &elem(&1, 0), :asc),
         as_of: parse_timestamp(body["timestamp"]),
         metadata: %{
           condition_id: body["market"],
           asset_id: body["asset_id"],
           tick_size: body["tick_size"],
           raw_book: body
         }
       )}
    end
  end

  def from_clob_book(_body, _instrument), do: {:error, :invalid_book}

  defp parse_levels(levels) when is_list(levels) do
    levels
    |> Enum.reduce_while({:ok, []}, fn level, {:ok, acc} ->
      case parse_level(level) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, tuple} -> {:cont, {:ok, [tuple | acc]}}
        :error -> {:halt, {:error, :invalid_book}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp parse_levels(_), do: {:error, :invalid_book}

  defp parse_level(%{"price" => p_raw, "size" => s_raw}) do
    with {:ok, price} <- parse_number(p_raw),
         {:ok, size} <- parse_number(s_raw) do
      cond do
        size == 0 -> {:ok, nil}
        # `MarketSnapshot.new/1` requires price >= 0 and size > 0 and
        # RAISES otherwise, so reject negatives here to honor the
        # `{:error, :invalid_book}` contract instead of crashing.
        price < 0 -> :error
        size < 0 -> :error
        true -> {:ok, {price, size}}
      end
    else
      _ -> :error
    end
  end

  defp parse_level(_), do: :error

  defp parse_number(n) when is_number(n), do: {:ok, n / 1}

  defp parse_number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_number(_), do: :error

  defp parse_timestamp(nil), do: DateTime.utc_now()

  # Strict: timestamp strings must parse fully. `"1700000000abc"`
  # falls back to `DateTime.utc_now/0` rather than silently
  # truncating to a valid prefix. The live CLOB `/book` sends the
  # timestamp as a **string of milliseconds** (e.g. "1781577793787"),
  # so the string path must apply the same ms-vs-seconds heuristic as
  # the integer path — not assume seconds.
  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {n, ""} -> parse_timestamp(n)
      _ -> DateTime.utc_now()
    end
  end

  # Polymarket timestamps may arrive in seconds or milliseconds.
  # 13-digit (> 1e12) values are milliseconds. A malformed timestamp
  # must never crash the snapshotter (and with it the app) — fall
  # back to the current time.
  defp parse_timestamp(ts) when is_integer(ts) do
    seconds = if ts > 1_000_000_000_000, do: div(ts, 1000), else: ts
    DateTime.from_unix!(seconds)
  rescue
    _ -> DateTime.utc_now()
  end

  defp parse_timestamp(_other), do: DateTime.utc_now()
end

defmodule PaperExPolymarket.Market do
  @moduledoc """
  Translation between Polymarket market identifiers and
  `PaperEx.Instrument`.

  Polymarket has two relevant identifier flavors:

    * **condition id** — `0x…` hex string identifying a market
      (a question). Has two outcomes: YES (`outcome_index = 0`)
      and NO (`outcome_index = 1`).
    * **token id** — large decimal-string integer identifying a single
      outcome's ERC-1155 token. One condition has two token ids.

  The CLOB places orders against a token id (one side of the market).
  This adapter therefore keys instruments by **token id** — the
  same level the order book operates on.

  `from_clob_market/2` builds an `Instrument` from a CLOB market
  metadata payload (`/markets/{condition_id}` or
  `/markets-by-token/{token_id}` response) plus an explicit
  `:token_id` so the instrument id matches the order book the engine
  will walk. The full payload is preserved in
  `Instrument.metadata.raw_market` for traceability.
  """

  alias PaperEx.Instrument

  @typedoc "A CLOB market metadata payload (as returned by polymarket_clob)."
  @type clob_market :: map()

  @doc """
  Builds a `PaperEx.Instrument` for the given token id, using the
  supplied CLOB market metadata for display fields.

  `clob_market` is the raw CLOB market payload (a map). Display fields
  are read defensively — `"question"`, `"market_slug"`, and the tick
  size (`"minimum_tick_size"`, falling back to the `"tick_size"` alt
  key); `"condition_id"` falls back to `"market"`; the outcome
  label/index come from the matching entry in `"tokens"`. Any field
  missing from the payload simply becomes `nil` on the instrument, and
  a token id not present in `"tokens"` still returns `{:ok, _}` with a
  nil outcome label/index. The full payload is preserved in
  `Instrument.metadata.raw_market`.

  Always returns `{:ok, Instrument.t()}` for a binary token id and a
  map payload; a parsed tick size is always a valid positive float (or
  nil), so `PaperEx.Instrument.new/1` does not raise on this path.
  """
  @spec from_clob_market(String.t(), clob_market()) :: {:ok, Instrument.t()}
  def from_clob_market(token_id, %{} = clob_market) when is_binary(token_id) do
    outcome = find_outcome(clob_market, token_id)

    {:ok,
     Instrument.new(
       id: token_id,
       symbol: market_symbol(clob_market, outcome),
       exchange: "polymarket",
       description: clob_market["question"],
       tick_size: parse_tick_size(clob_market),
       metadata: %{
         condition_id: clob_market["condition_id"] || clob_market["market"],
         market_slug: clob_market["market_slug"],
         outcome: outcome[:label],
         outcome_index: outcome[:index],
         neg_risk: clob_market["neg_risk"],
         raw_market: clob_market
       }
     )}
  end

  @doc """
  Convenience: builds an `Instrument` for a token id with no CLOB
  metadata. Useful for tests and fixture-only callers.

  Unlike `from_clob_market/2`, the `:tick_size` opt is passed straight
  through to `PaperEx.Instrument.new/1`, which RAISES `ArgumentError`
  on a non-positive or non-numeric tick size. Pass a positive number
  or omit it.
  """
  @spec from_token_id(String.t(), keyword()) :: {:ok, Instrument.t()}
  def from_token_id(token_id, opts \\ []) when is_binary(token_id) do
    {:ok,
     Instrument.new(
       id: token_id,
       symbol: Keyword.get(opts, :symbol),
       exchange: "polymarket",
       description: Keyword.get(opts, :description),
       tick_size: Keyword.get(opts, :tick_size),
       metadata: Map.new(Keyword.get(opts, :metadata, []))
     )}
  end

  defp find_outcome(%{"tokens" => tokens}, token_id) when is_list(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.find_value(fn {tok, idx} ->
      if tok["token_id"] == token_id do
        %{label: tok["outcome"], index: idx}
      end
    end) || %{label: nil, index: nil}
  end

  defp find_outcome(_clob_market, _token_id), do: %{label: nil, index: nil}

  defp market_symbol(%{"market_slug" => slug}, %{label: label})
       when is_binary(slug) and is_binary(label),
       do: "#{slug}:#{label}"

  defp market_symbol(%{"market_slug" => slug}, _) when is_binary(slug), do: slug
  defp market_symbol(_, %{label: label}) when is_binary(label), do: label
  defp market_symbol(_, _), do: nil

  # Try "minimum_tick_size" first, then fall back to the "tick_size"
  # alt key. A present-but-null/""/"0"/unparseable "minimum_tick_size"
  # must NOT block the fallback, so match on the parsed value rather
  # than mere key presence.
  defp parse_tick_size(%{"minimum_tick_size" => ts} = market) do
    case parse_number(ts) do
      nil -> parse_tick_size(Map.delete(market, "minimum_tick_size"))
      n -> n
    end
  end

  defp parse_tick_size(%{"tick_size" => ts}), do: parse_number(ts)
  defp parse_tick_size(_), do: nil

  defp parse_number(nil), do: nil
  defp parse_number(n) when is_number(n) and n > 0, do: n

  # Strict: the whole string must parse (`{n, ""}`), matching the
  # sibling `OrderBook` / `ActivityMapper` parsers. A partial parse
  # like `"0.01abc"` yields nil rather than silently becoming `0.01`.
  defp parse_number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_number(_), do: nil
end

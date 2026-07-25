defmodule PaperExPolymarket.Snapshot do
  @moduledoc """
  Convenience module that closes the loop from a raw Polymarket CLOB
  `/book` response to a normalized `PaperEx.MarketSnapshot`.

  This module composes two pieces that already exist independently:

    * `PaperExPolymarket.Market` — turns a token id / CLOB market
      payload into a `PaperEx.Instrument`.
    * `PaperExPolymarket.OrderBook` — turns a CLOB book body into a
      `PaperEx.MarketSnapshot` for that instrument.

  Network IO is **injected**, never owned: callers pass either a
  pre-fetched book body (`from_clob_book/3`) or a fetcher
  function/MFA tuple (`fetch_order_book_snapshot/3`). The adapter
  package itself never opens a socket.

  ## Why a separate module instead of in `polymarket`

  `polymarket` is upstream of paper packages; it must not depend on
  `paper_ex` or `paper_ex_polymarket`. Helpers that return a
  `PaperEx.MarketSnapshot` therefore belong here. A consumer wires
  their own `polymarket_clob` (or other) fetcher into this module's
  `fetch_order_book_snapshot/3`.

  ## Two entry points

  ### `from_clob_book/3` — already have a body

  Use this when you have already fetched the CLOB `/book` body
  yourself (typically via `PolymarketClob.API.MarketData.get_order_book/2`):

      {:ok, body} = PolymarketClob.API.MarketData.get_order_book(token_id)
      {:ok, snap} = PaperExPolymarket.Snapshot.from_clob_book(token_id, body)

  An already-normalized `PaperEx.Instrument` can be passed instead of
  a token id; the adapter will simply skip the lookup step.

  ### `fetch_order_book_snapshot/3` — inject a fetcher

  Use this when you want `Snapshot` to handle the fetch step too.
  `fetcher` is one of:

    * a 1-arity anonymous function `fn token_id -> {:ok, body} | {:error, term} end`
    * a `{module, function, args}` tuple invoked as
      `apply(module, function, args ++ [token_id])`

  The fetcher is the only piece that talks to the network. Tests
  pass a stub function; production wires this through
  `polymarket_clob`. The adapter has zero opinions about which
  network library or which credentials the fetcher uses.

  ## Errors

    * `{:error, :polymarket_invalid_market_payload}` from the
      `Instrument` step (unresolvable instrument reference).
    * `{:error, :polymarket_invalid_book}` from the `OrderBook`
      step (malformed book body).
    * `{:error, :polymarket_invalid_fetcher}` from
      `fetch_order_book_snapshot/3` when the `fetcher` is neither a
      1-arity function nor a `{module, function, args}` tuple.
    * Anything the fetcher returns as `{:error, term}` is propagated
      verbatim.
  """

  alias PaperEx.{Instrument, MarketSnapshot}
  alias PaperExPolymarket.{Market, OrderBook}

  @typedoc """
  A token id or an already-normalized `PaperEx.Instrument`. Token
  ids may be strings or `{:token_id, "…"}` tuples; instrument
  values are passed through unchanged.
  """
  @type instrument_ref :: String.t() | Instrument.t() | {:token_id, String.t()}

  @typedoc """
  Either a 1-arity function or a `{module, function, extra_args}`
  tuple. The token id is appended as the final argument.
  """
  @type fetcher ::
          (String.t() -> {:ok, map()} | {:error, term()})
          | {module(), atom(), list()}

  @doc """
  Build a `PaperEx.MarketSnapshot` from an already-fetched CLOB book
  body for the given instrument reference.

  `instrument_ref` may be:

    * a `PaperEx.Instrument` — used verbatim;
    * a token id string — resolved via
      `PaperExPolymarket.Market.from_token_id/2`;
    * a `{:token_id, "…"}` tuple — equivalent to the bare string.

  Options:

    * `:instrument_opts` — keyword list forwarded to
      `Market.from_token_id/2` when resolving a token id.
  """
  @spec from_clob_book(instrument_ref(), map(), keyword()) ::
          {:ok, MarketSnapshot.t()} | {:error, term()}
  def from_clob_book(instrument_ref, body, opts \\ []) do
    with {:ok, %Instrument{} = inst} <- resolve_instrument(instrument_ref, opts),
         {:ok, snap} <- normalize_snapshot(body, inst) do
      {:ok, snap}
    end
  end

  @doc """
  Fetch a CLOB book for `instrument_ref` via the injected `fetcher`
  and normalize the result.

  Tests pass `fn _id -> {:ok, fixture_body} end`. Production wires
  this through `polymarket_clob`'s order-book endpoint with whatever
  client/credentials the caller has assembled.

  Returns `{:error, term}` if the fetcher errors; the error is
  propagated unchanged.
  """
  @spec fetch_order_book_snapshot(fetcher(), instrument_ref(), keyword()) ::
          {:ok, MarketSnapshot.t()} | {:error, term()}
  def fetch_order_book_snapshot(fetcher, instrument_ref, opts \\ []) do
    with {:ok, token_id} <- token_id(instrument_ref),
         {:ok, body} <- call_fetcher(fetcher, token_id) do
      from_clob_book(instrument_ref, body, opts)
    end
  end

  defp resolve_instrument(%Instrument{} = inst, _opts), do: {:ok, inst}

  defp resolve_instrument({:token_id, token_id}, opts) when is_binary(token_id) do
    Market.from_token_id(token_id, Keyword.get(opts, :instrument_opts, []))
  end

  defp resolve_instrument(token_id, opts) when is_binary(token_id) do
    Market.from_token_id(token_id, Keyword.get(opts, :instrument_opts, []))
  end

  defp resolve_instrument(_other, _opts),
    do: {:error, :polymarket_invalid_market_payload}

  defp normalize_snapshot(body, %Instrument{} = inst) do
    case OrderBook.from_clob_book(body, inst) do
      {:ok, snap} -> {:ok, snap}
      {:error, :invalid_book} -> {:error, :polymarket_invalid_book}
    end
  end

  defp token_id(%Instrument{id: id}), do: {:ok, id}
  defp token_id({:token_id, id}) when is_binary(id), do: {:ok, id}
  defp token_id(id) when is_binary(id), do: {:ok, id}
  defp token_id(_other), do: {:error, :polymarket_invalid_market_payload}

  defp call_fetcher(fun, token_id) when is_function(fun, 1), do: fun.(token_id)

  defp call_fetcher({mod, fun, args}, token_id)
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    apply(mod, fun, args ++ [token_id])
  end

  defp call_fetcher(_other, _token_id),
    do: {:error, :polymarket_invalid_fetcher}
end

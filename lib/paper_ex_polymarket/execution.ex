defmodule PaperExPolymarket.Execution do
  @moduledoc """
  Polymarket-flavored fill simulator.

  This module simulates how a `PaperEx.Order` *would* execute against
  a `PaperEx.MarketSnapshot` produced by
  `PaperExPolymarket.OrderBook.from_clob_book/2`. It is the
  `simulate_fill/3` implementation behind `PaperExPolymarket.Adapter`.

  ## Polymarket order-type defaults

  Polymarket's CLOB v2 supports several order types (FOK, FAK, GTC,
  GTD). The adapter maps `PaperEx.Order` types as follows:

    * `:market` — modeled as **FAK** (fill-and-kill against current
      book). Walks levels; whatever fills, fills. Unfilled remainder
      is dropped (a future phase may emit a `:pending` execution for
      the remainder).
    * `:limit` — modeled as **GTC** for simulation purposes. The
      order fills against any level that crosses the limit price.
      Unfilled remainder is reported as a partial fill; the engine
      can decide to leave the rest as `:pending`.

  This is intentionally simpler than the live CLOB's full lifecycle.
  Research-mode simulation does not need GTC resting-order
  reconciliation. Live-mirror callers wanting that detail should
  combine `simulate_fill/3` with their own pending-order tracking
  using `PaperEx.Execution.status` `:pending` → `:filled` /
  `:cancelled` transitions.

  ## `:size` vs `:amount` for `:market` orders

  A `:market` order can specify quantity in two ways:

    * `:size` — explicit share quantity. The walker takes
      `min(level_size, remaining_shares)` at each level until shares
      are exhausted.
    * `:amount` — currency budget (`"spend at most $N"` for buys,
      `"receive at most $N"` for sells). The walker takes
      `min(level_size, remaining_budget / price)` at each level
      until the budget is exhausted. This is the right reading for
      prediction markets where `$5` at price `0.05` should buy
      `100` shares, not `5`.

  When both `:size` and `:amount` are set, `:size` wins — the
  caller has stated explicit share quantity. For `:limit` orders,
  `:amount` is informational only; the walker always uses `:size`
  (per `PaperEx.Order` moduledoc).

  ## Return shape

  Matches `c:PaperEx.Adapter.simulate_fill/3`:

    * `{:ok, :filled, [Fill.t()]}` — the order's target was reached:
      the full requested `:size` for a share order, or the full
      `:amount` budget exhausted for a budget (`:amount`) order.
    * `{:ok, :partial, [Fill.t()]}` — some quantity filled; remainder
      unmodeled (book exhausted before the size/budget target).
    * `{:ok, :missed, :limit_not_crossed}` — limit price did not cross
      the book.
    * `{:ok, :missed, :no_liquidity}` — relevant side of book empty.
  """

  alias PaperEx.{Fill, MarketSnapshot, Order}

  # Tolerance for "budget exhausted" — protects the :filled vs
  # :partial classification against float drift after a sequence of
  # `spent = take * price` reductions.
  @budget_epsilon 1.0e-9

  @doc """
  Simulate `order` against `snapshot`. `opts` is reserved for
  future tuning (slippage cap, post-only flag, etc.) and currently
  ignored.
  """
  @spec simulate_fill(Order.t(), MarketSnapshot.t(), keyword()) ::
          {:ok, :filled | :partial, [Fill.t()]}
          | {:ok, :missed, atom() | String.t()}
  def simulate_fill(%Order{} = order, %MarketSnapshot{} = snap, _opts \\ []) do
    levels =
      case order.side do
        :buy -> snap.asks
        :sell -> snap.bids
      end

    case {levels, target(order)} do
      {[], _} ->
        {:ok, :missed, :no_liquidity}

      {_, :none} ->
        {:ok, :missed, :no_liquidity}

      {levels, {mode, value}} when value > 0 ->
        walk(order, levels, mode, value)
    end
  end

  # Returns `{:shares, n}` for share-quantity orders, `{:budget, n}`
  # for currency-budget market orders, or `:none` when no usable
  # quantity is present.
  defp target(%Order{order_type: :limit, size: size}) when is_number(size) and size > 0,
    do: {:shares, size}

  defp target(%Order{order_type: :limit}), do: :none

  defp target(%Order{size: size}) when is_number(size) and size > 0, do: {:shares, size}

  defp target(%Order{amount: amount}) when is_number(amount) and amount > 0,
    do: {:budget, amount}

  defp target(_), do: :none

  defp walk(%Order{order_type: :limit, price: limit, side: side} = order, levels, :shares, target) do
    case do_walk_shares(side, limit, levels, target, []) do
      {[], _remaining} -> {:ok, :missed, :limit_not_crossed}
      {fills, 0} -> {:ok, :filled, fills} |> stamp(order)
      {fills, _remaining} -> {:ok, :partial, fills} |> stamp(order)
    end
  end

  defp walk(%Order{order_type: :market, side: side} = order, levels, :shares, target) do
    case do_walk_shares(side, nil, levels, target, []) do
      {[], _remaining} -> {:ok, :missed, :no_liquidity}
      {fills, 0} -> {:ok, :filled, fills} |> stamp(order)
      {fills, _remaining} -> {:ok, :partial, fills} |> stamp(order)
    end
  end

  defp walk(%Order{order_type: :market, side: side} = order, levels, :budget, budget) do
    case do_walk_budget(side, levels, budget, []) do
      {[], _remaining} ->
        {:ok, :missed, :no_liquidity}

      {fills, remaining} when remaining <= @budget_epsilon ->
        {:ok, :filled, fills} |> stamp(order)

      {fills, _remaining} ->
        {:ok, :partial, fills} |> stamp(order)
    end
  end

  defp stamp({:ok, status, fills}, %Order{side: side}) do
    stamped = Enum.map(fills, fn %Fill{} = f -> %{f | side: side} end)
    {:ok, status, stamped}
  end

  defp do_walk_shares(_side, _limit, _levels, remaining, fills) when remaining <= 0 do
    {Enum.reverse(fills), 0}
  end

  defp do_walk_shares(_side, _limit, [], remaining, fills) do
    {Enum.reverse(fills), remaining}
  end

  defp do_walk_shares(side, limit, [{price, size} | rest], remaining, fills) do
    if limit_ok?(side, limit, price) do
      take = min(remaining, size)
      fill = Fill.new(size: take, price: price, side: side)
      do_walk_shares(side, limit, rest, remaining - take, [fill | fills])
    else
      # Levels are sorted by attractiveness; once we hit an
      # un-crossable level, all later ones are also un-crossable.
      {Enum.reverse(fills), remaining}
    end
  end

  # Budget-walk: spend `budget` quote currency across `levels`,
  # taking `min(level_size, budget / price)` shares at each level.
  # Used only for `:market` orders with `:amount` and no `:size`.
  defp do_walk_budget(_side, _levels, remaining, fills) when remaining <= @budget_epsilon do
    {Enum.reverse(fills), 0}
  end

  defp do_walk_budget(_side, [], remaining, fills) do
    {Enum.reverse(fills), remaining}
  end

  defp do_walk_budget(side, [{price, level_size} | rest], remaining, fills) when price > 0 do
    affordable = remaining / price
    take = min(level_size, affordable)
    fill = Fill.new(size: take, price: price, side: side)
    spent = take * price
    do_walk_budget(side, rest, remaining - spent, [fill | fills])
  end

  defp do_walk_budget(side, [{price, _size} | rest], remaining, fills) when price <= 0 do
    # A price-0 level is VALID in a `MarketSnapshot` (it requires
    # `price >= 0`), so skip it and keep walking rather than halting
    # the whole budget walk and hiding deeper liquidity behind it. A
    # zero-price level costs nothing to cross for budget purposes, and
    # dividing by it is undefined, so it contributes no fill.
    do_walk_budget(side, rest, remaining, fills)
  end

  defp limit_ok?(_side, nil, _price), do: true
  defp limit_ok?(:buy, limit, price), do: price <= limit
  defp limit_ok?(:sell, limit, price), do: price >= limit
end

defmodule PaperExPolymarket.AdvancePendingIntegrationTest do
  @moduledoc """
  End-to-end test for `PaperEx.Engine.advance_pending/3` flowing
  through `PaperExPolymarket.Adapter`.

  Verifies the bot's intended periodic loop:

    1. apply a `:limit` order with `:pending_remainder` against an
       initial snapshot — produces a partial fill + pending entry;
    2. a fresh snapshot becomes available (Snapshotter refresh);
    3. `Engine.advance_pending/3` resolves the pending against the
       new book through the same Polymarket adapter.

  No network IO.
  """

  use ExUnit.Case, async: true

  alias PaperEx.{Engine, Execution, MarketSnapshot, Order, Portfolio, Position}
  alias PaperExPolymarket.Adapter

  defp inst_id, do: "111111111111111111111111111111111111111111111111111111111111111111"

  defp snap(asks) do
    MarketSnapshot.new(
      instrument_id: inst_id(),
      asks: asks,
      bids: []
    )
  end

  test "limit pending created by Polymarket adapter is resolved by advance_pending against a fresh snapshot" do
    portfolio = Portfolio.new(starting_balance: 100.0)

    # Initial book: 5 ask shares at 0.50 (limit will fill 5; 15
    # remaining of a size-20 limit buy).
    initial = snap([{0.50, 5}, {0.60, 100}])

    order =
      Order.new(
        market_id: inst_id(),
        side: :buy,
        order_type: :limit,
        size: 20,
        price: 0.50,
        id: "lim-1"
      )

    {p1, ex1} =
      Engine.apply_order(portfolio, order, initial,
        adapter: Adapter,
        pending_remainder: true
      )

    assert ex1.status == :filled
    assert_in_delta ex1.fill_size, 5.0, 1.0e-9

    pending = Enum.find(p1.executions, &(&1.status == :pending))
    assert pending.metadata.remaining_size == 15.0
    assert pending.metadata.side == :buy
    assert pending.metadata.limit_price == 0.50

    # A later snapshot reveals deeper liquidity at the limit price.
    fresh = snap([{0.50, 1_000}])

    {:ok, p2, results} = Engine.advance_pending(p1, fresh, adapter: Adapter)

    assert [{{:pending_remainder, "lim-1"}, {:filled, filled}}] = results
    assert filled.status == :filled
    assert_in_delta filled.fill_size, 15.0, 1.0e-9
    assert filled.metadata.source == :advance_pending
    assert filled.metadata.resolves == {:pending_remainder, "lim-1"}

    # Position now reflects the full original order size.
    assert [%Position{} = pos] = p2.positions
    assert_in_delta pos.shares, 20.0, 1.0e-9
  end

  test "advance_pending with a non-crossing fresh snapshot keeps the pending pending" do
    portfolio = Portfolio.new(starting_balance: 100.0)
    initial = snap([{0.50, 5}, {0.60, 100}])

    order =
      Order.new(
        market_id: inst_id(),
        side: :buy,
        order_type: :limit,
        size: 20,
        price: 0.50,
        id: "lim-2"
      )

    {p1, _} =
      Engine.apply_order(portfolio, order, initial, adapter: Adapter, pending_remainder: true)

    # Fresh book: only an ask at 0.60 (limit 0.50 doesn't cross).
    fresh = snap([{0.60, 1_000}])

    {:ok, p2, results} = Engine.advance_pending(p1, fresh, adapter: Adapter)

    assert [{_, {:still_pending, %Execution{status: :pending}}}] = results
    # Ledger unchanged (no missed/skipped/filled appended for
    # non-crossing advance).
    assert p2.executions == p1.executions
  end
end

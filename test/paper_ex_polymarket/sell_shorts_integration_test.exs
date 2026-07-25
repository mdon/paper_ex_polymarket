defmodule PaperExPolymarket.SellShortsIntegrationTest do
  @moduledoc """
  Integration test for the amount-based `:market :sell` shorts guard.

  Unlike `PaperEx.MockAdapter`, `PaperExPolymarket.Execution`
  actually budget-walks `:market :sell` orders specified by
  `:amount`. This test verifies that the engine's post-simulation
  shorts guard correctly catches a budget-walked sell that would
  open a short, and lets a budget-walked sell that fits within a
  held position fill normally.
  """

  use ExUnit.Case, async: true

  alias PaperEx.{Engine, Execution, Order, Portfolio, Position}
  alias PaperExPolymarket.{Adapter, Fixtures}

  defp setup_market do
    {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())
    {:ok, snap} = Adapter.normalize_snapshot(Fixtures.clob_book(), inst)
    {inst, snap}
  end

  defp open_long(portfolio, instrument_id, shares) do
    {_inst, snap} = setup_market()

    buy =
      Order.new(
        market_id: instrument_id,
        side: :buy,
        order_type: :market,
        size: shares,
        id: "long-#{shares}"
      )

    {p, _ex} = Engine.apply_order(portfolio, buy, snap, adapter: Adapter)
    p
  end

  describe "amount-based sell with the Polymarket adapter (real budget walking)" do
    test "no held position → :skipped / :shorts_disallowed (default allow_shorts: false)" do
      {_inst, snap} = setup_market()
      starting = Portfolio.new(starting_balance: 100.0)

      sell =
        Order.new(
          market_id: snap.instrument_id,
          side: :sell,
          order_type: :market,
          amount: 5.0,
          id: "sell-amt-1"
        )

      {p, ex} = Engine.apply_order(starting, sell, snap, adapter: Adapter)

      assert ex.status == :skipped
      assert ex.reason == :shorts_disallowed

      # Filled_size from the adapter's budget walk: $5 / 0.54 ≈ 9.26.
      assert_in_delta ex.metadata.filled_size, 5.0 / 0.54, 1.0e-9

      assert p.positions == []
      assert p.current_balance == starting.current_balance
    end

    test "held position large enough → :filled and held reduced" do
      {inst, snap} = setup_market()
      p0 = Portfolio.new(starting_balance: 1_000.0)
      p1 = open_long(p0, inst.id, 100)

      sell =
        Order.new(
          market_id: inst.id,
          side: :sell,
          order_type: :market,
          amount: 5.0,
          id: "sell-amt-2"
        )

      {p2, ex} = Engine.apply_order(p1, sell, snap, adapter: Adapter)
      assert ex.status == :filled

      assert [%Position{} = pos] = p2.positions
      # 100 - 5/0.54 ≈ 90.74
      assert_in_delta pos.shares, 100.0 - 5.0 / 0.54, 1.0e-9
    end

    test "allow_shorts: true → fills and opens a short with budget-walked size" do
      {_inst, snap} = setup_market()
      starting = Portfolio.new(starting_balance: 100.0)

      sell =
        Order.new(
          market_id: snap.instrument_id,
          side: :sell,
          order_type: :market,
          amount: 5.0,
          id: "sell-amt-3"
        )

      {p, ex} = Engine.apply_order(starting, sell, snap, adapter: Adapter, allow_shorts: true)
      assert ex.status == :filled
      assert [%Position{side: :sell} = pos] = p.positions
      assert_in_delta pos.shares, 5.0 / 0.54, 1.0e-9
    end

    test "skip is recorded in the ledger (mirror analytics see it)" do
      {_inst, snap} = setup_market()

      sell =
        Order.new(
          market_id: snap.instrument_id,
          side: :sell,
          order_type: :market,
          amount: 1.0,
          id: "sell-amt-4"
        )

      {p, _ex} =
        Engine.apply_order(Portfolio.new(starting_balance: 100.0), sell, snap, adapter: Adapter)

      assert [%Execution{status: :skipped, reason: :shorts_disallowed}] = p.executions
    end
  end
end

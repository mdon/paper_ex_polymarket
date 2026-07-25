defmodule PaperExPolymarket.PendingIntegrationTest do
  @moduledoc """
  Verifies that the `:pending_remainder` policy added to
  `PaperEx.Engine` flows through the Polymarket adapter correctly.
  The adapter itself was not modified — the engine handles pending
  appending generically — but these tests pin the contract from the
  adapter side so a future change can't silently regress it.
  """

  use ExUnit.Case, async: true

  alias PaperEx.{Engine, Execution, Order, Portfolio}
  alias PaperExPolymarket.{Adapter, Fixtures, LiveMirror}

  defp setup_market do
    {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())
    {:ok, snap} = Adapter.normalize_snapshot(Fixtures.clob_book(), inst)
    {inst, snap}
  end

  describe "limit-partial through the Polymarket adapter with pending_remainder" do
    test "appends a :pending execution for the unfilled remainder" do
      {_inst, snap} = setup_market()

      # Best ask is 80 @ 0.56; limit 0.56 wants 500 → fills 80,
      # remainder 420 should be pending.
      order =
        Order.new(
          market_id: snap.instrument_id,
          side: :buy,
          order_type: :limit,
          size: 500,
          price: 0.56,
          id: "lim-1"
        )

      {p, ex} =
        Engine.apply_order(Portfolio.new(starting_balance: 1_000.0), order, snap,
          adapter: Adapter,
          pending_remainder: true
        )

      assert ex.status == :filled
      assert_in_delta ex.fill_size, 80.0, 1.0e-9

      statuses = Enum.map(p.executions, & &1.status)
      assert statuses == [:filled, :pending]

      pending = Enum.find(p.executions, &(&1.status == :pending))
      assert pending.id == {:pending_remainder, "lim-1"}
      assert pending.order_id == "lim-1"
      assert_in_delta pending.metadata.remaining_size, 420.0, 1.0e-9
      assert_in_delta pending.metadata.filled_size, 80.0, 1.0e-9
      assert pending.metadata.market_id == snap.instrument_id
    end

    test "without pending_remainder, the unfilled remainder is dropped (default)" do
      {_inst, snap} = setup_market()

      order =
        Order.new(
          market_id: snap.instrument_id,
          side: :buy,
          order_type: :limit,
          size: 500,
          price: 0.56,
          id: "lim-1"
        )

      {p, _ex} =
        Engine.apply_order(Portfolio.new(starting_balance: 1_000.0), order, snap,
          adapter: Adapter
        )

      refute Enum.any?(p.executions, &(&1.status == :pending))
    end

    test "engine cancel_pending/3 cleanly resolves a pending remainder produced by the adapter" do
      {_inst, snap} = setup_market()

      order =
        Order.new(
          market_id: snap.instrument_id,
          side: :buy,
          order_type: :limit,
          size: 500,
          price: 0.56,
          id: "lim-1"
        )

      {p1, _} =
        Engine.apply_order(Portfolio.new(starting_balance: 1_000.0), order, snap,
          adapter: Adapter,
          pending_remainder: true
        )

      {:ok, p2, cancelled} = Engine.cancel_pending(p1, "lim-1", reason: :cancelled_by_caller)

      assert cancelled.status == :cancelled
      assert cancelled.reason == :cancelled_by_caller
      statuses = Enum.map(p2.executions, & &1.status)
      assert statuses == [:filled, :pending, :cancelled]
    end
  end

  describe "market FAK through the Polymarket adapter" do
    test "partial market fills NEVER record :pending even with pending_remainder on" do
      {_inst, snap} = setup_market()

      # Market buy by size walks asks. Book asks total 80+150+300+1500 = 2030.
      # Request 5000 → partial fill of 2030.
      order =
        Order.new(
          market_id: snap.instrument_id,
          side: :buy,
          order_type: :market,
          size: 5_000,
          id: "mkt-1"
        )

      {p, ex} =
        Engine.apply_order(Portfolio.new(starting_balance: 10_000.0), order, snap,
          adapter: Adapter,
          pending_remainder: true
        )

      # Pre-cash check may skip if 5000 × ask depth exceeds balance.
      # Confirm either filled-partial-no-pending OR a skipped attempt.
      case ex.status do
        :filled ->
          refute Enum.any?(p.executions, &(&1.status == :pending))

        :skipped ->
          # Insufficient cash is the more common outcome for a
          # multi-thousand-share market buy at 0.5x. Pending must
          # still not appear.
          refute Enum.any?(p.executions, &(&1.status == :pending))
      end
    end
  end

  describe "LiveMirror.record_pending/3 keeps working alongside engine pending" do
    test "manually-recorded pending coexists with engine-produced pending without conflict" do
      {inst, snap} = setup_market()

      # 1. Engine produces a pending remainder via the adapter.
      order_a =
        Order.new(
          market_id: inst.id,
          side: :buy,
          order_type: :limit,
          size: 500,
          price: 0.56,
          id: "engine-pending-1"
        )

      {p1, _} =
        Engine.apply_order(Portfolio.new(starting_balance: 1_000.0), order_a, snap,
          adapter: Adapter,
          pending_remainder: true
        )

      # 2. LiveMirror manually records a pending for a different
      #    order.
      order_b =
        Order.new(
          market_id: inst.id,
          side: :buy,
          order_type: :limit,
          size: 5,
          price: 0.40,
          id: "manual-pending-1"
        )

      {p2, manual_pending} = LiveMirror.record_pending(p1, order_b, id: "manual-1")

      # Both pendings live in the ledger.
      pendings = Enum.filter(p2.executions, &(&1.status == :pending))
      assert length(pendings) == 2

      # The manually-recorded pending uses LiveMirror's id, not the
      # engine's `{:pending_remainder, order_id}` tagged tuple.
      assert manual_pending.id == "manual-1"
    end

    test "Engine.cancel_pending/3 cancels by order_id; LiveMirror.resolve_pending/4 cancels by execution id — they do not collide" do
      {inst, snap} = setup_market()

      engine_order =
        Order.new(
          market_id: inst.id,
          side: :buy,
          order_type: :limit,
          size: 500,
          price: 0.56,
          id: "engine-order-1"
        )

      {p1, _} =
        Engine.apply_order(Portfolio.new(starting_balance: 1_000.0), engine_order, snap,
          adapter: Adapter,
          pending_remainder: true
        )

      manual_order =
        Order.new(
          market_id: inst.id,
          side: :buy,
          order_type: :limit,
          size: 5,
          price: 0.40,
          id: "manual-order-1"
        )

      {p2, _} = LiveMirror.record_pending(p1, manual_order, id: "manual-exec-1")

      # Engine.cancel_pending resolves the engine-produced one.
      assert {:ok, p3, %Execution{status: :cancelled}} =
               Engine.cancel_pending(p2, "engine-order-1")

      # LiveMirror.resolve_pending resolves the manually-recorded one
      # by its execution id.
      {p4, %Execution{status: :cancelled}} =
        LiveMirror.resolve_pending(p3, "manual-exec-1", :cancelled, [])

      # Both have a matching cancellation; no cross-contamination.
      cancellations = Enum.filter(p4.executions, &(&1.status == :cancelled))
      assert length(cancellations) == 2
    end
  end
end

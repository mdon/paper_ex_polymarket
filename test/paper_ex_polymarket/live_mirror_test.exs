defmodule PaperExPolymarket.LiveMirrorTest do
  use ExUnit.Case, async: true

  alias PaperEx.{Execution, Fill, Instrument, MarketSnapshot, Order, Portfolio, Position}
  alias PaperExPolymarket.LiveMirror

  defp inst, do: Instrument.new(id: "111", exchange: "polymarket")

  defp snap do
    MarketSnapshot.new(
      instrument_id: "111",
      bids: [{0.53, 50}],
      asks: [{0.55, 50}]
    )
  end

  defp port(opts \\ []) do
    Portfolio.new(Keyword.merge([starting_balance: 100.0], opts))
  end

  defp order(opts \\ []) do
    Order.new(
      Keyword.merge(
        [market_id: "111", side: :buy, order_type: :market, size: 5, id: "order-1"],
        opts
      )
    )
  end

  describe "simulate_intent/4" do
    test "stamps :live_mirror mode on a successful fill" do
      {p, ex} = LiveMirror.simulate_intent(port(), order(), snap())
      assert ex.status == :filled
      assert ex.metadata.mode == :live_mirror
      assert [%Position{shares: 5}] = p.positions
    end

    test "records a miss with :live_mirror mode when book has no liquidity" do
      empty = MarketSnapshot.new(instrument_id: "111")
      {_p, ex} = LiveMirror.simulate_intent(port(), order(), empty)
      assert ex.status == :missed
      assert ex.metadata.mode == :live_mirror
    end

    test "records a skip with :live_mirror mode when guardrail rejects" do
      {_p, ex} = LiveMirror.simulate_intent(port(starting_balance: 1.0), order(), snap())
      assert ex.status == :skipped
      assert ex.reason == :insufficient_cash
      assert ex.metadata.mode == :live_mirror
    end
  end

  describe "mirror_actual_fill/4" do
    test "records an actual exchange trade as a :filled execution" do
      event = %{
        "asset" => "111",
        "side" => "BUY",
        "size" => "5",
        "price" => "0.55",
        "transactionHash" => "0xdead"
      }

      {p, ex} = LiveMirror.mirror_actual_fill(port(), order(), event, inst())
      assert ex.status == :filled
      assert ex.fill_price == 0.55
      assert ex.fill_size == 5.0
      assert ex.metadata.mode == :live_mirror
      assert ex.metadata.source == :actual_fill
      assert ex.metadata.raw_event == event
      assert_in_delta p.current_balance, 100.0 - 5 * 0.55, 1.0e-9
      assert [%Position{shares: 5.0}] = p.positions
    end

    test "returns {portfolio, error} on instrument mismatch with no state change" do
      event = %{"asset" => "999", "side" => "BUY", "size" => "5", "price" => "0.55"}
      starting_portfolio = port()
      {p, err} = LiveMirror.mirror_actual_fill(starting_portfolio, order(), event, inst())
      assert err == {:error, :instrument_mismatch}
      assert p == starting_portfolio
    end
  end

  describe "record_pending/3" do
    test "appends a :pending execution and leaves cash/positions untouched" do
      starting_portfolio = port()
      {p, ex} = LiveMirror.record_pending(starting_portfolio, order(id: "pend-1"))
      assert ex.status == :pending
      assert ex.id == "pend-1"
      assert ex.metadata.mode == :live_mirror
      assert p.current_balance == starting_portfolio.current_balance
      assert p.positions == starting_portfolio.positions
      assert [^ex] = p.executions
    end
  end

  describe "resolve_pending/4 -> :filled" do
    test "fills with a :fill struct and updates cash/positions" do
      {p1, _} = LiveMirror.record_pending(port(), order(id: "pend-1"))
      fill = Fill.new(size: 5, price: 0.55, side: :buy)

      {p2, ex} =
        LiveMirror.resolve_pending(p1, "pend-1", :filled, order: order(id: "pend-1"), fill: fill)

      assert ex.status == :filled
      assert ex.fill_price == 0.55
      assert ex.metadata.resolved_from == "pend-1"
      assert [%Position{shares: 5}] = p2.positions
      assert_in_delta p2.current_balance, 100.0 - 5 * 0.55, 1.0e-9
    end

    test "fills with a Polymarket trade event" do
      {p1, _} = LiveMirror.record_pending(port(), order(id: "pend-1"))
      event = %{"asset" => "111", "side" => "BUY", "size" => "5", "price" => "0.55"}

      {p2, ex} =
        LiveMirror.resolve_pending(p1, "pend-1", :filled,
          order: order(id: "pend-1"),
          instrument: inst(),
          trade_event: event
        )

      assert ex.status == :filled
      assert ex.metadata.resolved_from == "pend-1"
      assert [%Position{shares: 5.0}] = p2.positions
    end

    test "errors when neither :fill nor :trade_event provided" do
      {p1, _} = LiveMirror.record_pending(port(), order(id: "pend-1"))
      {_p, err} = LiveMirror.resolve_pending(p1, "pend-1", :filled, order: order(id: "pend-1"))
      assert err == {:error, :fill_or_trade_event_required}
    end

    test "errors when the pending execution is not found" do
      {_p, err} =
        LiveMirror.resolve_pending(port(), "missing", :filled,
          order: order(),
          fill: Fill.new(size: 1, price: 0.5, side: :buy)
        )

      assert err == {:error, :pending_not_found}
    end
  end

  describe "resolve_pending/4 guards (binding + idempotency)" do
    test "rejects a resolve whose order does not match the pending" do
      {p1, _} = LiveMirror.record_pending(port(), order(id: "pend-1"))
      fill = Fill.new(size: 5, price: 0.55, side: :buy)

      {p2, err} =
        LiveMirror.resolve_pending(p1, "pend-1", :filled, order: order(id: "other"), fill: fill)

      assert err == {:error, :order_pending_mismatch}
      assert p2 == p1
    end

    test "resolving an already-filled pending is idempotent (no double-book)" do
      {p1, _} = LiveMirror.record_pending(port(), order(id: "pend-1"))
      fill = Fill.new(size: 5, price: 0.55, side: :buy)

      {p2, _} =
        LiveMirror.resolve_pending(p1, "pend-1", :filled, order: order(id: "pend-1"), fill: fill)

      {p3, err} =
        LiveMirror.resolve_pending(p2, "pend-1", :filled, order: order(id: "pend-1"), fill: fill)

      assert err == {:error, :pending_already_resolved}
      assert p3 == p2
    end
  end

  describe "resolve_pending/4 -> :cancelled" do
    test "appends a :cancelled execution and leaves state otherwise untouched" do
      {p1, _} = LiveMirror.record_pending(port(), order(id: "pend-1"))

      {p2, ex} =
        LiveMirror.resolve_pending(p1, "pend-1", :cancelled, reason: :cancelled_by_exchange)

      assert ex.status == :cancelled
      assert ex.reason == :cancelled_by_exchange
      assert ex.metadata.resolved_from == "pend-1"
      assert p2.positions == p1.positions
      assert p2.current_balance == p1.current_balance
      assert length(p2.executions) == 2
    end

    test "defaults reason to :cancelled_by_caller" do
      {p1, _} = LiveMirror.record_pending(port(), order(id: "pend-1"))
      {_p, ex} = LiveMirror.resolve_pending(p1, "pend-1", :cancelled, [])
      assert ex.reason == :cancelled_by_caller
    end
  end

  describe "preserving execution ledger across the lifecycle" do
    test "pending -> filled keeps both ledger entries" do
      {p1, _} = LiveMirror.record_pending(port(), order(id: "pend-1"))
      fill = Fill.new(size: 5, price: 0.55, side: :buy)

      {p2, _} =
        LiveMirror.resolve_pending(p1, "pend-1", :filled, order: order(id: "pend-1"), fill: fill)

      statuses = Enum.map(p2.executions, & &1.status)
      assert statuses == [:pending, :filled]
    end

    test "pending -> cancelled keeps both ledger entries" do
      {p1, _} = LiveMirror.record_pending(port(), order(id: "pend-1"))
      {p2, _} = LiveMirror.resolve_pending(p1, "pend-1", :cancelled, [])
      statuses = Enum.map(p2.executions, & &1.status)
      assert statuses == [:pending, :cancelled]
    end
  end

  describe "ExecutionAttempt design — what live-mirror exists to expose" do
    test "starting from an empty portfolio, the first event can be a miss" do
      # Mirror portfolios exist before the first fill — verifying the
      # ledger still records the miss with no fills having happened.
      empty_snap = MarketSnapshot.new(instrument_id: "111")
      starting_portfolio = port()
      {p, ex} = LiveMirror.simulate_intent(starting_portfolio, order(), empty_snap)

      assert p.positions == []
      assert p.history == []
      assert ex.status == :missed
      assert [^ex] = p.executions
    end

    test "skip due to insufficient cash is visible in the ledger" do
      starting_portfolio = port(starting_balance: 1.0)
      {p, _ex} = LiveMirror.simulate_intent(starting_portfolio, order(), snap())
      assert [%Execution{status: :skipped, reason: :insufficient_cash}] = p.executions
    end
  end
end

defmodule PaperExPolymarket.ExecutionTest do
  use ExUnit.Case, async: true

  alias PaperEx.{Fill, MarketSnapshot, Order}
  alias PaperExPolymarket.Execution

  defp snap do
    MarketSnapshot.new(
      instrument_id: "111",
      bids: [{0.53, 50}, {0.50, 100}],
      asks: [{0.55, 10}, {0.56, 100}]
    )
  end

  describe "market buy" do
    test "fills against best ask" do
      order = Order.new(market_id: "111", side: :buy, order_type: :market, size: 5)

      assert {:ok, :filled, [%Fill{size: 5, price: 0.55}]} =
               Execution.simulate_fill(order, snap())
    end

    test "walks multiple levels and tags fills as :buy" do
      order = Order.new(market_id: "111", side: :buy, order_type: :market, size: 15)
      assert {:ok, :filled, fills} = Execution.simulate_fill(order, snap())

      assert [%Fill{size: 10, price: 0.55, side: :buy}, %Fill{size: 5, price: 0.56, side: :buy}] =
               fills
    end

    test "partial when book exhausts before target" do
      tiny = MarketSnapshot.new(instrument_id: "111", asks: [{0.55, 3}], bids: [])
      order = Order.new(market_id: "111", side: :buy, order_type: :market, size: 10)
      assert {:ok, :partial, [%Fill{size: 3}]} = Execution.simulate_fill(order, tiny)
    end

    test "missed when asks side is empty" do
      empty = MarketSnapshot.new(instrument_id: "111", bids: [{0.53, 10}])
      order = Order.new(market_id: "111", side: :buy, order_type: :market, size: 5)
      assert {:ok, :missed, :no_liquidity} = Execution.simulate_fill(order, empty)
    end
  end

  describe "market sell" do
    test "walks bids descending" do
      order = Order.new(market_id: "111", side: :sell, order_type: :market, size: 60)

      assert {:ok, :filled,
              [%Fill{size: 50, price: 0.53, side: :sell}, %Fill{size: 10, price: 0.50}]} =
               Execution.simulate_fill(order, snap())
    end
  end

  describe "limit buy" do
    test "fills against asks below the limit" do
      order =
        Order.new(market_id: "111", side: :buy, order_type: :limit, size: 5, price: 0.55)

      assert {:ok, :filled, [%Fill{price: 0.55}]} = Execution.simulate_fill(order, snap())
    end

    test "missed when limit below best ask" do
      order =
        Order.new(market_id: "111", side: :buy, order_type: :limit, size: 5, price: 0.50)

      assert {:ok, :missed, :limit_not_crossed} = Execution.simulate_fill(order, snap())
    end

    test "partial when limit crosses one level then walks past it" do
      order =
        Order.new(market_id: "111", side: :buy, order_type: :limit, size: 20, price: 0.55)

      assert {:ok, :partial, [%Fill{size: 10, price: 0.55}]} =
               Execution.simulate_fill(order, snap())
    end
  end

  describe "market buy with :amount (currency budget)" do
    test "$5 budget at 0.05 price fills 100 shares, not 5" do
      cheap = MarketSnapshot.new(instrument_id: "111", asks: [{0.05, 500}], bids: [])

      order =
        Order.new(market_id: "111", side: :buy, order_type: :market, amount: 5.0, id: "o-1")

      assert {:ok, :filled, [%Fill{size: size, price: 0.05}]} =
               Execution.simulate_fill(order, cheap)

      assert_in_delta size, 100.0, 1.0e-9
    end

    test "budget walks multiple levels, taking min(level_size, budget/price)" do
      # Level 1: 50 at 0.05, full = $2.50.
      # Level 2: 100 at 0.10, affordable_with_remaining_$2.50 = 25 shares = $2.50.
      # Total: 50 + 25 = 75 shares for $5.00.
      snap =
        MarketSnapshot.new(
          instrument_id: "111",
          asks: [{0.05, 50}, {0.10, 100}],
          bids: []
        )

      order = Order.new(market_id: "111", side: :buy, order_type: :market, amount: 5.0)
      assert {:ok, :filled, fills} = Execution.simulate_fill(order, snap)
      assert [%Fill{price: 0.05} = f1, %Fill{price: 0.10} = f2] = fills
      assert_in_delta f1.size, 50.0, 1.0e-9
      assert_in_delta f2.size, 25.0, 1.0e-9
      total_spent = Enum.reduce(fills, 0.0, fn f, acc -> acc + f.size * f.price end)
      assert_in_delta total_spent, 5.0, 1.0e-9
    end

    test "partial when book is exhausted before budget" do
      tiny = MarketSnapshot.new(instrument_id: "111", asks: [{0.05, 30}], bids: [])
      order = Order.new(market_id: "111", side: :buy, order_type: :market, amount: 5.0)

      assert {:ok, :partial, [%Fill{price: 0.05} = fill]} =
               Execution.simulate_fill(order, tiny)

      assert_in_delta fill.size, 30.0, 1.0e-9
    end

    test "skips a zero-price level and fills deeper liquidity (does not halt)" do
      # price 0.0 is a VALID MarketSnapshot level; the budget walk must
      # skip it and keep going, not abort as :no_liquidity.
      snap = MarketSnapshot.new(instrument_id: "111", asks: [{0.0, 100}, {0.5, 20}], bids: [])
      order = Order.new(market_id: "111", side: :buy, order_type: :market, amount: 5.0)

      assert {:ok, :filled, [%Fill{price: 0.5} = fill]} =
               Execution.simulate_fill(order, snap)

      # $5 budget @ 0.5 = 10 shares; the 0.0 level contributes nothing.
      assert_in_delta fill.size, 10.0, 1.0e-9
    end

    test ":size wins when both :size and :amount are present (no double-counting)" do
      snap = MarketSnapshot.new(instrument_id: "111", asks: [{0.05, 500}], bids: [])

      order =
        Order.new(
          market_id: "111",
          side: :buy,
          order_type: :market,
          size: 7,
          amount: 5.0
        )

      # If :size wins, exactly 7 shares fill at 0.05 (not 100 from budget).
      assert {:ok, :filled, [%Fill{size: 7, price: 0.05}]} =
               Execution.simulate_fill(order, snap)
    end

    test ":limit orders never budget-walk (:amount is informational)" do
      # A :limit order with no :size and only :amount should fall
      # through to :none, not to budget-walking. The order is missed
      # for lack of usable quantity.
      snap = MarketSnapshot.new(instrument_id: "111", asks: [{0.05, 500}], bids: [])

      order =
        Order.new(
          market_id: "111",
          side: :buy,
          order_type: :limit,
          price: 0.05,
          # :limit requires :size — use a tiny size so we observe
          # that :amount does not augment it.
          size: 1.0,
          amount: 9999.0
        )

      assert {:ok, :filled, [%Fill{size: 1.0, price: 0.05}]} =
               Execution.simulate_fill(order, snap)
    end
  end

  describe "market sell with :amount" do
    test "budget caps revenue: receive at most $N" do
      # 3 bid levels, all at price 0.50: take min(level_size, remaining/0.50).
      snap =
        MarketSnapshot.new(
          instrument_id: "111",
          asks: [],
          bids: [{0.50, 5}, {0.50, 5}, {0.50, 5}]
        )

      order = Order.new(market_id: "111", side: :sell, order_type: :market, amount: 5.0)
      assert {:ok, :filled, fills} = Execution.simulate_fill(order, snap)
      total_revenue = Enum.reduce(fills, 0.0, fn f, acc -> acc + f.size * f.price end)
      assert_in_delta total_revenue, 5.0, 1.0e-9
    end
  end

  describe "limit sell" do
    test "fills against bids at or above the limit" do
      order =
        Order.new(market_id: "111", side: :sell, order_type: :limit, size: 30, price: 0.53)

      assert {:ok, :filled, [%Fill{size: 30, price: 0.53, side: :sell}]} =
               Execution.simulate_fill(order, snap())
    end

    test "missed when limit above best bid" do
      order =
        Order.new(market_id: "111", side: :sell, order_type: :limit, size: 5, price: 0.60)

      assert {:ok, :missed, :limit_not_crossed} = Execution.simulate_fill(order, snap())
    end
  end
end

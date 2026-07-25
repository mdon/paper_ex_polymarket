defmodule PaperExPolymarket.AdapterTest do
  use ExUnit.Case, async: true

  alias PaperEx.{Engine, Execution, Fill, Instrument, MarketSnapshot, Order, Portfolio}
  alias PaperExPolymarket.Adapter

  @clob_market %{
    "condition_id" => "0xabc",
    "question" => "Test market",
    "market_slug" => "test",
    "minimum_tick_size" => "0.01",
    "neg_risk" => false,
    "token_id" => "111",
    "tokens" => [
      %{"token_id" => "111", "outcome" => "Yes"},
      %{"token_id" => "222", "outcome" => "No"}
    ]
  }

  @clob_book %{
    "market" => "0xabc",
    "asset_id" => "111",
    "bids" => [%{"price" => "0.53", "size" => "100"}],
    "asks" => [%{"price" => "0.55", "size" => "100"}]
  }

  describe "behaviour conformance" do
    test "Adapter implements every callback" do
      assert function_exported?(Adapter, :normalize_instrument, 1)
      assert function_exported?(Adapter, :normalize_snapshot, 2)
      assert function_exported?(Adapter, :normalize_fill, 2)
      assert function_exported?(Adapter, :simulate_fill, 3)
      assert function_exported?(Adapter, :fee, 2)
      assert function_exported?(Adapter, :reason_codes, 0)
    end
  end

  describe "normalize_instrument/1" do
    test "accepts a CLOB market payload with a token_id field" do
      assert {:ok, %Instrument{id: "111", exchange: "polymarket"}} =
               Adapter.normalize_instrument(@clob_market)
    end

    test "accepts a bare token id string" do
      assert {:ok, %Instrument{id: "111"}} = Adapter.normalize_instrument("111")
    end

    test "accepts a {:token_id, id} tuple" do
      assert {:ok, %Instrument{id: "111"}} = Adapter.normalize_instrument({:token_id, "111"})
    end

    test "errors on a malformed payload" do
      assert {:error, :polymarket_invalid_market_payload} = Adapter.normalize_instrument(:bad)
    end
  end

  describe "normalize_snapshot/2" do
    test "round-trips a CLOB book payload" do
      {:ok, inst} = Adapter.normalize_instrument(@clob_market)
      assert {:ok, %MarketSnapshot{}} = Adapter.normalize_snapshot(@clob_book, inst)
    end

    test "maps OrderBook :invalid_book into a Polymarket-tagged error" do
      {:ok, inst} = Adapter.normalize_instrument(@clob_market)
      assert {:error, :polymarket_invalid_book} = Adapter.normalize_snapshot(%{}, inst)
    end
  end

  describe "normalize_fill/2" do
    test "round-trips an activity event" do
      {:ok, inst} = Adapter.normalize_instrument(@clob_market)
      event = %{"asset" => "111", "side" => "BUY", "size" => "1", "price" => "0.5"}
      assert {:ok, %Fill{side: :buy}} = Adapter.normalize_fill(event, inst)
    end

    test "maps instrument mismatch into a Polymarket-tagged error" do
      {:ok, inst} = Adapter.normalize_instrument(@clob_market)
      event = %{"asset" => "999", "side" => "BUY", "size" => "1", "price" => "0.5"}
      assert {:error, :polymarket_instrument_mismatch} = Adapter.normalize_fill(event, inst)
    end
  end

  describe "simulate_fill/3" do
    test "fills via the Polymarket-specific simulator" do
      {:ok, inst} = Adapter.normalize_instrument(@clob_market)
      {:ok, snap} = Adapter.normalize_snapshot(@clob_book, inst)
      order = Order.new(market_id: "111", side: :buy, order_type: :market, size: 5)

      assert {:ok, :filled, [%Fill{size: 5, price: 0.55, side: :buy}]} =
               Adapter.simulate_fill(order, snap, [])
    end
  end

  describe "fee/2" do
    test "defaults to zero when no fee_bps is provided" do
      fill = Fill.new(size: 10, price: 0.5, side: :buy)
      assert Adapter.fee(fill, []) == 0.0
    end

    test "applies fee_bps to notional" do
      fill = Fill.new(size: 10, price: 0.5, side: :buy)
      assert Adapter.fee(fill, fee_bps: 200) == 0.10
    end

    test "raises on a negative fee_bps (would silently improve balances)" do
      fill = Fill.new(size: 10, price: 0.5, side: :buy)

      assert_raise ArgumentError, ~r/:fee_bps/, fn ->
        Adapter.fee(fill, fee_bps: -200)
      end
    end

    test "raises on a non-numeric fee_bps" do
      fill = Fill.new(size: 10, price: 0.5, side: :buy)

      assert_raise ArgumentError, ~r/:fee_bps/, fn ->
        Adapter.fee(fill, fee_bps: "lots")
      end
    end
  end

  describe "reason_codes/0" do
    test "includes generic engine codes plus Polymarket-specific ones" do
      codes = Adapter.reason_codes()
      assert :insufficient_cash in codes
      assert :polymarket_invalid_book in codes
      assert :polymarket_invalid_market_payload in codes
      assert :polymarket_invalid_trade_payload in codes
      assert :polymarket_instrument_mismatch in codes
    end
  end

  describe "end-to-end with PaperEx.Engine" do
    test "Engine.apply_order runs through the adapter and produces a filled position" do
      {:ok, inst} = Adapter.normalize_instrument(@clob_market)
      {:ok, snap} = Adapter.normalize_snapshot(@clob_book, inst)

      portfolio = Portfolio.new(starting_balance: 100.0)
      order = Order.new(market_id: "111", side: :buy, order_type: :market, size: 5, id: "o-1")

      {p, ex} = Engine.apply_order(portfolio, order, snap, adapter: Adapter)

      assert ex.status == :filled
      assert ex.fill_price == 0.55
      assert ex.fill_size == 5
      assert_in_delta p.current_balance, 100.0 - 5 * 0.55, 1.0e-9
      assert length(p.positions) == 1
    end

    test "Engine.apply_order records a miss when the book has no liquidity" do
      {:ok, inst} = Adapter.normalize_instrument(@clob_market)
      empty_book = %{"bids" => [], "asks" => []}
      {:ok, snap} = Adapter.normalize_snapshot(empty_book, inst)

      order = Order.new(market_id: "111", side: :buy, order_type: :market, size: 5, id: "o-1")

      {_p, ex} =
        Engine.apply_order(Portfolio.new(starting_balance: 100.0), order, snap, adapter: Adapter)

      assert ex.status == :missed
      assert ex.reason == :no_liquidity
    end

    test "Engine.apply_order applies fee_bps via adapter_opts" do
      {:ok, inst} = Adapter.normalize_instrument(@clob_market)
      {:ok, snap} = Adapter.normalize_snapshot(@clob_book, inst)
      order = Order.new(market_id: "111", side: :buy, order_type: :market, size: 5, id: "o-1")

      {p, ex} =
        Engine.apply_order(Portfolio.new(starting_balance: 100.0), order, snap,
          adapter: Adapter,
          adapter_opts: [fee_bps: 200]
        )

      assert ex.status == :filled
      expected_fee = 5 * 0.55 * 200 / 10_000
      assert_in_delta Execution.total_fees(ex), expected_fee, 1.0e-9
      assert_in_delta p.current_balance, 100.0 - (5 * 0.55 + expected_fee), 1.0e-9
    end
  end
end

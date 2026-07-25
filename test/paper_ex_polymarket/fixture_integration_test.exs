defmodule PaperExPolymarket.FixtureIntegrationTest do
  @moduledoc """
  Integration tests against hand-authored realistic Polymarket CLOB /
  Data-API fixtures. See `test/fixtures/README.md` for the fixture
  shapes and why they live in this package.

  These tests exercise the adapter end-to-end against the *shape* of
  production payloads, not just minimal synthetic maps. They do not
  make network calls.
  """

  use ExUnit.Case, async: true

  alias PaperEx.{Engine, Fill, Instrument, MarketSnapshot, Order, Portfolio}
  alias PaperExPolymarket.{Adapter, Execution, Fixtures, Market, OrderBook}

  @token_id "111111111111111111111111111111111111111111111111111111111111111111"
  @condition_id "0xabc1234567890000000000000000000000000000000000000000000000000000"

  describe "Market.from_clob_market/2 against the realistic market fixture" do
    test "produces an Instrument keyed by token id with rich metadata" do
      {:ok, inst} = Market.from_clob_market(@token_id, Fixtures.clob_market())

      assert inst.id == @token_id
      assert inst.exchange == "polymarket"
      assert inst.tick_size == 0.01
      assert inst.description =~ "BTC"
      assert inst.symbol == "btc-100k-by-2026-12-31:Yes"
      assert inst.metadata.condition_id == @condition_id
      assert inst.metadata.outcome == "Yes"
      assert inst.metadata.outcome_index == 0
      assert inst.metadata.neg_risk == false
    end

    test "preserves the full raw market payload in metadata.raw_market" do
      raw = Fixtures.clob_market()
      {:ok, inst} = Market.from_clob_market(@token_id, raw)
      assert inst.metadata.raw_market == raw
    end

    test "resolves the NO token correctly when given its id" do
      no_token = "222222222222222222222222222222222222222222222222222222222222222222"
      {:ok, inst} = Market.from_clob_market(no_token, Fixtures.clob_market())
      assert inst.metadata.outcome == "No"
      assert inst.metadata.outcome_index == 1
    end
  end

  describe "Adapter.normalize_instrument/1 against the realistic market fixture" do
    test "accepts the fixture's top-level token_id field" do
      assert {:ok, %Instrument{id: @token_id}} =
               Adapter.normalize_instrument(Fixtures.clob_market())
    end
  end

  describe "OrderBook.from_clob_book/2 against the realistic book fixture" do
    setup do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())
      {:ok, snap} = OrderBook.from_clob_book(Fixtures.clob_book(), inst)
      %{inst: inst, snap: snap}
    end

    test "parses 4-level bids and asks from decimal-string payloads", %{snap: snap} do
      assert snap.instrument_id == @token_id
      assert length(snap.bids) == 4
      assert length(snap.asks) == 4
    end

    test "preserves CLOB-side ordering (bids descending, asks ascending)", %{snap: snap} do
      assert MarketSnapshot.best_bid(snap) == {0.54, 120.0}
      assert MarketSnapshot.best_ask(snap) == {0.56, 80.0}
      bid_prices = Enum.map(snap.bids, fn {p, _} -> p end)
      ask_prices = Enum.map(snap.asks, fn {p, _} -> p end)
      assert bid_prices == Enum.sort(bid_prices, :desc)
      assert ask_prices == Enum.sort(ask_prices, :asc)
    end

    test "computes midpoint and spread from the parsed top of book", %{snap: snap} do
      assert MarketSnapshot.midpoint(snap) == 0.55
      assert_in_delta MarketSnapshot.spread(snap), 0.02, 1.0e-9
    end

    test "stamps condition_id, asset_id, tick_size into snapshot metadata", %{snap: snap} do
      assert snap.metadata.condition_id == @condition_id
      assert snap.metadata.asset_id == @token_id
      assert snap.metadata.tick_size == "0.01"
    end

    test "preserves the raw book payload in metadata.raw_book", %{snap: snap} do
      assert snap.metadata.raw_book == Fixtures.clob_book()
    end

    test "snapshot as_of is parsed from the unix-second string timestamp", %{snap: snap} do
      assert snap.as_of == DateTime.from_unix!(1_714_128_000)
    end
  end

  describe "Adapter.normalize_snapshot/2 against the realistic book fixture" do
    test "delegates cleanly to OrderBook and surfaces an :ok tuple" do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())
      assert {:ok, %MarketSnapshot{}} = Adapter.normalize_snapshot(Fixtures.clob_book(), inst)
    end
  end

  describe "Execution.simulate_fill/3 against the realistic snapshot" do
    setup do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())
      {:ok, snap} = OrderBook.from_clob_book(Fixtures.clob_book(), inst)
      %{snap: snap}
    end

    test "market buy with $5 budget against 0.56-best-ask fills 5/0.56 ≈ 8.93 shares", %{
      snap: snap
    } do
      order =
        Order.new(market_id: @token_id, side: :buy, order_type: :market, amount: 5.0, id: "o-1")

      assert {:ok, :filled, [%Fill{price: 0.56} = fill]} =
               Execution.simulate_fill(order, snap)

      assert_in_delta fill.size, 5.0 / 0.56, 1.0e-9
    end

    test "market buy with $200 budget walks multiple ask levels", %{snap: snap} do
      # Level 1: 80 @ 0.56 = $44.80
      # Level 2: 150 @ 0.57 = $85.50 (running total $130.30)
      # Level 3: 300 @ 0.58 — affordable_with_$69.70 ≈ 120.17 shares = $69.70
      order = Order.new(market_id: @token_id, side: :buy, order_type: :market, amount: 200.0)

      assert {:ok, :filled, [_, _, _] = fills} = Execution.simulate_fill(order, snap)

      total = Enum.reduce(fills, 0.0, fn f, acc -> acc + f.size * f.price end)
      assert_in_delta total, 200.0, 1.0e-9
    end

    test "market sell by size walks bids descending", %{snap: snap} do
      order = Order.new(market_id: @token_id, side: :sell, order_type: :market, size: 200)

      assert {:ok, :filled, fills} = Execution.simulate_fill(order, snap)
      # Bids: 120 @ 0.54, 250 @ 0.53. Should fill 120 + 80 = 200.
      # Fixture sizes are float-typed after JSON decode, so match by price
      # and assert sizes with a delta.
      assert [%Fill{price: 0.54} = f1, %Fill{price: 0.53} = f2] = fills
      assert_in_delta f1.size, 120.0, 1.0e-9
      assert_in_delta f2.size, 80.0, 1.0e-9
    end

    test "limit buy below best ask misses with :limit_not_crossed", %{snap: snap} do
      order =
        Order.new(
          market_id: @token_id,
          side: :buy,
          order_type: :limit,
          size: 10,
          price: 0.55
        )

      assert {:ok, :missed, :limit_not_crossed} = Execution.simulate_fill(order, snap)
    end

    test "limit buy at best ask fills fully", %{snap: snap} do
      order =
        Order.new(
          market_id: @token_id,
          side: :buy,
          order_type: :limit,
          size: 50,
          price: 0.56
        )

      assert {:ok, :filled, [%Fill{price: 0.56} = fill]} =
               Execution.simulate_fill(order, snap)

      assert_in_delta fill.size, 50.0, 1.0e-9
    end

    test "limit buy that crosses two levels partially fills past the limit", %{snap: snap} do
      # Limit 0.57, want 200. Level 1 (80 @ 0.56) fills; level 2 (150 @ 0.57)
      # fills the remaining 120. Total = 200. Filled.
      order =
        Order.new(
          market_id: @token_id,
          side: :buy,
          order_type: :limit,
          size: 200,
          price: 0.57
        )

      assert {:ok, :filled, [%Fill{price: 0.56} = f1, %Fill{price: 0.57} = f2]} =
               Execution.simulate_fill(order, snap)

      assert_in_delta f1.size, 80.0, 1.0e-9
      assert_in_delta f2.size, 120.0, 1.0e-9
    end

    test "limit buy that crosses but with size exceeding crossing depth → partial", %{snap: snap} do
      # Limit 0.56, want 500. Only level 1 (80 @ 0.56) crosses. Partial = 80.
      order =
        Order.new(
          market_id: @token_id,
          side: :buy,
          order_type: :limit,
          size: 500,
          price: 0.56
        )

      assert {:ok, :partial, [%Fill{price: 0.56} = fill]} =
               Execution.simulate_fill(order, snap)

      assert_in_delta fill.size, 80.0, 1.0e-9
    end
  end

  describe "Engine.apply_order/4 end-to-end through the adapter and realistic fixtures" do
    setup do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())
      {:ok, snap} = Adapter.normalize_snapshot(Fixtures.clob_book(), inst)

      %{
        inst: inst,
        snap: snap,
        portfolio: Portfolio.new(starting_balance: 100.0)
      }
    end

    test "research-mode market buy through the adapter produces a position", %{
      snap: snap,
      portfolio: p
    } do
      order =
        Order.new(market_id: @token_id, side: :buy, order_type: :market, size: 50, id: "o-1")

      {p2, ex} = Engine.apply_order(p, order, snap, adapter: Adapter)

      assert ex.status == :filled
      assert ex.fill_price == 0.56
      assert ex.fill_size == 50
      assert_in_delta p2.current_balance, 100.0 - 50 * 0.56, 1.0e-9
      assert [%PaperEx.Position{shares: 50}] = p2.positions
    end

    test "fee_bps applies the configured take-fee on top of notional", %{snap: snap, portfolio: p} do
      order =
        Order.new(market_id: @token_id, side: :buy, order_type: :market, size: 50, id: "o-1")

      {p2, ex} =
        Engine.apply_order(p, order, snap, adapter: Adapter, adapter_opts: [fee_bps: 200])

      expected_fee = 50 * 0.56 * 200 / 10_000
      assert_in_delta PaperEx.Execution.total_fees(ex), expected_fee, 1.0e-9
      assert_in_delta p2.current_balance, 100.0 - (50 * 0.56 + expected_fee), 1.0e-9
    end
  end

  describe "Adapter.normalize_fill/2 against the realistic trade fixture" do
    test "produces a buy fill from the Data-API trade payload" do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())

      assert {:ok, %Fill{side: :buy, size: 12.5, price: 0.56} = fill} =
               Adapter.normalize_fill(Fixtures.data_api_trade(), inst)

      assert fill.metadata.tx_hash =~ "0xdeadbeef"
      assert fill.metadata.outcome == "Yes"
      assert fill.metadata.proxy_wallet == "0x1111111111111111111111111111111111111111"
    end

    test "instrument mismatch on wrong asset id is surfaced as bounded reason" do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())

      bad = Map.put(Fixtures.data_api_trade(), "asset", "999")

      assert {:error, :polymarket_instrument_mismatch} =
               Adapter.normalize_fill(bad, inst)
    end
  end

  describe "malformed payload handling" do
    test "Adapter.normalize_instrument rejects a non-map" do
      assert {:error, :polymarket_invalid_market_payload} =
               Adapter.normalize_instrument(42)
    end

    test "Adapter.normalize_snapshot rejects a book missing :bids/:asks with a bounded code" do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())
      assert {:error, :polymarket_invalid_book} = Adapter.normalize_snapshot(%{}, inst)
    end

    test "Adapter.normalize_snapshot rejects a book with a partial-parse price string" do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())

      bad_book =
        Fixtures.clob_book()
        |> Map.update!("asks", fn [first | rest] ->
          [Map.put(first, "price", "0.5x") | rest]
        end)

      assert {:error, :polymarket_invalid_book} = Adapter.normalize_snapshot(bad_book, inst)
    end

    test "snapshot with a zero-size level filters that level out" do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())

      doped_book =
        Fixtures.clob_book()
        |> Map.update!("bids", fn bids ->
          bids ++ [%{"price" => "0.10", "size" => "0"}]
        end)

      {:ok, snap} = Adapter.normalize_snapshot(doped_book, inst)
      assert length(snap.bids) == 4
      refute Enum.any?(snap.bids, fn {p, _} -> p == 0.10 end)
    end

    test "snapshot with a partial-parse timestamp falls back to now, doesn't crash" do
      before = DateTime.utc_now()
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())

      doped_book = Map.put(Fixtures.clob_book(), "timestamp", "1714128000abc")
      {:ok, snap} = Adapter.normalize_snapshot(doped_book, inst)
      assert DateTime.diff(snap.as_of, before, :second) in 0..60
    end

    test "the live CLOB millisecond-string timestamp parses (not treated as seconds)" do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())

      # Real CLOB /book sends ms as a string; treating it as seconds
      # raised `invalid Unix time` and crashed the snapshotter.
      ms_book = Map.put(Fixtures.clob_book(), "timestamp", "1781577793787")
      {:ok, snap} = Adapter.normalize_snapshot(ms_book, inst)
      assert snap.as_of == DateTime.from_unix!(1_781_577_793)
    end

    test "best bid/ask are the true best regardless of the venue's level order" do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())

      # Live CLOB ordering: bids ascending, asks descending — best
      # price LAST. The adapter must sort so the head is the best.
      book =
        Fixtures.clob_book()
        |> Map.put("bids", [
          %{"price" => "0.01", "size" => "100"},
          %{"price" => "0.28", "size" => "50"},
          %{"price" => "0.29", "size" => "30"}
        ])
        |> Map.put("asks", [
          %{"price" => "0.99", "size" => "100"},
          %{"price" => "0.33", "size" => "50"},
          %{"price" => "0.32", "size" => "40"}
        ])

      {:ok, snap} = Adapter.normalize_snapshot(book, inst)

      assert {0.29, _} = PaperEx.MarketSnapshot.best_bid(snap)
      assert {0.32, _} = PaperEx.MarketSnapshot.best_ask(snap)
      assert Enum.map(snap.bids, &elem(&1, 0)) == [0.29, 0.28, 0.01]
      assert Enum.map(snap.asks, &elem(&1, 0)) == [0.32, 0.33, 0.99]
    end

    test "an absurd integer timestamp falls back to now rather than crashing" do
      before = DateTime.utc_now()
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())

      {:ok, snap} =
        Fixtures.clob_book()
        |> Map.put("timestamp", 999_999_999_999_999_999_999)
        |> Adapter.normalize_snapshot(inst)

      assert DateTime.diff(snap.as_of, before, :second) in 0..60
    end

    test "Adapter.normalize_fill rejects a trade with a partial-parse size" do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())

      # Malformed trade *content* is remapped to the bounded adapter
      # code, not the raw ActivityMapper atom.
      bad = Map.put(Fixtures.data_api_trade(), "size", "12abc")
      assert {:error, :polymarket_invalid_trade_payload} = Adapter.normalize_fill(bad, inst)
    end
  end
end

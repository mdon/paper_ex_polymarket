defmodule PaperExPolymarket.MarketTest do
  use ExUnit.Case, async: true

  alias PaperExPolymarket.Market

  @clob_market %{
    "condition_id" => "0xabc",
    "question" => "Will BTC be over $100k by 2026-12-31?",
    "market_slug" => "btc-100k-2026",
    "minimum_tick_size" => "0.01",
    "neg_risk" => false,
    "tokens" => [
      %{"token_id" => "111", "outcome" => "Yes"},
      %{"token_id" => "222", "outcome" => "No"}
    ]
  }

  describe "from_clob_market/2" do
    test "produces an Instrument keyed by token id" do
      {:ok, inst} = Market.from_clob_market("111", @clob_market)
      assert inst.id == "111"
      assert inst.exchange == "polymarket"
    end

    test "fills tick size from minimum_tick_size" do
      {:ok, inst} = Market.from_clob_market("111", @clob_market)
      assert inst.tick_size == 0.01
    end

    test "fills description from market question" do
      {:ok, inst} = Market.from_clob_market("111", @clob_market)
      assert inst.description =~ "BTC"
    end

    test "stamps condition_id, slug, outcome label/index, neg_risk, raw_market into metadata" do
      {:ok, inst} = Market.from_clob_market("111", @clob_market)
      assert inst.metadata.condition_id == "0xabc"
      assert inst.metadata.market_slug == "btc-100k-2026"
      assert inst.metadata.outcome == "Yes"
      assert inst.metadata.outcome_index == 0
      assert inst.metadata.neg_risk == false
      assert inst.metadata.raw_market == @clob_market
    end

    test "outcome metadata is nil when token id is not in tokens list" do
      {:ok, inst} = Market.from_clob_market("999", @clob_market)
      assert inst.metadata.outcome == nil
      assert inst.metadata.outcome_index == nil
    end

    test "symbol is slug:outcome when both present" do
      {:ok, inst} = Market.from_clob_market("111", @clob_market)
      assert inst.symbol == "btc-100k-2026:Yes"
    end

    test "tick_size falls back to nil when missing" do
      {:ok, inst} = Market.from_clob_market("111", Map.delete(@clob_market, "minimum_tick_size"))
      assert inst.tick_size == nil
    end

    test "a partial-parse tick string yields nil (not a silent 0.01)" do
      {:ok, inst} =
        Market.from_clob_market("111", %{"minimum_tick_size" => "0.01abc"})

      assert inst.tick_size == nil
    end

    test "falls through to the tick_size alt key when minimum_tick_size is null" do
      {:ok, inst} =
        Market.from_clob_market("111", %{"minimum_tick_size" => nil, "tick_size" => "0.01"})

      assert inst.tick_size == 0.01
    end

    test "falls through to tick_size when minimum_tick_size is \"0\"" do
      {:ok, inst} =
        Market.from_clob_market("111", %{"minimum_tick_size" => "0", "tick_size" => "0.05"})

      assert inst.tick_size == 0.05
    end
  end

  describe "from_token_id/2" do
    test "produces a minimal Polymarket-tagged Instrument" do
      {:ok, inst} = Market.from_token_id("111")
      assert inst.id == "111"
      assert inst.exchange == "polymarket"
      assert inst.tick_size == nil
      assert inst.metadata == %{}
    end

    test "accepts symbol/description/tick_size/metadata overrides" do
      {:ok, inst} =
        Market.from_token_id("111",
          symbol: "BTC:Yes",
          description: "Will BTC be over $100k?",
          tick_size: 0.001,
          metadata: [condition_id: "0xabc"]
        )

      assert inst.symbol == "BTC:Yes"
      assert inst.tick_size == 0.001
      assert inst.metadata.condition_id == "0xabc"
    end
  end
end

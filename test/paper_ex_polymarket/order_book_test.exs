defmodule PaperExPolymarket.OrderBookTest do
  use ExUnit.Case, async: true

  alias PaperEx.{Instrument, MarketSnapshot}
  alias PaperExPolymarket.OrderBook

  defp inst, do: Instrument.new(id: "111", exchange: "polymarket")

  describe "from_clob_book/2 happy paths" do
    test "parses string-encoded prices and sizes" do
      body = %{
        "market" => "0xabc",
        "asset_id" => "111",
        "bids" => [
          %{"price" => "0.53", "size" => "100"},
          %{"price" => "0.50", "size" => "200"}
        ],
        "asks" => [
          %{"price" => "0.55", "size" => "80"},
          %{"price" => "0.56", "size" => "40"}
        ],
        "timestamp" => "1700000000",
        "tick_size" => "0.01"
      }

      assert {:ok, %MarketSnapshot{} = snap} = OrderBook.from_clob_book(body, inst())
      assert snap.instrument_id == "111"
      assert snap.bids == [{0.53, 100.0}, {0.50, 200.0}]
      assert snap.asks == [{0.55, 80.0}, {0.56, 40.0}]
      assert MarketSnapshot.best_bid(snap) == {0.53, 100.0}
      assert MarketSnapshot.best_ask(snap) == {0.55, 80.0}
    end

    test "stamps condition_id and asset_id and raw_book into metadata" do
      body = %{
        "market" => "0xabc",
        "asset_id" => "111",
        "bids" => [%{"price" => "0.53", "size" => "100"}],
        "asks" => [%{"price" => "0.55", "size" => "80"}]
      }

      {:ok, snap} = OrderBook.from_clob_book(body, inst())
      assert snap.metadata.condition_id == "0xabc"
      assert snap.metadata.asset_id == "111"
      assert snap.metadata.raw_book == body
    end

    test "accepts numeric prices and sizes (already parsed)" do
      body = %{
        "bids" => [%{"price" => 0.53, "size" => 100}],
        "asks" => [%{"price" => 0.55, "size" => 80}]
      }

      assert {:ok, snap} = OrderBook.from_clob_book(body, inst())
      assert snap.bids == [{0.53, 100.0}]
      assert snap.asks == [{0.55, 80.0}]
    end

    test "filters out zero-size levels rather than failing" do
      body = %{
        "bids" => [
          %{"price" => "0.53", "size" => "100"},
          %{"price" => "0.50", "size" => "0"}
        ],
        "asks" => []
      }

      {:ok, snap} = OrderBook.from_clob_book(body, inst())
      assert snap.bids == [{0.53, 100.0}]
    end

    test "handles empty bids/asks lists" do
      body = %{"bids" => [], "asks" => []}
      {:ok, snap} = OrderBook.from_clob_book(body, inst())
      assert snap.bids == []
      assert snap.asks == []
      assert MarketSnapshot.midpoint(snap) == nil
    end
  end

  describe "from_clob_book/2 failure paths" do
    test "errors when bids key is missing" do
      assert {:error, :invalid_book} = OrderBook.from_clob_book(%{"asks" => []}, inst())
    end

    test "errors when a level has a non-numeric price" do
      body = %{
        "bids" => [%{"price" => "notanumber", "size" => "10"}],
        "asks" => []
      }

      assert {:error, :invalid_book} = OrderBook.from_clob_book(body, inst())
    end

    test "errors when a level has a negative price" do
      body = %{
        "bids" => [%{"price" => "-0.01", "size" => "10"}],
        "asks" => []
      }

      assert {:error, :invalid_book} = OrderBook.from_clob_book(body, inst())
    end

    test "errors when a level has a negative size (does not raise through the API)" do
      # MarketSnapshot.new/1 requires size > 0 and RAISES otherwise;
      # a negative size must surface as {:error, :invalid_book}, like a
      # negative price, not crash the snapshotter.
      body = %{
        "bids" => [%{"price" => "0.50", "size" => "-10"}],
        "asks" => []
      }

      assert {:error, :invalid_book} = OrderBook.from_clob_book(body, inst())
    end
  end

  describe "strict numeric parsing" do
    test "rejects a level with a partial-parse price like '0.5x'" do
      body = %{
        "bids" => [%{"price" => "0.5x", "size" => "10"}],
        "asks" => []
      }

      assert {:error, :invalid_book} = OrderBook.from_clob_book(body, inst())
    end

    test "rejects a level with a partial-parse size like '12abc'" do
      body = %{
        "bids" => [%{"price" => "0.50", "size" => "12abc"}],
        "asks" => []
      }

      assert {:error, :invalid_book} = OrderBook.from_clob_book(body, inst())
    end

    test "rejects a level whose price has trailing whitespace" do
      body = %{
        "bids" => [%{"price" => "0.50 ", "size" => "10"}],
        "asks" => []
      }

      assert {:error, :invalid_book} = OrderBook.from_clob_book(body, inst())
    end
  end

  describe "strict timestamp parsing" do
    test "rejects '1700000000abc' as a timestamp, falls back to now" do
      before = DateTime.utc_now()

      body = %{
        "bids" => [%{"price" => "0.53", "size" => "100"}],
        "asks" => [%{"price" => "0.55", "size" => "80"}],
        "timestamp" => "1700000000abc"
      }

      {:ok, snap} = OrderBook.from_clob_book(body, inst())
      assert DateTime.diff(snap.as_of, before, :second) in 0..60
    end

    test "accepts a clean numeric-string timestamp" do
      body = %{
        "bids" => [%{"price" => "0.53", "size" => "100"}],
        "asks" => [%{"price" => "0.55", "size" => "80"}],
        "timestamp" => "1700000000"
      }

      {:ok, snap} = OrderBook.from_clob_book(body, inst())
      assert snap.as_of == DateTime.from_unix!(1_700_000_000)
    end

    test "rejects a timestamp with trailing whitespace, falls back to now" do
      before = DateTime.utc_now()

      body = %{
        "bids" => [%{"price" => "0.53", "size" => "100"}],
        "asks" => [%{"price" => "0.55", "size" => "80"}],
        "timestamp" => "1700000000 "
      }

      {:ok, snap} = OrderBook.from_clob_book(body, inst())
      assert DateTime.diff(snap.as_of, before, :second) in 0..60
    end
  end
end

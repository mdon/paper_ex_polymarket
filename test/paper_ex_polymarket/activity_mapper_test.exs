defmodule PaperExPolymarket.ActivityMapperTest do
  use ExUnit.Case, async: true

  alias PaperEx.{Fill, Instrument}
  alias PaperExPolymarket.ActivityMapper

  defp inst, do: Instrument.new(id: "111", exchange: "polymarket")

  describe "from_trade/2 happy paths" do
    test "maps a BUY trade event into a Fill" do
      event = %{
        "asset" => "111",
        "side" => "BUY",
        "size" => "10.5",
        "price" => "0.55",
        "timestamp" => 1_700_000_000,
        "transactionHash" => "0xdead",
        "outcome" => "Yes",
        "outcomeIndex" => 0,
        "pseudonym" => "TraderJoe",
        "proxyWallet" => "0xfeed"
      }

      assert {:ok, %Fill{} = fill} = ActivityMapper.from_trade(event, inst())
      assert fill.side == :buy
      assert fill.size == 10.5
      assert fill.price == 0.55
      assert fill.metadata.tx_hash == "0xdead"
      assert fill.metadata.outcome == "Yes"
      assert fill.metadata.pseudonym == "TraderJoe"
      assert fill.metadata.raw_event == event
    end

    test "maps a SELL trade event into a Fill" do
      event = %{
        "asset" => "111",
        "side" => "SELL",
        "size" => "5",
        "price" => "0.40"
      }

      assert {:ok, %Fill{side: :sell, size: 5.0, price: 0.40}} =
               ActivityMapper.from_trade(event, inst())
    end

    test "honors a MAKER liquidity hint" do
      event = %{
        "asset" => "111",
        "side" => "BUY",
        "size" => "1",
        "price" => "0.50",
        "liquidityType" => "MAKER"
      }

      assert {:ok, %Fill{liquidity: :maker}} = ActivityMapper.from_trade(event, inst())
    end

    test "parses millisecond timestamps" do
      event = %{
        "asset" => "111",
        "side" => "BUY",
        "size" => "1",
        "price" => "0.50",
        "timestamp" => 1_700_000_000_000
      }

      {:ok, fill} = ActivityMapper.from_trade(event, inst())
      assert fill.timestamp == DateTime.from_unix!(1_700_000_000)
    end

    test "instrument mismatch is reported, not silently accepted" do
      event = %{"asset" => "999", "side" => "BUY", "size" => "1", "price" => "0.5"}
      assert {:error, :instrument_mismatch} = ActivityMapper.from_trade(event, inst())
    end

    test "rejects a payload that omits any asset token id (identity enforced)" do
      # A wrong-instrument reconciliation event must NOT apply as a
      # fill: with no "asset"/"asset_id"/"token_id" the identity can't
      # be confirmed, so it's an :instrument_mismatch, not an allow.
      event = %{"side" => "BUY", "size" => "1", "price" => "0.5"}
      assert {:error, :instrument_mismatch} = ActivityMapper.from_trade(event, inst())
    end

    test "matches instrument via the asset_id / token_id fallback keys" do
      via_asset_id = %{"asset_id" => "111", "side" => "BUY", "size" => "1", "price" => "0.5"}
      via_token_id = %{"token_id" => "111", "side" => "BUY", "size" => "1", "price" => "0.5"}
      assert {:ok, %Fill{}} = ActivityMapper.from_trade(via_asset_id, inst())
      assert {:ok, %Fill{}} = ActivityMapper.from_trade(via_token_id, inst())
    end

    test "a non-binary asset (int) is a mismatch, not an allow" do
      event = %{"asset" => 111, "side" => "BUY", "size" => "1", "price" => "0.5"}
      assert {:error, :instrument_mismatch} = ActivityMapper.from_trade(event, inst())
    end
  end

  describe "from_trade/2 invalid payloads" do
    test "errors on a missing side" do
      event = %{"asset" => "111", "size" => "1", "price" => "0.5"}
      assert {:error, :invalid_side} = ActivityMapper.from_trade(event, inst())
    end

    test "errors on a zero size" do
      event = %{"asset" => "111", "side" => "BUY", "size" => "0", "price" => "0.5"}
      assert {:error, :zero_size} = ActivityMapper.from_trade(event, inst())
    end

    test "errors on a non-numeric size" do
      event = %{"asset" => "111", "side" => "BUY", "size" => "lots", "price" => "0.5"}
      assert {:error, :invalid_number} = ActivityMapper.from_trade(event, inst())
    end

    test "accepts a zero price (PaperEx.Fill allows price >= 0)" do
      event = %{"asset" => "111", "side" => "BUY", "size" => "5", "price" => "0"}
      assert {:ok, %Fill{price: +0.0, size: 5.0}} = ActivityMapper.from_trade(event, inst())
    end

    test "errors on a negative price (:invalid_number, not accepted)" do
      event = %{"asset" => "111", "side" => "BUY", "size" => "5", "price" => "-0.1"}
      assert {:error, :invalid_number} = ActivityMapper.from_trade(event, inst())
    end
  end

  describe "strict numeric parsing" do
    test "rejects '12abc' as a size (partial parse must fail)" do
      event = %{"asset" => "111", "side" => "BUY", "size" => "12abc", "price" => "0.5"}
      assert {:error, :invalid_number} = ActivityMapper.from_trade(event, inst())
    end

    test "rejects '0.5x' as a price (partial parse must fail)" do
      event = %{"asset" => "111", "side" => "BUY", "size" => "1", "price" => "0.5x"}
      assert {:error, :invalid_number} = ActivityMapper.from_trade(event, inst())
    end

    test "rejects leading whitespace" do
      event = %{"asset" => "111", "side" => "BUY", "size" => "  1.0", "price" => "0.5"}
      assert {:error, :invalid_number} = ActivityMapper.from_trade(event, inst())
    end

    test "rejects trailing whitespace" do
      event = %{"asset" => "111", "side" => "BUY", "size" => "1.0 ", "price" => "0.5"}
      assert {:error, :invalid_number} = ActivityMapper.from_trade(event, inst())
    end

    test "accepts a clean numeric string" do
      event = %{"asset" => "111", "side" => "BUY", "size" => "1.0", "price" => "0.5"}

      assert {:ok, %PaperEx.Fill{size: 1.0, price: 0.5}} =
               ActivityMapper.from_trade(event, inst())
    end

    test "accepts an integer-shaped numeric string" do
      event = %{"asset" => "111", "side" => "BUY", "size" => "5", "price" => "1"}

      assert {:ok, %PaperEx.Fill{size: 5.0, price: 1.0}} =
               ActivityMapper.from_trade(event, inst())
    end
  end

  describe "strict timestamp parsing" do
    test "rejects '1700000000abc' as a timestamp, falls back to now" do
      before = DateTime.utc_now()

      event = %{
        "asset" => "111",
        "side" => "BUY",
        "size" => "1",
        "price" => "0.5",
        "timestamp" => "1700000000abc"
      }

      assert {:ok, %PaperEx.Fill{timestamp: ts}} = ActivityMapper.from_trade(event, inst())
      # 2023-11-15 ish would be the partial-parsed timestamp; the
      # fallback must be `now`, not the 2023 timestamp.
      assert DateTime.diff(ts, before, :second) in 0..60
    end

    test "accepts a clean numeric-string timestamp" do
      event = %{
        "asset" => "111",
        "side" => "BUY",
        "size" => "1",
        "price" => "0.5",
        "timestamp" => "1700000000"
      }

      assert {:ok, %PaperEx.Fill{timestamp: ts}} = ActivityMapper.from_trade(event, inst())
      assert ts == DateTime.from_unix!(1_700_000_000)
    end

    test "rejects a timestamp with trailing whitespace, falls back to now" do
      before = DateTime.utc_now()

      event = %{
        "asset" => "111",
        "side" => "BUY",
        "size" => "1",
        "price" => "0.5",
        "timestamp" => "1700000000 "
      }

      {:ok, fill} = ActivityMapper.from_trade(event, inst())
      assert DateTime.diff(fill.timestamp, before, :second) in 0..60
    end

    test "a float timestamp yields :invalid_timestamp, not a raise" do
      event = %{
        "asset" => "111",
        "side" => "BUY",
        "size" => "1",
        "price" => "0.5",
        "timestamp" => 1.5
      }

      assert {:error, :invalid_timestamp} = ActivityMapper.from_trade(event, inst())
    end

    test "an integer timestamp in the second/millisecond gap yields :invalid_timestamp" do
      # 5e11 is > the max Unix second and < the 1e12 millisecond
      # threshold — the range that used to RAISE from from_unix!/1.
      event = %{
        "asset" => "111",
        "side" => "BUY",
        "size" => "1",
        "price" => "0.5",
        "timestamp" => 500_000_000_000
      }

      assert {:error, :invalid_timestamp} = ActivityMapper.from_trade(event, inst())
    end
  end
end

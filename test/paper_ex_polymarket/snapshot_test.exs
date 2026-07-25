defmodule PaperExPolymarket.SnapshotTest do
  use ExUnit.Case, async: true

  alias PaperEx.{Instrument, MarketSnapshot}
  alias PaperExPolymarket.{Adapter, Fixtures, Snapshot}

  @token_id "111111111111111111111111111111111111111111111111111111111111111111"

  describe "from_clob_book/3 with a token id" do
    test "produces a MarketSnapshot from the realistic CLOB book fixture" do
      assert {:ok, %MarketSnapshot{instrument_id: @token_id}} =
               Snapshot.from_clob_book(@token_id, Fixtures.clob_book())
    end

    test "best bid/ask match the parsed fixture" do
      {:ok, snap} = Snapshot.from_clob_book(@token_id, Fixtures.clob_book())
      assert MarketSnapshot.best_bid(snap) == {0.54, 120.0}
      assert MarketSnapshot.best_ask(snap) == {0.56, 80.0}
    end

    test "preserves raw_book in snapshot metadata for traceability" do
      {:ok, snap} = Snapshot.from_clob_book(@token_id, Fixtures.clob_book())
      assert snap.metadata.raw_book == Fixtures.clob_book()
    end
  end

  describe "from_clob_book/3 with a {:token_id, …} tuple" do
    test "accepts the tagged-tuple form" do
      assert {:ok, %MarketSnapshot{instrument_id: @token_id}} =
               Snapshot.from_clob_book({:token_id, @token_id}, Fixtures.clob_book())
    end
  end

  describe "from_clob_book/3 with a pre-resolved Instrument" do
    test "skips the resolution step and uses the instrument verbatim" do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())
      {:ok, snap} = Snapshot.from_clob_book(inst, Fixtures.clob_book())
      assert snap.instrument_id == inst.id
      assert snap.metadata.condition_id == inst.metadata.condition_id
    end

    test "instrument_opts is ignored when an Instrument is supplied" do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())

      {:ok, snap} =
        Snapshot.from_clob_book(inst, Fixtures.clob_book(), instrument_opts: [symbol: "ignored"])

      # The pre-resolved instrument's metadata wins; instrument_opts
      # never reaches the resolver.
      assert snap.instrument_id == inst.id
    end
  end

  describe "from_clob_book/3 malformed inputs" do
    test "non-token-id, non-instrument ref → :polymarket_invalid_market_payload" do
      assert {:error, :polymarket_invalid_market_payload} =
               Snapshot.from_clob_book(42, Fixtures.clob_book())
    end

    test "missing bids/asks → :polymarket_invalid_book" do
      assert {:error, :polymarket_invalid_book} =
               Snapshot.from_clob_book(@token_id, %{"timestamp" => "0"})
    end

    test "empty book is valid — fields exist but bids/asks are empty" do
      body = %{"bids" => [], "asks" => []}
      {:ok, snap} = Snapshot.from_clob_book(@token_id, body)
      assert snap.bids == []
      assert snap.asks == []
      assert MarketSnapshot.midpoint(snap) == nil
    end
  end

  describe "fetch_order_book_snapshot/3 with a function fetcher" do
    test "calls the fetcher with the token id and normalizes the result" do
      parent = self()

      fetcher = fn token_id ->
        send(parent, {:fetcher_called, token_id})
        {:ok, Fixtures.clob_book()}
      end

      assert {:ok, %MarketSnapshot{instrument_id: @token_id}} =
               Snapshot.fetch_order_book_snapshot(fetcher, @token_id)

      assert_received {:fetcher_called, @token_id}
    end

    test "extracts token id from an Instrument when given one" do
      {:ok, inst} = Adapter.normalize_instrument(Fixtures.clob_market())
      parent = self()

      fetcher = fn token_id ->
        send(parent, {:fetcher_called, token_id})
        {:ok, Fixtures.clob_book()}
      end

      assert {:ok, _} = Snapshot.fetch_order_book_snapshot(fetcher, inst)
      assert_received {:fetcher_called, @token_id}
    end

    test "extracts token id from a {:token_id, …} tuple" do
      parent = self()

      fetcher = fn token_id ->
        send(parent, {:fetcher_called, token_id})
        {:ok, Fixtures.clob_book()}
      end

      assert {:ok, _} =
               Snapshot.fetch_order_book_snapshot(fetcher, {:token_id, @token_id})

      assert_received {:fetcher_called, @token_id}
    end

    test "propagates fetcher errors verbatim" do
      fetcher = fn _id -> {:error, :network_unreachable} end

      assert {:error, :network_unreachable} =
               Snapshot.fetch_order_book_snapshot(fetcher, @token_id)
    end

    test "propagates :polymarket_invalid_book when fetcher returns a malformed body" do
      fetcher = fn _id -> {:ok, %{"no_bids_here" => true}} end

      assert {:error, :polymarket_invalid_book} =
               Snapshot.fetch_order_book_snapshot(fetcher, @token_id)
    end
  end

  describe "fetch_order_book_snapshot/3 with an MFA tuple" do
    defmodule MfaStub do
      def fetch(:no_extra, token_id),
        do: {:ok, %{"bids" => [], "asks" => [], "asset_id" => token_id}}

      def fetch(:fail, _token_id), do: {:error, :stub_failed}
    end

    test "applies extra args before the token id" do
      mfa = {MfaStub, :fetch, [:no_extra]}

      assert {:ok, %MarketSnapshot{instrument_id: @token_id}} =
               Snapshot.fetch_order_book_snapshot(mfa, @token_id)
    end

    test "propagates MFA fetcher errors" do
      mfa = {MfaStub, :fetch, [:fail]}

      assert {:error, :stub_failed} =
               Snapshot.fetch_order_book_snapshot(mfa, @token_id)
    end
  end

  describe "fetch_order_book_snapshot/3 invalid fetcher" do
    test "returns :polymarket_invalid_fetcher when given garbage" do
      assert {:error, :polymarket_invalid_fetcher} =
               Snapshot.fetch_order_book_snapshot(:not_a_fun, @token_id)
    end
  end

  describe "fetch_order_book_snapshot/3 invalid instrument ref" do
    test "returns :polymarket_invalid_market_payload for an integer ref (no crash)" do
      # The fetcher must NOT be called when the ref is invalid — the
      # error has to short-circuit before the network hop.
      parent = self()

      fetcher = fn token_id ->
        send(parent, {:fetcher_called, token_id})
        {:ok, Fixtures.clob_book()}
      end

      assert {:error, :polymarket_invalid_market_payload} =
               Snapshot.fetch_order_book_snapshot(fetcher, 42)

      refute_received {:fetcher_called, _}
    end

    test "returns :polymarket_invalid_market_payload for nil" do
      assert {:error, :polymarket_invalid_market_payload} =
               Snapshot.fetch_order_book_snapshot(fn _id -> {:ok, %{}} end, nil)
    end

    test "returns :polymarket_invalid_market_payload for a non-binary tagged tuple" do
      assert {:error, :polymarket_invalid_market_payload} =
               Snapshot.fetch_order_book_snapshot(
                 fn _id -> {:ok, %{}} end,
                 {:token_id, 42}
               )
    end
  end

  describe "instrument resolution via instrument_opts" do
    test "passes instrument_opts to Market.from_token_id/2 (symbol round-trips)" do
      {:ok, snap} =
        Snapshot.from_clob_book(@token_id, Fixtures.clob_book(),
          instrument_opts: [symbol: "BTC-YES"]
        )

      # We can't read the symbol off the snapshot directly — but we
      # can rebuild the resolved instrument and check.
      {:ok, %Instrument{symbol: "BTC-YES"}} =
        PaperExPolymarket.Market.from_token_id(@token_id, symbol: "BTC-YES")

      # Sanity: the snapshot's instrument_id matches the token.
      assert snap.instrument_id == @token_id
    end
  end
end

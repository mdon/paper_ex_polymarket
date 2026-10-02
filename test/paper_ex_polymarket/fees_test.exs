defmodule PaperExPolymarket.FeesTest do
  @moduledoc """
  The Polymarket taker fee curve (`shares × rate × p × (1-p)`), the maker
  exemption, category rates, and backward-compat with the flat `:fee_bps` path.
  """
  use ExUnit.Case, async: true

  alias PaperEx.Fill
  alias PaperExPolymarket.Fees

  defp fill(size, price), do: Fill.new(size: size, price: price, side: :buy)

  describe "fee/2 — Polymarket price-curved taker fee" do
    test "fee_rate applies shares × rate × p × (1-p), peaking at p = 0.5" do
      # 10 × 0.07 × 0.5 × 0.5 = 0.175  (= 1.75¢/share at 0.50)
      assert_in_delta Fees.fee(fill(10, 0.5), fee_rate: 0.07), 0.175, 1.0e-9
    end

    test "the curve vanishes toward the price extremes" do
      mid = Fees.fee(fill(10, 0.5), fee_rate: 0.07)
      edge = Fees.fee(fill(10, 0.9), fee_rate: 0.07)
      assert edge < mid
      # 10 × 0.07 × 0.9 × 0.1 = 0.063
      assert_in_delta edge, 0.063, 1.0e-9
    end

    test "maker fills are fee-free even with a fee_rate" do
      assert Fees.fee(fill(10, 0.5), fee_rate: 0.07, maker: true) == 0.0
    end

    test "fee_rate takes precedence over fee_bps" do
      assert_in_delta Fees.fee(fill(10, 0.5), fee_rate: 0.07, fee_bps: 999), 0.175, 1.0e-9
    end

    test "raises on a negative fee_rate" do
      assert_raise ArgumentError, ~r/:fee_rate/, fn -> Fees.fee(fill(10, 0.5), fee_rate: -0.07) end
    end
  end

  describe "fee/2 — backward compatibility" do
    test "defaults to zero with no opts" do
      assert Fees.fee(fill(10, 0.5), []) == 0.0
    end

    test "the flat :fee_bps path is unchanged" do
      assert Fees.fee(fill(10, 0.5), fee_bps: 200) == 0.10
    end
  end

  describe "rate_for/1" do
    test "maps categories to their CLOB v2 taker rates" do
      assert Fees.rate_for(:crypto) == 0.07
      assert Fees.rate_for(:sports) == 0.05
      assert Fees.rate_for(:finance) == 0.04
      assert Fees.rate_for(:politics) == 0.04
      assert Fees.rate_for(:mentions) == 0.04
      assert Fees.rate_for(:tech) == 0.04
      assert Fees.rate_for(:economics) == 0.05
      assert Fees.rate_for(:other) == 0.05
      assert Fees.rate_for(:geopolitics) == 0.0
      assert Fees.rate_for(:world) == 0.0
    end

    test "unknown categories default to the 'other' catch-all rate (0.05), not zero" do
      assert Fees.rate_for(:some_new_category) == 0.05
    end
  end

  describe "reproduces Polymarket's published max-fee-per-100-shares (at p = 0.5)" do
    test "crypto $1.75, sports $1.25, finance/politics $1.00" do
      assert_in_delta Fees.fee(fill(100, 0.5), fee_rate: Fees.rate_for(:crypto)), 1.75, 1.0e-9
      assert_in_delta Fees.fee(fill(100, 0.5), fee_rate: Fees.rate_for(:sports)), 1.25, 1.0e-9
      assert_in_delta Fees.fee(fill(100, 0.5), fee_rate: Fees.rate_for(:politics)), 1.00, 1.0e-9
      assert Fees.fee(fill(100, 0.5), fee_rate: Fees.rate_for(:geopolitics)) == 0.0
    end
  end
end

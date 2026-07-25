defmodule PaperExPolymarket.Fees do
  @moduledoc """
  Polymarket fee helpers.

  Polymarket's CLOB v2 changed the fee model: per-order
  `feeRateBps` is gone; trade-time fees are not charged. The fee
  surface lives on profit at resolution and in optional take-fees
  that depend on market metadata.

  For paper-trading purposes this module exposes a single bps-based
  fee helper that callers can plug into
  `PaperExPolymarket.Adapter.fee/2` via `:fee_bps` in
  `:adapter_opts`. Defaulting to **zero** is the honest answer for
  most paper-mode trades. Research that wants to model a worst-case
  take-fee can pass an explicit bps value.

  ## Why not auto-fetch fees

  Fetching live market fee data is a network call and a strategy
  decision (what fee bucket to assume). This adapter is offline; it
  takes the caller's stated assumption via opts and applies it
  deterministically.
  """

  alias PaperEx.Fill

  @doc """
  Returns the fee in quote currency for a `Fill` given an opts
  keyword. Looks up `:fee_bps` (basis points, non-negative integer or
  float). Defaults to `0`.

  Raises `ArgumentError` if `:fee_bps` is negative or non-numeric.
  A negative fee would silently *improve* balances/PnL — the engine
  applies the fee via a struct update that bypasses `PaperEx.Fill`'s
  non-negative validation — so it is rejected here at the boundary.
  """
  @spec fee(Fill.t(), keyword()) :: number()
  def fee(%Fill{} = fill, opts) do
    bps = validate_bps!(Keyword.get(opts, :fee_bps, 0))
    fill.size * fill.price * bps / 10_000
  end

  defp validate_bps!(bps) when is_number(bps) and bps >= 0, do: bps

  defp validate_bps!(other) do
    raise ArgumentError,
          ":fee_bps must be a non-negative number, got: #{inspect(other)}"
  end
end

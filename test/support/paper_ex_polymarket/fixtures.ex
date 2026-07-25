defmodule PaperExPolymarket.Fixtures do
  @moduledoc """
  Test-only helpers for loading the hand-authored CLOB / Data-API
  fixtures under `test/fixtures/`.

  Not compiled into the library — lives under `test/support`.
  """

  @fixture_dir Path.expand("../../fixtures", __DIR__)

  @doc "Loads `clob_market.json` as a decoded map."
  @spec clob_market() :: map()
  def clob_market, do: load!("clob_market.json")

  @doc "Loads `clob_book.json` as a decoded map."
  @spec clob_book() :: map()
  def clob_book, do: load!("clob_book.json")

  @doc "Loads `data_api_trade.json` as a decoded map."
  @spec data_api_trade() :: map()
  def data_api_trade, do: load!("data_api_trade.json")

  defp load!(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end

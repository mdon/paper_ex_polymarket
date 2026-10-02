defmodule PaperExPolymarket.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/mdon/paper_ex_polymarket"

  def project do
    [
      app: :paper_ex_polymarket,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "PaperExPolymarket",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "Adapter between paper_ex (generic paper trading) and polymarket (Polymarket SDK). " <>
      "Translates Polymarket CLOB books, market metadata, and trade activity into " <>
      "the normalized paper_ex domain. Not a trading bot."
  end

  defp package do
    # `AGENTS.md` and `PACKAGE_PLAN.md` are intentionally excluded:
    # internal AI/dev-process planning notes, not authoritative for
    # users of the library.
    [
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      main: "PaperExPolymarket",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md"
      ]
    ]
  end

  defp deps do
    # Path deps day-to-day; HEX_BUILD=1 switches them to Hex
    # requirements for `mix hex.build`/`mix hex.publish` (publish
    # paper_ex and polymarket_sdk first).
    [
      workspace_dep(:paper_ex, "~> 0.7"),
      workspace_dep(:polymarket_sdk, "~> 0.2"),
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # Hex forbids path dependencies in published packages.
  defp workspace_dep(name, requirement) do
    if System.get_env("HEX_BUILD") do
      {name, requirement}
    else
      {name, requirement, path: "../#{name}"}
    end
  end
end

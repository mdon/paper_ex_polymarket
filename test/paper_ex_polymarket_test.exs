defmodule PaperExPolymarketTest do
  use ExUnit.Case, async: true

  test "version/0 returns a non-empty string" do
    version = PaperExPolymarket.version()
    assert is_binary(version)
    assert version != ""
  end

  test "depends on paper_ex (PaperEx is loadable)" do
    # Sanity-check that the path dep resolved and the generic engine's
    # top-level module is reachable from this package.
    assert Code.ensure_loaded?(PaperEx)
    assert function_exported?(PaperEx, :version, 0)
  end

  test "depends on polymarket (Polymarket is loadable)" do
    assert Code.ensure_loaded?(Polymarket)
    assert function_exported?(Polymarket, :version, 0)
  end
end

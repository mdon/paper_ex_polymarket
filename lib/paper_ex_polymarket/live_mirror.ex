defmodule PaperExPolymarket.LiveMirror do
  @moduledoc """
  Polymarket-specific live-mirror helpers built on top of
  `PaperEx.Engine`.

  Live mirroring answers a different question than research-mode
  simulation: *"what likely would have happened to this order under
  the real exchange's fill, sizing, and exit rules?"*. The `paper_ex`
  engine already records `:filled` / `:missed` / `:skipped` outcomes;
  live-mirror also needs to reconcile against actual Polymarket fills
  when they arrive, and to track resting orders explicitly at the
  Polymarket level.

  All cash and position accounting is delegated to `PaperEx.Engine`
  (`apply_order/4` for intents, `apply_fill/4` for observed fills) —
  this module never reimplements portfolio math, so short cover/flip,
  partial-close P&L, and fee handling stay identical to the engine.

  This module wraps four live-mirror flows:

    * `simulate_intent/4` — record what the engine *would* do against
      the current book. Stamps `:mode = :live_mirror` on the execution
      metadata. Use this when you have an intent and a snapshot but no
      actual fill yet.
    * `mirror_actual_fill/4` — record an *observed* exchange fill (from
      the Data API `/activity` endpoint or the RTDS WebSocket) as a
      `:filled` execution on the mirror portfolio, applied through
      `PaperEx.Engine.apply_fill/4`. Use this when reconciling the
      mirror against real exchange behavior.
    * `record_pending/3` — record a `:pending` execution for a resting
      order and later move it to `:filled` or `:cancelled` via
      `resolve_pending/4`. This is a Polymarket-level, caller-driven
      pending marker; it is separate from the generic engine's own
      `:pending_remainder` lifecycle (`PaperEx.Engine.advance_pending/3`,
      `cancel_pending/3`, `open_pending_remainders/1`) and does not feed
      into it.
    * `resolve_pending/4` — resolve a `record_pending/3` entry to
      `:filled` or `:cancelled`. Idempotent: a pending that has already
      been resolved cannot be resolved again (returns
      `{:error, :pending_already_resolved}`), so a duplicate event can't
      double-book cash or positions.

  ## Mirror portfolios exist before the first fill

  Callers should seed a mirror `Portfolio` at startup, not lazily on
  the first fill. The execution-attempt ledger is the authoritative
  record of *what was attempted*, regardless of whether any of those
  attempts succeeded. Constructing the portfolio late means losing
  misses and skips that happened before the first fill — which is
  exactly the information live-mirror exists to expose.

  ## Token resolution before reconciliation

  The functions that consume a raw Polymarket trade event take an
  already-resolved `PaperEx.Instrument`, not a raw token id or condition
  id: `mirror_actual_fill/4` as a positional argument, and
  `resolve_pending/4` via the `:instrument` opt when a `:trade_event` is
  supplied. (`simulate_intent/4` works off the snapshot, and
  `record_pending/3` needs only the order.) Callers should resolve the
  instrument once (via `PaperExPolymarket.Adapter.normalize_instrument/1`
  or `PaperExPolymarket.Market.from_clob_market/2`) and hold it for the
  duration of the order's lifecycle.
  """

  alias PaperEx.{Engine, Execution, Fill, Instrument, MarketSnapshot, Order, Portfolio}
  alias PaperExPolymarket.{ActivityMapper, Adapter}

  @doc """
  Run `order` against `snapshot` through `PaperEx.Engine` with the
  Polymarket adapter and `:mode = :live_mirror` recorded on the
  execution metadata.

  Returns `{updated_portfolio, execution}` exactly like
  `PaperEx.Engine.apply_order/4`.
  """
  @spec simulate_intent(Portfolio.t(), Order.t(), MarketSnapshot.t(), keyword()) ::
          {Portfolio.t(), Execution.t()}
  def simulate_intent(
        %Portfolio{} = portfolio,
        %Order{} = order,
        %MarketSnapshot{} = snap,
        opts \\ []
      ) do
    cfg =
      opts
      |> Keyword.put_new(:adapter, Adapter)
      |> Keyword.put(:mode, :live_mirror)

    Engine.apply_order(portfolio, order, snap, cfg)
  end

  @doc """
  Record an actual exchange trade event as a `:filled` execution on
  `portfolio`. Cash and positions are updated by
  `PaperEx.Engine.apply_fill/4`, so the observed fill goes through the
  same accounting a simulated fill would (open / average-in /
  reduce-cover / flip).

  `trade_event` is a Polymarket Data-API activity payload or an RTDS
  trade payload. The event's asset token id must match `instrument.id`
  or the call returns `{portfolio, {:error, reason}}` (e.g.
  `{:error, :instrument_mismatch}`) with no state change.
  """
  @spec mirror_actual_fill(Portfolio.t(), Order.t(), map(), Instrument.t()) ::
          {Portfolio.t(), Execution.t()} | {Portfolio.t(), {:error, atom()}}
  def mirror_actual_fill(
        %Portfolio{} = portfolio,
        %Order{} = order,
        %{} = trade_event,
        %Instrument{} = inst
      ) do
    case ActivityMapper.from_trade(trade_event, inst) do
      {:ok, %Fill{} = fill} ->
        Engine.apply_fill(portfolio, order, [fill],
          mode: :live_mirror,
          execution_metadata: %{
            source: :actual_fill,
            instrument_id: inst.id,
            raw_event: trade_event
          }
        )

      {:error, reason} ->
        {portfolio, {:error, reason}}
    end
  end

  @doc """
  Record a `:pending` execution for a resting `order`. Cash and
  positions are not moved (the engine cannot know whether the order
  will fill or be cancelled).

  Returns `{updated_portfolio, execution}`. The returned execution
  carries a caller-provided `:id` (defaulting to `order.id`) so a later
  `resolve_pending/4` can find it.

  Polymarket-specific `:reason` and `:metadata` defaults:

    * `:reason` — `:resting_gtc` (a GTC order placed but not yet filled).
    * `:metadata.mode` — `:live_mirror`.
    * `:metadata.placed_at` — `order.placed_at`.
  """
  @spec record_pending(Portfolio.t(), Order.t(), keyword()) :: {Portfolio.t(), Execution.t()}
  def record_pending(%Portfolio{} = portfolio, %Order{} = order, opts \\ []) do
    execution_id = Keyword.get(opts, :id, order.id)

    execution =
      Execution.new(
        id: execution_id,
        order_id: order.id,
        status: :pending,
        metadata: %{
          market_id: order.market_id,
          mode: :live_mirror,
          placed_at: order.placed_at,
          reason: Keyword.get(opts, :reason, :resting_gtc)
        }
      )

    {%{portfolio | executions: portfolio.executions ++ [execution]}, execution}
  end

  @doc """
  Resolve a previously-recorded `:pending` execution.

  `outcome` is one of `:filled` or `:cancelled`.

  For `:filled`, `opts` must include `:order` (the resting order, whose
  `:id` must match the pending's `:order_id`) and either a `:trade_event`
  map (plus `:instrument`) or a `:fill` `PaperEx.Fill` struct. The fill
  is applied through `PaperEx.Engine.apply_fill/4`; the original
  `:pending` execution is left on the ledger and a new `:filled`
  execution is appended.

  For `:cancelled`, `opts[:reason]` is the bounded reason atom
  (`:cancelled_by_caller`, `:cancelled_by_exchange`, etc.).

  Idempotent: once a pending has been resolved, resolving it again
  returns `{portfolio, {:error, :pending_already_resolved}}` with no
  state change. An unknown id returns `{:error, :pending_not_found}`.
  """
  @spec resolve_pending(Portfolio.t(), term(), :filled | :cancelled, keyword()) ::
          {Portfolio.t(), Execution.t()} | {Portfolio.t(), {:error, atom()}}
  def resolve_pending(%Portfolio{} = portfolio, execution_id, :filled, opts) do
    case pending_status(portfolio, execution_id) do
      {:pending, pending} ->
        with {:ok, order} <- fetch_order(opts),
             :ok <- check_binding(order, pending),
             {:ok, %Fill{} = fill} <- resolve_fill(opts) do
          Engine.apply_fill(portfolio, order, [fill],
            mode: :live_mirror,
            execution_metadata: %{source: :resolved_pending, resolved_from: execution_id}
          )
        else
          {:error, reason} -> {portfolio, {:error, reason}}
        end

      other ->
        {portfolio, {:error, other}}
    end
  end

  def resolve_pending(%Portfolio{} = portfolio, execution_id, :cancelled, opts) do
    case pending_status(portfolio, execution_id) do
      {:pending, pending} ->
        execution =
          Execution.new(
            order_id: pending.order_id,
            status: :cancelled,
            reason: Keyword.get(opts, :reason, :cancelled_by_caller),
            metadata: %{
              mode: :live_mirror,
              resolved_from: execution_id,
              source: :resolved_pending
            }
          )

        {%{portfolio | executions: portfolio.executions ++ [execution]}, execution}

      other ->
        {portfolio, {:error, other}}
    end
  end

  # Classify a pending id: `{:pending, execution}` when it exists and has
  # not yet been resolved, `:pending_already_resolved` when a later
  # `:filled`/`:cancelled` already resolved it (idempotency guard), or
  # `:pending_not_found` when no such `:pending` exists.
  defp pending_status(%Portfolio{executions: list}, execution_id) do
    cond do
      Enum.any?(list, &resolves?(&1, execution_id)) ->
        :pending_already_resolved

      pending = Enum.find(list, &pending_with_id?(&1, execution_id)) ->
        {:pending, pending}

      true ->
        :pending_not_found
    end
  end

  defp pending_with_id?(%Execution{id: id, status: :pending}, execution_id), do: id == execution_id
  defp pending_with_id?(_, _), do: false

  defp resolves?(%Execution{status: status, metadata: meta}, execution_id)
       when status in [:filled, :cancelled],
       do: Map.get(meta, :resolved_from) == execution_id

  defp resolves?(_, _), do: false

  defp fetch_order(opts) do
    case Keyword.fetch(opts, :order) do
      {:ok, %Order{} = order} -> {:ok, order}
      {:ok, _} -> {:error, :invalid_order}
      :error -> {:error, :order_required}
    end
  end

  # The resolving order must be the one that opened the pending.
  defp check_binding(%Order{id: id}, %Execution{order_id: order_id}) do
    if id == order_id, do: :ok, else: {:error, :order_pending_mismatch}
  end

  defp resolve_fill(opts) do
    cond do
      Keyword.has_key?(opts, :fill) ->
        case Keyword.get(opts, :fill) do
          %Fill{} = fill -> {:ok, fill}
          _ -> {:error, :invalid_fill}
        end

      Keyword.has_key?(opts, :trade_event) ->
        case Keyword.get(opts, :instrument) do
          %Instrument{} = inst ->
            ActivityMapper.from_trade(Keyword.get(opts, :trade_event), inst)

          _ ->
            {:error, :instrument_required_for_trade_event}
        end

      true ->
        {:error, :fill_or_trade_event_required}
    end
  end
end

defmodule TuningFork.Application do
  @moduledoc false

  use Application

  alias TuningFork.Sample.Fetch

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: TuningFork.Supervisor)
  end

  defp children do
    [
      TuningFork.Store,
      TuningFork.Sample.Bank,
      TuningFork.Sample.Font,
      {DynamicSupervisor, name: TuningFork.StageSupervisor, strategy: :one_for_one}
    ] ++ Fetch.child_specs() ++ configured_stage()
  end

  defp configured_stage do
    case Application.get_env(:tuning_fork, :stage) do
      nil -> []
      opts -> [{TuningFork.Stage, opts}]
    end
  end
end

defmodule TuningFork.Samples.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    TuningFork.Samples.register()
    Supervisor.start_link([], strategy: :one_for_one, name: TuningFork.Samples.Supervisor)
  end
end

defmodule KinoTuningFork.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Kino.SmartCell.register(KinoTuningFork.ComposerCell)
    Kino.SmartCell.register(KinoTuningFork.MidiCell)
    Kino.SmartCell.register(KinoTuningFork.LivePatternsCell)
    Kino.SmartCell.register(KinoTuningFork.LiveLoopsCell)

    Supervisor.start_link([], strategy: :one_for_one, name: KinoTuningFork.Supervisor)
  end
end

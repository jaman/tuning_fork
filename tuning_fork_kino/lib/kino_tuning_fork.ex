defmodule KinoTuningFork do
  @moduledoc """
  TuningFork in a notebook: a stage heard in the browser, and the smart cells.

      KinoTuningFork.stage()
  """

  @doc "Start a stage heard in the browser. `opts` are `KinoTuningFork.Stage.new/1`'s."
  @spec stage(keyword()) :: Kino.JS.Live.t()
  def stage(opts \\ []), do: KinoTuningFork.Stage.new(opts)
end

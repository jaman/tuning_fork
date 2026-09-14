defmodule TuningFork.DoctestsTest do
  use ExUnit.Case, async: true

  doctest TuningFork.Chord
  doctest TuningFork.Envelope
  doctest TuningFork.Midi
  doctest TuningFork.Mixer
  doctest TuningFork.Source
  doctest TuningFork.Stage
  doctest TuningFork.State
  doctest TuningFork.Tick
  doctest TuningFork.Transport
  doctest TuningFork.Voice
end

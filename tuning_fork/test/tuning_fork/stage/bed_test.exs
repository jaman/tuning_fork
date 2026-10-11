defmodule TuningFork.Stage.BedTest do
  use ExUnit.Case, async: true

  alias TuningFork.Stage.Bed

  defp ramp(frames), do: for(value <- 1..frames, into: <<>>, do: <<value::16-signed-little>>)
  defp samples(pcm), do: for(<<s::16-signed-little <- pcm>>, do: s)

  test "a layer added from its start reads its own beginning while the others play on" do
    bed = Bed.replace(nil, %{a: ramp(100)}, [])
    {_first, bed} = Bed.chunk(bed, 10, 1)

    bed = Bed.replace(bed, %{b: ramp(100)}, keep: true, from_start: true, gains: %{b: 1.0})
    bed = Bed.gains(bed, %{a: 0.0})
    {from_b, bed} = Bed.chunk(bed, 3, 1)
    assert samples(from_b) == [1, 2, 3]

    bed = bed |> Bed.gains(%{a: 1.0}) |> Bed.drop([:b])
    {from_a, _bed} = Bed.chunk(bed, 3, 1)
    assert samples(from_a) == [14, 15, 16]
  end
end

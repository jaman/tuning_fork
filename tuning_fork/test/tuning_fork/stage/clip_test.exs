defmodule TuningFork.Stage.ClipTest do
  use ExUnit.Case, async: true

  alias TuningFork.Stage.Clip

  doctest Clip

  defp pcm(values), do: for(v <- values, into: <<>>, do: <<v::16-signed-little>>)
  defp samples(binary), do: for(<<s::16-signed-little <- binary>>, do: s)

  test "a clip is read a chunk at a time and is done when its PCM runs out" do
    clip = Clip.new(pcm([1, 2, 3]))

    assert {first, clip} = Clip.take(clip, 2)
    assert samples(first) == [1, 2]
    assert {last, :done} = Clip.take(clip, 2)
    assert samples(last) == [3]
  end

  test "a released clip falls in a straight line to silence over the frames given" do
    clip = pcm(List.duplicate(1_000, 10)) |> Clip.new() |> Clip.release(4)

    assert {faded, :done} = Clip.take(clip, 10)
    assert samples(faded) == [1_000, 750, 500, 250]
  end

  test "releasing a falling clip starts the new fall from where it had reached" do
    clip = pcm(List.duplicate(1_000, 10)) |> Clip.new() |> Clip.release(4)
    {_half, clip} = Clip.take(clip, 2)

    assert {faded, :done} = Clip.take(Clip.release(clip, 2), 10)
    assert samples(faded) == [500, 250]
  end
end

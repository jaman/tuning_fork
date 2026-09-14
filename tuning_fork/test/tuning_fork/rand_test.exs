defmodule TuningFork.RandTest do
  use ExUnit.Case, async: true

  import TuningFork.Part

  alias TuningFork.{Notes, Part, Rand, Voice}

  describe "the generator" do
    test "the same seed gives the same run" do
      one = Rand.new(42) |> stream(20)
      two = Rand.new(42) |> stream(20)

      assert one == two
    end

    test "different seeds give different runs" do
      refute Rand.new(1) |> stream(20) == Rand.new(2) |> stream(20)
    end

    test "numbers stay between 0 and 1" do
      assert Enum.all?(stream(Rand.new(7), 200), &(&1 >= 0.0 and &1 < 1.0))
    end

    test "a range is respected" do
      {values, _rand} =
        Enum.map_reduce(1..100, Rand.new(3), fn _n, acc -> Rand.int(acc, 5, 10) end)

      assert Enum.all?(values, &(&1 >= 5 and &1 <= 10))
      assert 5 in values and 10 in values
    end

    test "picking takes from the list and nothing else" do
      notes = [:a3, :c4, :e4]

      {picked, _rand} =
        Enum.map_reduce(1..50, Rand.new(9), fn _n, acc -> Rand.pick(acc, notes) end)

      assert Enum.all?(picked, &(&1 in notes))
      assert length(Enum.uniq(picked)) > 1
    end

    test "picking from nothing gives nothing rather than failing" do
      assert {nil, _rand} = Rand.pick(Rand.new(1), [])
    end

    test "a chance of one always happens and zero never does" do
      assert {true, _} = Rand.chance(Rand.new(1), 1.0)
      assert {false, _} = Rand.chance(Rand.new(1), 0.0)
    end

    test "one_in is about that often" do
      {hits, _rand} =
        Enum.map_reduce(1..1_000, Rand.new(11), fn _n, acc -> Rand.one_in(acc, 4) end)

      count = Enum.count(hits, & &1)
      assert count > 180 and count < 320, "expected roughly a quarter, got #{count}"
    end

    test "shuffling keeps everything and usually moves it" do
      list = Enum.to_list(1..20)
      {shuffled, _rand} = Rand.shuffle(Rand.new(5), list)

      assert Enum.sort(shuffled) == list
      refute shuffled == list
    end
  end

  describe "a part that makes choices" do
    test "the same seed writes the same part" do
      assert notes_of(generative(1)) == notes_of(generative(1))
    end

    test "a different seed writes a different part" do
      refute notes_of(generative(1)) == notes_of(generative(2))
    end

    test "chosen notes come from the list it was given" do
      scale = Notes.scale(:a3, :minor_pentatonic)
      allowed = Enum.map(scale, &Notes.freq/1)

      played =
        part(seed: 3, synth: Voice.new())
        |> repeat(30, &play_any(&1, scale, 0.25))
        |> Part.notes()
        |> Enum.map(fn {_beat, voice} -> voice.freq end)

      assert Enum.all?(played, fn freq -> Enum.any?(allowed, &(abs(&1 - freq) < 0.001)) end)
    end

    test "maybe sometimes plays and always moves on" do
      played =
        part(seed: 4, synth: Voice.new())
        |> repeat(40, &maybe(&1, 0.5, fn p -> play(p, :a4, 0.0) end, 1.0))

      count = length(Part.notes(played))

      assert count > 5 and count < 35, "expected about half of forty, got #{count}"
      assert cursor(played) == 40.0
    end

    test "a gain between two values differs from note to note" do
      gains =
        part(seed: 6, synth: Voice.new(gain: 1.0))
        |> repeat(20, &play(&1, :a4, 0.25, gain: {:between, 0.1, 1.0}))
        |> Part.notes()
        |> Enum.map(fn {_beat, voice} -> voice.gain end)

      assert length(Enum.uniq(gains)) > 10
      assert Enum.all?(gains, &(&1 >= 0.1 and &1 <= 1.0))
    end
  end

  defp generative(seed) do
    part(seed: seed, synth: Voice.new())
    |> repeat(20, &play_any(&1, Notes.scale(:eb2, :major_pentatonic, octaves: 3), 0.1))
  end

  defp notes_of(part), do: part |> Part.notes() |> Enum.map(fn {beat, v} -> {beat, v.freq} end)

  defp stream(rand, count) do
    {values, _rand} = Enum.map_reduce(1..count, rand, fn _n, acc -> Rand.next(acc) end)
    values
  end
end

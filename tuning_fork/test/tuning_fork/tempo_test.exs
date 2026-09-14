defmodule TuningFork.TempoTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Envelope, Mixer, Score, Voice}

  @rate 44_100

  describe "a score at one tempo" do
    test "the map is just where it started" do
      assert Score.tempo_map(Score.new(bpm: 120)) == [{0.0, 120.0}]
    end

    test "beats convert as they always did" do
      score = Score.new(bpm: 120, beats: 8)

      assert Score.beat_to_seconds(score, 0) == 0.0
      assert Score.beat_to_seconds(score, 2) == 1.0
      assert Score.beat_to_seconds(score, 8) == 4.0
      assert Score.duration(score) == 4.0
    end

    test "seconds convert back" do
      score = Score.new(bpm: 120, beats: 8)

      assert Score.seconds_to_beat(score, 0.0) == 0.0
      assert Score.seconds_to_beat(score, 1.0) == 2.0
      assert Score.seconds_to_beat(score, 4.0) == 8.0
    end
  end

  describe "a score that changes speed" do
    setup do
      {:ok, score: Score.new(bpm: 120, beats: 8) |> Score.tempo(4, 60)}
    end

    test "the map holds both", %{score: score} do
      assert Score.tempo_map(score) == [{0.0, 120.0}, {4.0, 60.0}]
    end

    test "beats before the change are unaffected", %{score: score} do
      assert Score.beat_to_seconds(score, 0) == 0.0
      assert Score.beat_to_seconds(score, 2) == 1.0
      assert Score.beat_to_seconds(score, 4) == 2.0
    end

    test "beats after it run at the new speed", %{score: score} do
      assert Score.beat_to_seconds(score, 5) == 3.0
      assert Score.beat_to_seconds(score, 8) == 6.0
    end

    test "the score is as long as the map says, not as the starting tempo would", %{score: score} do
      assert Score.duration(score) == 6.0
      refute Score.duration(score) == 8 * 60.0 / 120.0
    end

    test "seconds convert back through the change", %{score: score} do
      for beat <- [0.0, 1.5, 4.0, 4.5, 7.9] do
        seconds = Score.beat_to_seconds(score, beat)

        assert_in_delta Score.seconds_to_beat(score, seconds), beat, 0.0001
      end
    end

    test "several changes stack up" do
      score =
        Score.new(bpm: 60, beats: 12)
        |> Score.tempo(4, 120)
        |> Score.tempo(8, 240)

      assert Score.beat_to_seconds(score, 4) == 4.0
      assert Score.beat_to_seconds(score, 8) == 6.0
      assert Score.beat_to_seconds(score, 12) == 7.0
    end

    test "changes given out of order are sorted" do
      score = Score.new(bpm: 60, beats: 12) |> Score.tempo(8, 240) |> Score.tempo(4, 120)

      assert Score.tempo_map(score) == [{0.0, 60.0}, {4.0, 120.0}, {8.0, 240.0}]
    end

    test "a second change at the same beat replaces the first" do
      score = Score.new(bpm: 60) |> Score.tempo(4, 120) |> Score.tempo(4, 180)

      assert Score.tempo_map(score) == [{0.0, 60.0}, {4.0, 180.0}]
    end

    test "a change at beat zero is the starting tempo rather than a segment of no length" do
      score = Score.new(bpm: 120) |> Score.tempo(0, 90)

      assert Score.tempo_map(score) == [{0.0, 90.0}]
      assert Score.beat_to_seconds(score, 2) == 2 * 60.0 / 90.0
    end
  end

  describe "rendering through a tempo change" do
    test "the buffer is as long as the tempo map says" do
      score = Score.new(bpm: 120, beats: 8) |> Score.tempo(4, 60)

      assert byte_size(Score.render(score, @rate)) == trunc(6.0 * @rate) * 4
    end

    test "a note lands where the changed tempo puts it, not where the old one would" do
      voice = Voice.new(shape: :sine, freq: 440.0, envelope: Envelope.hit(0.2), gain: 0.9)

      pcm =
        Score.new(bpm: 120, beats: 8)
        |> Score.tempo(4, 60)
        |> Score.add(6.0, voice)
        |> Score.render(@rate, channels: 1)

      {before, from_note} = Mixer.take(pcm, trunc(3.9 * @rate), 1)

      refute loud?(before)
      assert loud?(binary_part(from_note, 0, trunc(0.3 * @rate) * 2))
    end

    test "changes can be given to new/1 and from_parts/2 rather than added afterwards" do
      direct = Score.new(bpm: 120, beats: 8, changes: [{4, 60}])
      built = Score.new(bpm: 120, beats: 8) |> Score.tempo(4, 60)

      assert Score.tempo_map(direct) == Score.tempo_map(built)

      from_parts =
        Score.from_parts([TuningFork.Part.part(bpm: 120)], beats: 8, changes: [{4, 60}])

      assert Score.tempo_map(from_parts) == [{0.0, 120.0}, {4.0, 60.0}]
    end
  end

  describe "one score, one tempo" do
    test "parts written at different tempos are refused rather than played at the first one's" do
      slow = TuningFork.Part.part(bpm: 60)
      quick = TuningFork.Part.part(bpm: 120)

      assert_raise ArgumentError, ~r/one tempo.*60.*120/s, fn ->
        Score.from_parts([slow, quick])
      end
    end

    test "parts that agree are mixed as they always were" do
      parts = [TuningFork.Part.part(bpm: 90), TuningFork.Part.part(bpm: 90)]

      assert Score.from_parts(parts, beats: 4).bpm == 90.0
    end

    test "no parts at all still gives a score rather than raising" do
      assert Score.from_parts([], beats: 4).bpm == 120.0
    end
  end

  describe "repeating a voice" do
    test "a step of zero is refused rather than never finishing" do
      score = Score.new(bpm: 120, beats: 8)
      voice = Voice.new(shape: :sine, envelope: Envelope.hit(0.1))

      assert_raise ArgumentError, ~r/step greater than zero/, fn ->
        Score.repeat(score, 0, 0, voice)
      end

      assert_raise ArgumentError, ~r/step greater than zero/, fn ->
        Score.repeat(score, 0, -1, voice)
      end
    end

    test "a positive step places a voice on each of them" do
      score =
        Score.new(bpm: 120, beats: 8)
        |> Score.repeat(0, 2, Voice.new(shape: :sine, envelope: Envelope.hit(0.1)))

      assert length(score.notes) == 4
    end
  end

  defp loud?(pcm) do
    pcm |> then(&for(<<s::16-signed-little <- &1>>, do: abs(s))) |> Enum.max(fn -> 0 end) > 500
  end
end

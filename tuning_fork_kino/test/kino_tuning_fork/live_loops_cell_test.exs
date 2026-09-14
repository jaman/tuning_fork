defmodule KinoTuningFork.LiveLoopsCellTest do
  @moduledoc """
  Drives `KinoTuningFork.LiveLoopsCell` as Livebook does and asserts on what the browser is
  sent.
  """

  use ExUnit.Case, async: false

  import Kino.Test

  alias KinoTuningFork.LiveLoopsCell
  alias TuningFork.Mixer
  alias TuningFork.Part.Source

  setup :configure_livebook_bridge

  @drums """
  part(bpm: 120, synth: TuningFork.Voice.new(shape: :saw))
  |> steps("x...x...x...x...")
  """

  @three "part(bpm: 120) |> play(:c2, 1.5) |> play(:g2, 1.5)"

  defp named(name, source), do: %{"name" => name, "source" => source}

  defp refute_broadcast_event(%{ref: ref}, event) do
    refute_receive {:runtime_broadcast, "js_live", ^ref, {:event, ^event, _payload, _info}}, 100
  end

  defp cell(loops) do
    {kino, _source} = start_smart_cell!(LiveLoopsCell, %{"loops" => loops})
    _data = connect(kino)

    kino
  end

  describe "opening" do
    test "a fresh cell opens on the same loops the terminal front end opens on" do
      assert [%{"name" => "drums"}, %{"name" => "bass"}] = LiveLoopsCell.demo()
    end

    test "the loops it opens on are built with the kit, and every one of them plays" do
      {errors, scores} = LiveLoopsCell.read_loops(LiveLoopsCell.demo())

      assert errors == []
      assert length(scores) == length(LiveLoopsCell.demo())

      for {name, score} <- scores do
        assert Mixer.peak(TuningFork.Score.render(score, 44_100)) > 1_000, "#{name} is silent"

        for {_beat, voice} <- score.notes do
          assert voice.freq < 400.0, "#{name} is a raw oscillator, not a kit sound"
        end
      end
    end

    test "what it opens on is what a new loop opens on, and both come from core" do
      assert LiveLoopsCell.demo() |> hd() |> Map.fetch!("source") =~ "Kit.voice("
      assert Source.template() =~ "Kit.voice("
    end

    test "a saved cell opens on what was saved, with the vocabulary to hand" do
      loops = [named("bass", "part(bpm: 100)")]
      data = connect(cell(loops))

      assert data.loops == loops
      assert data.template == Source.template()
      assert data.reference =~ "Kit.voice("
    end
  end

  describe "the boundary" do
    test "attrs are the board, and an edit is written back into the notebook" do
      kino = cell([named("bass", @drums)])
      edited = [named("bass", @three)]

      push_event(kino, "update_loops", %{"loops" => edited})

      assert_smart_cell_update(kino, %{"loops" => ^edited}, source)
      assert source =~ "play(:c2, 1.5)"
    end

    test "editing sends nothing back to the browser, and plays nothing" do
      kino = cell([named("drums", @drums)])

      push_event(kino, "update_loops", %{"loops" => [named("drums", "part(bpm: 90)")]})

      refute_broadcast_event(kino, "audio")
      refute_broadcast_event(kino, "evaluated")
    end
  end

  describe "what evaluating a source line means" do
    test "a part becomes a score" do
      assert {:ok, %TuningFork.Score{}} = LiveLoopsCell.eval_source(@drums)
    end

    test "a score is taken as it stands" do
      score = TuningFork.Score.new(bpm: 120, beats: 4)
      source = "TuningFork.Score.new(bpm: 120, beats: 4)"

      assert {:ok, ^score} = LiveLoopsCell.eval_source(source)
    end

    test "anything else is reported rather than crashing the board" do
      assert {:error, message} = LiveLoopsCell.eval_source("1 + 1")
      assert message =~ "not a score or a part"
    end

    test "code that will not compile is reported in one line" do
      assert {:error, message} = LiveLoopsCell.eval_source("part(bpm: (")
      assert is_binary(message)
      refute message =~ "\n"
    end

    test "blank source is reported rather than silently doing nothing" do
      assert {:error, _message} = LiveLoopsCell.eval_source("")
      assert {:error, _message} = LiveLoopsCell.eval_source(nil)
    end
  end

  describe "reading the board" do
    test "every named loop comes back with its name" do
      {errors, scores} = LiveLoopsCell.read_loops([named("drums", @drums), named("bass", @three)])

      assert errors == []
      assert Enum.map(scores, &elem(&1, 0)) == ["drums", "bass"]
    end

    test "a loop that will not read is reported against its own row" do
      {errors, scores} = LiveLoopsCell.read_loops([named("drums", @drums), named("bad", "1 + (")])

      assert [%{loop: 1, error: message}] = errors
      assert is_binary(message)
      assert length(scores) == 1
    end

    test "a loop with no name or no source is passed over rather than reported" do
      assert LiveLoopsCell.read_loops([named("", @drums), named("bass", "")]) == {[], []}
    end
  end

  describe "the stage it plays on" do
    test "evaluating starts every loop on the cell's own stage and streams the mix" do
      kino = cell([named("drums", @drums), named("bass", @three)])

      push_event(kino, "evaluate", %{"loops" => [named("drums", @drums), named("bass", @three)]})

      assert_broadcast_event(kino, "evaluated", %{errors: [], playing: true})
      assert_broadcast_event(kino, "pcm", {:binary, %{}, chunk}, 5_000)
      assert byte_size(chunk) == 2_048 * 4

      assert_broadcast_event(
        kino,
        "readouts",
        %{readouts: [%{name: "bass"}, %{name: "drums"}]},
        2_000
      )
    end

    test "what it streams is not silence" do
      kino = cell([named("drums", @drums)])
      push_event(kino, "evaluate", %{"loops" => [named("drums", @drums)]})

      loud =
        Enum.find(1..40, fn _ ->
          assert_broadcast_event(kino, "pcm", {:binary, %{}, chunk}, 5_000)
          Mixer.peak(chunk) > 1_000
        end)

      assert loud
    end

    test "evaluating again swaps the loops that changed and stops the ones taken away" do
      kino = cell([named("drums", @drums), named("bass", @three)])
      push_event(kino, "evaluate", %{"loops" => [named("drums", @drums), named("bass", @three)]})

      assert_broadcast_event(
        kino,
        "readouts",
        %{readouts: [%{name: "bass"}, %{name: "drums"}]},
        2_000
      )

      push_event(kino, "evaluate", %{"loops" => [named("drums", @drums)]})
      assert_broadcast_event(kino, "evaluated", %{errors: [], playing: true})

      Process.sleep(300)
      assert_broadcast_event(kino, "readouts", %{readouts: [%{name: "drums"}]}, 2_000)
    end

    test "a board that will not read is reported, and nothing starts" do
      kino = cell([named("drums", "part(bpm: (")])

      push_event(kino, "evaluate", %{"loops" => [named("drums", "part(bpm: (")]})

      assert_broadcast_event(kino, "evaluated", %{errors: [%{loop: 0}], playing: false})
      assert_broadcast_event(kino, "readouts", %{readouts: []}, 2_000)
    end

    test "an empty board starts nothing" do
      kino = cell([])

      push_event(kino, "evaluate", %{"loops" => []})

      assert_broadcast_event(kino, "evaluated", %{errors: [], playing: false})
    end

    test "stop silences every loop and the readouts empty" do
      kino = cell([named("drums", @drums)])
      push_event(kino, "evaluate", %{"loops" => [named("drums", @drums)]})
      assert_broadcast_event(kino, "readouts", %{readouts: [%{name: "drums"}]}, 2_000)

      push_event(kino, "stop", %{})
      Process.sleep(300)

      assert_broadcast_event(kino, "readouts", %{readouts: []}, 2_000)
    end
  end

  describe "what it writes" do
    test "no loops writes nothing" do
      assert LiveLoopsCell.to_source(%{"loops" => []}) == ""
    end

    test "a loop with a blank name or a blank source is left out" do
      loops = [named("", @drums), named("bass", "")]

      assert LiveLoopsCell.to_source(%{"loops" => loops}) == ""
    end

    test "it writes each loop as a live_loop under the Sonic Pi words" do
      source =
        LiveLoopsCell.to_source(%{
          "loops" => [named("drums", @drums), named("bells", "sample :bd_haus\nsleep 0.5")]
        })

      assert {:ok, _ast} = Code.string_to_quoted(source)
      assert source =~ "use TuningFork.SonicPi"
      assert source =~ "live_loop :drums do"
      assert source =~ "live_loop :bells do\n  sample :bd_haus\n  sleep 0.5\nend"
      refute source =~ "Transport.render"
    end

    test "a loop that does not read as Elixir is written as a string to compile, so the source still parses" do
      source = LiveLoopsCell.to_source(%{"loops" => [named("broken", "part(bpm: (")]})

      assert {:ok, _ast} = Code.string_to_quoted(source)
      assert source =~ "TuningFork.Part.Source.compile(\"part(bpm: (\")"
    end

    test "it starts a stage widget only when the notebook has none" do
      source = LiveLoopsCell.to_source(%{"loops" => [named("drums", @drums)]})

      assert source =~
               "unless Process.whereis(TuningFork.Stage), do: Kino.render(KinoTuningFork.stage())"
    end

    test "it is formatted Elixir, not a string that happens to look like it" do
      source = LiveLoopsCell.to_source(%{"loops" => [named("drums", @drums)]})

      assert source == source |> Code.format_string!() |> IO.iodata_to_binary()
    end

    test "a name that is not a variable still writes something that compiles" do
      source = LiveLoopsCell.to_source(%{"loops" => [named("the drums", @drums)]})

      assert {:ok, _ast} = Code.string_to_quoted(source)
    end

    test "running it starts the loops on the named stage" do
      {stage, ours?} = named_stage()
      loops = [named("drums", @drums)]

      Code.eval_string(LiveLoopsCell.to_source(%{"loops" => loops}))
      Process.sleep(200)

      assert Map.has_key?(TuningFork.Stage.loops(stage), :drums)
      if ours?, do: GenServer.stop(stage)
    end
  end

  defp named_stage do
    case TuningFork.Stage.start_link(sink: TuningFork.Sink.Silent, rate: 8_000) do
      {:ok, stage} -> {stage, true}
      {:error, {:already_started, stage}} -> {stage, false}
    end
  end
end

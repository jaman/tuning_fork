defmodule KinoTuningFork.LivePatternsCellTest do
  @moduledoc """
  Drives `KinoTuningFork.LivePatternsCell` as Livebook does and asserts on what the browser is
  sent.
  """

  use ExUnit.Case, async: false

  import Kino.Test

  alias KinoTuningFork.LivePatternsCell
  alias TuningFork.Mixer
  alias TuningFork.Session.View

  setup :configure_livebook_bridge

  defp cell(attrs \\ %{}) do
    {kino, _source} = start_smart_cell!(LivePatternsCell, attrs)
    _data = connect(kino)

    kino
  end

  defp refute_broadcast_event(%{ref: ref}, event) do
    refute_receive {:runtime_broadcast, "js_live", ^ref, {:event, ^event, _payload, _info}}, 100
  end

  describe "opening" do
    test "a fresh cell opens on something to hear" do
      assert LivePatternsCell.demo() =~ "bd*4"

      assert connect(cell()) == %{
               text: LivePatternsCell.demo(),
               cps: "0.5",
               columns: View.columns(),
               rate: 44_100,
               channels: 2,
               diagnostics: []
             }
    end

    test "a saved cell opens on what was saved" do
      data = connect(cell(%{"text" => "hh*8", "cps" => "1.0"}))

      assert data.text == "hh*8"
      assert data.cps == "1.0"
    end
  end

  describe "the boundary" do
    test "attrs are the buffer, and an edit is written back into the notebook" do
      kino = cell(%{"text" => "bd*4", "cps" => "0.75"})

      push_event(kino, "update_text", %{"text" => "hh*8"})

      assert_smart_cell_update(kino, %{"text" => "hh*8", "cps" => "0.75"}, source)

      assert source =~ "hh*8"
    end

    test "typing sends nothing back to the browser, and plays nothing" do
      kino = cell()

      push_event(kino, "update_text", %{"text" => "hh*4"})

      refute_broadcast_event(kino, "audio")
      refute_broadcast_event(kino, "evaluated")
    end

    test "changing cps is remembered without re-rendering anything" do
      kino = cell()

      push_event(kino, "set_cps", %{"cps" => "2.0"})

      assert_smart_cell_update(kino, %{"cps" => "2.0"}, source)
      assert source =~ "cps: 2"
      refute_broadcast_event(kino, "audio")
    end
  end

  describe "the stage it plays on" do
    test "evaluating starts the pattern on the cell's own stage and streams the mix" do
      kino = cell(%{"cps" => "2"})

      push_event(kino, "evaluate", %{"text" => "s(\"bd*4\")"})

      assert_broadcast_event(kino, "evaluated", %{diagnostics: []})
      assert_broadcast_event(kino, "pcm", {:binary, %{}, chunk}, 5_000)
      assert byte_size(chunk) == 2_048 * 4
    end

    test "what it streams is not silence" do
      kino = cell(%{"cps" => "2"})
      push_event(kino, "evaluate", %{"text" => "s(\"bd*4\")"})

      loud =
        Enum.find(1..40, fn _ ->
          assert_broadcast_event(kino, "pcm", {:binary, %{}, chunk}, 5_000)
          Mixer.peak(chunk) > 1_000
        end)

      assert loud
    end

    test "a row that will not parse is reported and the rest still play" do
      kino = cell(%{"cps" => "2"})

      push_event(kino, "evaluate", %{"text" => "s(\"bd*4\")\n|> nonsense(("})

      assert_broadcast_event(kino, "evaluated", %{diagnostics: [%{row: 0}]})
      assert_broadcast_event(kino, "pcm", {:binary, %{}, _chunk}, 5_000)
    end

    test "every row parked is silence rather than a crash" do
      kino = cell(%{"cps" => "2"})

      push_event(kino, "evaluate", %{"text" => "-- s(\"bd*4\")"})

      assert_broadcast_event(kino, "evaluated", %{diagnostics: []})
      assert_broadcast_event(kino, "pcm", {:binary, %{}, _chunk}, 5_000)
    end

    test "stop ends the pattern" do
      kino = cell(%{"cps" => "2"})
      push_event(kino, "evaluate", %{"text" => "s(\"bd*4\")"})
      assert_broadcast_event(kino, "at", %{cycle: _, visuals: _}, 2_000)

      push_event(kino, "stop", %{})
      Process.sleep(300)

      refute_receive {:runtime_broadcast, "js_live", _ref, {:event, "at", _payload, _info}}, 300
    end
  end

  describe "a pasted Strudel piece" do
    test "evaluating takes the tempo the piece sets and says so" do
      kino = cell(%{"cps" => "2"})

      push_event(kino, "evaluate", %{"text" => "setcps(1.25)\n$: s(\"bd*4\").gain(.8)"})

      assert_broadcast_event(kino, "evaluated", %{diagnostics: [], cps: 1.25})
      assert_smart_cell_update(kino, %{"cps" => "1.25"}, _source)
    end

    test "a piece with no setcps keeps the cell's tempo" do
      kino = cell(%{"cps" => "2"})

      push_event(kino, "evaluate", %{"text" => "$: s(\"bd*4\")"})

      assert_broadcast_event(kino, "evaluated", %{diagnostics: [], cps: 2})
    end
  end

  describe "where the pattern has got to" do
    test "the cycle is reported as it plays, with what to draw" do
      kino = cell(%{"text" => "s(\"bd*4\")\n|> scope()", "cps" => "2"})

      push_event(kino, "evaluate", %{"text" => "s(\"bd*4\")\n|> scope()"})

      assert_broadcast_event(kino, "at", %{cycle: cycle, visuals: visuals}, 2_000)
      assert is_number(cycle)
      assert [%{row: 0, kind: "scope"}] = visuals
    end

    test "a buffer asking for nothing to be drawn still reports where it is" do
      kino = cell(%{"text" => "s(\"bd*4\")", "cps" => "0.5"})

      push_event(kino, "evaluate", %{"text" => "s(\"bd*4\")"})

      assert_broadcast_event(kino, "at", %{cycle: _cycle, visuals: []}, 2_000)
    end

    test "nothing is reported before anything plays" do
      kino = cell(%{"text" => "s(\"bd*4\")"})

      refute_broadcast_event(kino, "at")
    end
  end

  describe "what it writes" do
    test "an empty buffer writes nothing" do
      assert LivePatternsCell.to_source(%{"text" => "", "cps" => "0.5"}) == ""
    end

    test "a buffer with every row parked writes nothing" do
      assert LivePatternsCell.to_source(%{"text" => "-- bd*4\n_ hh*8", "cps" => "0.5"}) == ""
    end

    test "it folds the rows and starts them on the notebook's stage, or swaps them in" do
      source = LivePatternsCell.to_source(%{"text" => "s(\"bd*4\")\n|> gain(0.8)", "cps" => "2"})

      assert {:ok, _ast} = Code.string_to_quoted(source)
      assert source =~ "TuningFork.Session.combined(rows)"
      assert source =~ "TuningFork.Stage.start_pattern(pattern, cps: 2)"
      assert source =~ "TuningFork.Stage.update_pattern(pattern, at: :cycle)"
      refute source =~ "Transport.render"
    end

    test "it is formatted Elixir, not a string that happens to look like it" do
      source = LivePatternsCell.to_source(%{"text" => "bd*4", "cps" => "0.5"})

      assert source == source |> Code.format_string!() |> IO.iodata_to_binary()
    end

    test "a quote in the source is escaped rather than breaking the literal" do
      text = "s(\"bd*4\")\n// a \"quoted\" comment # not code"
      source = LivePatternsCell.to_source(%{"text" => text, "cps" => "0.5"})

      assert {:ok, _ast} = Code.string_to_quoted(source)
    end

    test "a blank cps falls back rather than breaking the source" do
      assert LivePatternsCell.to_source(%{"text" => "bd*4", "cps" => ""}) =~ "cps: 0.5"
    end

    test "running it plays the pattern on the named stage" do
      {stage, ours?} = named_stage()
      attrs = %{"text" => "s(\"bd*4\")", "cps" => "2"}

      Code.eval_string(LivePatternsCell.to_source(attrs))
      Process.sleep(200)

      assert TuningFork.Stage.cycle(stage) != nil
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

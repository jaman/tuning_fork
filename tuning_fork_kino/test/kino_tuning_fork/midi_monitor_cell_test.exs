defmodule KinoTuningFork.MidiMonitorCellTest do
  use ExUnit.Case, async: false

  alias Kino.JS.Live.Context
  alias KinoTuningFork.MidiMonitorCell

  defp ctx(attrs \\ %{}) do
    {:ok, ctx} = MidiMonitorCell.init(attrs, Context.new())

    put_in(ctx.__private__[:ref], make_ref())
  end

  test "an empty cell opens on nothing open, a piano, and a pattern to send" do
    fields = ctx().assigns.fields

    assert fields["input"] == ""
    assert fields["output"] == ""
    assert fields["voice"] == "gm_piano"
    assert fields["pattern"] =~ "bd"
    assert MidiMonitorCell.to_attrs(ctx()) == fields
  end

  test "the page is told the ports, the voices and what is happening" do
    {:ok, payload, _ctx} = MidiMonitorCell.handle_connect(ctx())

    assert is_list(payload.inputs)
    assert is_list(payload.outputs)
    assert Enum.any?(payload.voices, &(&1 == "gm_piano"))
    assert payload.state.keys == %{}
    assert payload.state.playing == false
  end

  test "the monitor's state reaches the page with its ports and events as lists, so it serializes" do
    state = %{
      input: {0, "CASIO USB-MIDI"},
      output: {:virtual, "TuningFork Out"},
      voice: {:gm, "piano"},
      keys: %{60 => 100},
      sounding: [62],
      pedal: false,
      bend: 0,
      controls: %{1 => 64},
      program: nil,
      playing: false,
      cps: 0.5,
      clock: false,
      events:
        for n <- 1..20 do
          {:in, {:note_on, 0, 40 + n, 100}, n}
        end
    }

    shown = MidiMonitorCell.page_state(state)

    assert shown.input == [0, "CASIO USB-MIDI"]
    assert shown.output == [:virtual, "TuningFork Out"]
    refute Map.has_key?(shown, :voice)
    assert length(shown.events) == 12
    assert hd(shown.events) == [:in, [:note_on, 0, 41, 100], 1]
    assert {:ok, _json} = Jason.encode(shown)

    assert MidiMonitorCell.page_state(%{state | input: nil, output: nil, events: []}).input == nil
  end

  test "a field the browser sends is kept" do
    {:noreply, ctx} =
      MidiMonitorCell.handle_event("update_field", %{"field" => "cps", "value" => "0.75"}, ctx())

    assert ctx.assigns.fields["cps"] == "0.75"
  end

  test "tapping a key with no output open is refused quietly" do
    {:noreply, _ctx} = MidiMonitorCell.handle_event("tap", %{"note" => 60}, ctx())
  end

  test "playing out with no output open reports the reason rather than crashing" do
    {:noreply, _ctx} = MidiMonitorCell.handle_event("play", %{}, ctx())
  end

  describe "what it writes" do
    test "nothing until a port is chosen" do
      assert MidiMonitorCell.to_source(%{"input" => "", "output" => ""}) == ""
    end

    test "the monitor, the ports, the voice and the pattern, in that order" do
      source =
        MidiMonitorCell.to_source(%{
          "input" => "0",
          "output" => "virtual:TuningFork",
          "voice" => "gm_epiano1",
          "pattern" => ~s|s("bd*4, hh*8")|,
          "cps" => "0.5",
          "clock" => true
        })

      assert source =~ "KinoTuningFork.stage()"
      assert source =~ ~s|TuningFork.Midi.Monitor.start_link(voice: "gm_epiano1")|
      assert source =~ "TuningFork.Midi.Monitor.open_input(midi, 0)"
      assert source =~ ~s|TuningFork.Midi.Monitor.open_output(midi, {:virtual, "TuningFork"})|
      assert source =~ ~s|TuningFork.Pattern.Source.parse("s(\\"bd*4, hh*8\\")")|
      assert source =~ "TuningFork.Midi.Monitor.play(midi, pattern, cps: 0.5, clock: true)"
      assert {:ok, _ast} = Code.string_to_quoted(source)
    end

    test "an output alone plays out, an input alone plays in" do
      out_only = MidiMonitorCell.to_source(%{"output" => "1", "pattern" => ~s|s("bd")|})
      refute out_only =~ "open_input"
      assert out_only =~ "open_output(midi, 1)"

      in_only = MidiMonitorCell.to_source(%{"input" => "virtual:Keys", "pattern" => ""})
      assert in_only =~ ~s|open_input(midi, {:virtual, "Keys"})|
      refute in_only =~ "play("
    end
  end
end

defmodule TuningFork.MidiApp do
  @moduledoc """
  A MIDI device in a terminal: a keyboard played in and heard on a stage, a pattern played
  out with clock, a key strip lit for both directions, and a log of every message — over a
  `TuningFork.Midi.Monitor`.

      mix tuning_fork.midi
  """

  use Drafter, runtime: :reducer

  alias TuningFork.Midi.Monitor
  alias TuningFork.Pattern.Source
  alias TuningFork.Stage

  @tick 100
  @pad 1
  @low 36
  @high 96
  @voices ~w(gm_piano gm_epiano1 gm_acoustic_bass gm_electric_bass_finger gm_flute gm_string_ensemble_1 sawtooth square triangle sine)
  @default_pattern ~S{stack([s("bd*4, hh*8"), n("0 4 7 4") |> scale("c:minor")])}
  @kept 8

  @type choice :: nil | {non_neg_integer(), String.t()} | {:virtual, String.t()}

  @type t :: %{
          monitor: pid() | nil,
          stage: pid() | nil,
          sink: module() | nil,
          inputs: [choice()],
          outputs: [choice()],
          input: non_neg_integer(),
          output: non_neg_integer(),
          voice: String.t(),
          pattern: String.t(),
          editing: String.t() | nil,
          cps: float(),
          clock: boolean(),
          tap: non_neg_integer(),
          snapshot: Monitor.state(),
          help: boolean(),
          said: String.t()
        }

  @doc """
  The state the app starts in.

  `props` is a map or a keyword list:

    * `:stage` — an already-running `TuningFork.Stage` the keyboard plays on, used as given
    * `:sink` — a `TuningFork.Sink` module used when the app starts its own stage, in place
      of checking for a speaker
    * `:voice` — what the keyboard plays, default `"gm_piano"`
    * `:pattern` — the pattern row to play out, one expression, default a drum and bass line
  """
  @impl true
  @spec mount(map() | keyword()) :: t()
  def mount(props) do
    props = Map.new(props)

    state = %{
      monitor: nil,
      stage: Map.get(props, :stage),
      sink: Map.get(props, :sink),
      inputs: [nil],
      outputs: [nil],
      input: 0,
      output: 0,
      voice: Map.get(props, :voice, "gm_piano"),
      pattern: Map.get(props, :pattern, @default_pattern),
      editing: nil,
      cps: 0.5,
      clock: true,
      tap: 60,
      snapshot: empty(),
      help: false,
      said: greeting()
    }

    schedule()

    state |> ensure_stage() |> start_monitor() |> refresh_ports() |> snapshot()
  end

  @doc "The voices `v` walks through."
  @spec voices() :: [String.t()]
  def voices, do: @voices

  @doc false
  @impl true
  def update(message, state)

  def update(:tick, state) do
    schedule()
    snapshot(state)
  end

  def update({:midi_monitor, _monitor, _side, _event, _at}, state), do: snapshot(state)
  def update({:midi_monitor, _monitor, :changed}, state), do: snapshot(state)

  def update({:key, :q, [:ctrl]}, state), do: quit(state)

  def update({:key, :enter}, %{editing: text} = state) when is_binary(text),
    do: keep_pattern(state)

  def update({:key, :escape}, %{editing: text} = state) when is_binary(text),
    do: %{state | editing: nil}

  def update({:key, :backspace}, %{editing: text} = state) when is_binary(text),
    do: %{state | editing: String.slice(text, 0, max(String.length(text) - 1, 0))}

  def update({:key, :space}, %{editing: text} = state) when is_binary(text),
    do: %{state | editing: text <> " "}

  def update({:key, key}, %{editing: text} = state) when is_binary(text) and is_atom(key) do
    typed = Atom.to_string(key)
    if String.length(typed) == 1, do: %{state | editing: text <> typed}, else: state
  end

  def update({:char, codepoint}, %{editing: text} = state) when is_binary(text),
    do: %{state | editing: text <> <<codepoint::utf8>>}

  def update(_anything, %{editing: text} = state) when is_binary(text), do: state

  def update({:key, :"?"}, state), do: %{state | help: not state.help}
  def update({:key, :i}, state), do: choose_input(state, 1)
  def update({:key, :I}, state), do: choose_input(state, -1)
  def update({:key, :o}, state), do: choose_output(state, 1)
  def update({:key, :O}, state), do: choose_output(state, -1)
  def update({:key, :v}, state), do: choose_voice(state, 1)
  def update({:key, :V}, state), do: choose_voice(state, -1)
  def update({:key, :r}, state), do: state |> refresh_ports() |> say("ports listed again")
  def update({:key, :p}, state), do: toggle_playing(state)

  def update({:key, :c}, state),
    do:
      %{state | clock: not state.clock}
      |> say("clock #{if state.clock, do: "off", else: "on"} from the next play")

  def update({:key, :+}, state), do: set_cps(state, state.cps + 0.05)
  def update({:key, :=}, state), do: set_cps(state, state.cps + 0.05)
  def update({:key, :-}, state), do: set_cps(state, state.cps - 0.05)
  def update({:key, :e}, state), do: %{state | editing: state.pattern}
  def update({:key, :left}, state), do: %{state | tap: max(state.tap - 1, @low)}
  def update({:key, :right}, state), do: %{state | tap: min(state.tap + 1, @high)}
  def update({:key, :up}, state), do: %{state | tap: min(state.tap + 12, @high)}
  def update({:key, :down}, state), do: %{state | tap: max(state.tap - 12, @low)}
  def update({:key, :enter}, state), do: tap(state)
  def update({:key, :space}, state), do: tap(state)
  def update(_anything_else, state), do: state

  @doc false
  @impl true
  def render(state) do
    vertical(
      [
        header("MIDI"),
        label(status(state), style: %{fg: :cyan}),
        vertical(body(state), flex: 1),
        footer(footer_text(state))
      ],
      padding: @pad
    )
  end

  @doc """
  The line along the bottom: the pattern being typed while `e` is open, or what just happened.

      iex> TuningFork.MidiApp.footer_text(%{editing: ~S|s("bd")|, said: "anything"})
      ~S|pattern ▸ s("bd")▏ · enter plays it, esc cancels|
  """
  @spec footer_text(t() | map()) :: String.t()
  def footer_text(%{editing: text}) when is_binary(text),
    do: "pattern ▸ #{text}▏ · enter plays it, esc cancels"

  def footer_text(state), do: state.said

  defp body(%{help: true}), do: Enum.map(reference(), &label(&1, style: %{fg: colour_of(&1)}))

  defp body(state) do
    [
      horizontal(keys(state)),
      label(caret(state), style: %{fg: :bright_black}),
      label(readout(state), style: %{fg: :white}),
      label("pattern out ▸ " <> state.pattern, style: %{fg: :bright_white}),
      label("", style: %{fg: :bright_black})
    ] ++ recent(state)
  end

  defp keys(state) do
    lit_in = Map.keys(state.snapshot.keys)
    lit_out = state.snapshot.sounding

    for note <- @low..@high do
      {glyph, colour} = key_look(note, note in lit_in, note in lit_out)
      label(glyph, style: %{fg: colour})
    end
  end

  defp key_look(_note, true, true), do: {"█", :magenta}
  defp key_look(_note, true, false), do: {"█", :blue}
  defp key_look(_note, false, true), do: {"█", :yellow}

  defp key_look(note, false, false),
    do: if(black?(note), do: {"▀", :bright_black}, else: {"▄", :white})

  defp black?(note), do: rem(note, 12) in [1, 3, 6, 8, 10]

  defp caret(state), do: String.duplicate(" ", state.tap - @low) <> "^ " <> name_of(state.tap)

  @doc """
  A note's name from its number.

      iex> TuningFork.MidiApp.name_of(60)
      "C4"
      iex> TuningFork.MidiApp.name_of(61)
      "C#4"
  """
  @spec name_of(non_neg_integer()) :: String.t()
  def name_of(note) do
    names = ~w(C C# D D# E F F# G G# A A# B)
    Enum.at(names, rem(note, 12)) <> Integer.to_string(div(note, 12) - 1)
  end

  defp status(state) do
    snap = state.snapshot

    playing =
      if snap.playing,
        do: " ▶ #{Float.round(snap.cps, 2)} cps#{if snap.clock, do: " · clock", else: ""}",
        else: ""

    "in: #{port_name(snap.input)} · #{state.voice}   out: #{port_name(snap.output)}#{playing}"
  end

  defp readout(state) do
    snap = state.snapshot
    bits = ["pedal #{if snap.pedal, do: "down", else: "up"}", "bend #{snap.bend}"]
    bits = if snap.program, do: bits ++ ["program #{snap.program}"], else: bits

    controls =
      Enum.map_join(Enum.sort(snap.controls), " ", fn {cc, value} -> "cc#{cc}=#{value}" end)

    bits = if controls == "", do: bits, else: bits ++ [controls]
    Enum.join(bits, " · ")
  end

  defp recent(state) do
    state.snapshot.events
    |> Enum.take(@kept)
    |> Enum.map(fn {side, event, _at} ->
      {arrow, colour} = if side == :in, do: {"← ", :blue}, else: {"→ ", :yellow}
      label(arrow <> describe(event), style: %{fg: colour})
    end)
  end

  defp describe(event) when is_tuple(event),
    do: event |> Tuple.to_list() |> Enum.map_join(" ", &to_string/1)

  defp describe(event), do: to_string(event)

  @doc "A port choice as it is named on screen."
  @spec port_name(choice()) :: String.t()
  def port_name(nil), do: "none"
  def port_name({:virtual, name}), do: "virtual \"#{name}\""
  def port_name({_index, name}), do: name

  defp choose_input(state, by) do
    index = Integer.mod(state.input + by, length(state.inputs))
    state = %{state | input: index}

    case Enum.at(state.inputs, index) do
      nil ->
        :ok = Monitor.close_input(state.monitor)
        state |> snapshot() |> say("input closed")

      choice ->
        opened(state, Monitor.open_input(state.monitor, choice_of(choice)), "input", choice)
    end
  end

  defp choose_output(state, by) do
    index = Integer.mod(state.output + by, length(state.outputs))
    state = %{state | output: index}

    case Enum.at(state.outputs, index) do
      nil ->
        :ok = Monitor.close_output(state.monitor)
        state |> snapshot() |> say("output closed")

      choice ->
        opened(state, Monitor.open_output(state.monitor, choice_of(choice)), "output", choice)
    end
  end

  defp opened(state, :ok, side, choice),
    do: state |> snapshot() |> say("#{side}: #{port_name(choice)}")

  defp opened(state, {:error, reason}, side, choice),
    do: say(state, "#{side} #{port_name(choice)} would not open: #{inspect(reason)}")

  defp choice_of({:virtual, name}), do: {:virtual, name}
  defp choice_of({index, _name}), do: index

  defp choose_voice(state, by) do
    at = Enum.find_index(@voices, &(&1 == state.voice)) || 0
    voice = Enum.at(@voices, Integer.mod(at + by, length(@voices)))
    Monitor.voice(state.monitor, voice)
    say(%{state | voice: voice}, "voice: #{voice}")
  end

  defp toggle_playing(%{snapshot: %{playing: true}} = state) do
    Monitor.stop(state.monitor)
    say(state, "stopped")
  end

  defp toggle_playing(state), do: play(state)

  defp play(state) do
    with {:ok, pattern} <- Source.parse(state.pattern),
         :ok <- Monitor.play(state.monitor, pattern, cps: state.cps, clock: state.clock) do
      say(state, "playing out at #{state.cps} cps")
    else
      {:error, :no_output} -> say(state, "pick an output with o first")
      {:error, reason} -> say(state, "pattern: #{reason_text(reason)}")
    end
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp keep_pattern(%{editing: text} = state) do
    state = %{state | pattern: text, editing: nil}
    if state.snapshot.playing, do: play(state), else: say(state, "pattern kept · p plays it out")
  end

  defp set_cps(state, cps) do
    cps = cps |> max(0.05) |> Float.round(2)
    if state.snapshot.playing, do: Monitor.cps(state.monitor, cps)
    say(%{state | cps: cps}, "#{cps} cps")
  end

  defp tap(state) do
    case Monitor.tap(state.monitor, state.tap, 100) do
      :ok -> say(state, "sent #{name_of(state.tap)}")
      {:error, :no_output} -> say(state, "pick an output with o first")
      {:error, reason} -> say(state, inspect(reason))
    end
  end

  defp refresh_ports(state) do
    %{
      state
      | inputs: [nil] ++ Monitor.inputs() ++ [{:virtual, "TuningFork In"}],
        outputs: [nil] ++ Monitor.outputs() ++ [{:virtual, "TuningFork Out"}]
    }
  end

  defp snapshot(%{monitor: nil} = state), do: state

  defp snapshot(state) do
    if Process.alive?(state.monitor),
      do: %{state | snapshot: Monitor.state(state.monitor)},
      else: %{state | snapshot: empty()}
  end

  defp empty do
    %{
      input: nil,
      output: nil,
      voice: nil,
      keys: %{},
      sounding: [],
      pedal: false,
      bend: 0,
      controls: %{},
      program: nil,
      playing: false,
      cps: 0.5,
      clock: false,
      events: []
    }
  end

  defp start_monitor(state) do
    {:ok, monitor} = Monitor.start_link(stage: state.stage, voice: state.voice)
    :ok = Monitor.subscribe(monitor, self())
    %{state | monitor: monitor}
  end

  defp ensure_stage(%{stage: stage} = state) when is_pid(stage), do: state

  defp ensure_stage(state) do
    case Stage.start_link(name: nil, sink: sink(state), voices: 48) do
      {:ok, stage} -> %{state | stage: stage}
      {:error, _reason} -> state
    end
  end

  defp sink(%{sink: sink}) when not is_nil(sink), do: sink

  defp sink(_state),
    do:
      if(TuningFork.available?(),
        do: Module.concat([:TuningFork, :Sink, :Speaker]),
        else: TuningFork.Sink.Silent
      )

  defp say(state, text), do: %{state | said: text}

  defp greeting,
    do:
      "i/o pick ports · v voice · p plays the pattern out · e edits it · ←→ enter taps a key · ? keys"

  defp schedule, do: Process.send_after(self(), :tick, @tick)

  defp quit(state) do
    if state.monitor && Process.alive?(state.monitor),
      do: GenServer.stop(state.monitor, :normal, 2_000)

    if state.stage && Process.alive?(state.stage), do: GenServer.stop(state.stage, :normal, 2_000)
    {:stop, :normal}
  catch
    :exit, _reason -> {:stop, :normal}
  end

  defp colour_of(""), do: :bright_black
  defp colour_of("  " <> _rest), do: :white
  defp colour_of(_heading), do: :cyan

  @doc "The key reference `?` shows, one line each."
  @spec reference() :: [String.t()]
  def reference do
    [
      "Ports",
      "  i / I     next / previous input — a keyboard, or the virtual port other software can send to",
      "  o / O     next / previous output — a synth, a DAW, or the virtual port other software can read",
      "  r         list the ports again",
      "  v / V     the instrument the keyboard plays on this machine",
      "",
      "Out",
      "  p         play the pattern out, or stop it",
      "  e         edit the pattern — one expression, as a TF Patterns row — enter plays it, esc cancels",
      "  + / -     cycles per second",
      "  c         MIDI clock on or off, from the next play",
      "  ← → ↑ ↓   choose a key on the strip; enter or space sends it out",
      "",
      "Strip",
      "  blue      held on the input · yellow: sounding on the output · magenta: both",
      "",
      "  ?         this list · ctrl+q quits"
    ]
  end
end

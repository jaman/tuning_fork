defmodule TuningFork.Midi.Out do
  @moduledoc """
  Plays a `TuningFork.Score` or a live `TuningFork.Pattern` out of a MIDI port, in time.

      {:ok, port} = TuningFork.Midi.Port.open_virtual_output("tuning_fork")
      {:ok, playing} = TuningFork.Midi.Out.play(port, score)
      {:ok, live} = TuningFork.Midi.Out.pattern(port, s("bd*4, hh*8"), cps: 0.5)

      TuningFork.Midi.Out.update_pattern(live, s("bd*2"))
      TuningFork.Midi.Out.stop(playing)
  """

  use GenServer

  alias TuningFork.{Kit, Pattern, Score}
  alias TuningFork.Midi.{Message, Port}

  @tick_ms 25
  @lookahead 0.15
  @percussion %{
    "bd" => 36,
    "kick" => 36,
    "sn" => 38,
    "snare" => 38,
    "rim" => 37,
    "cp" => 39,
    "clap" => 39,
    "hh" => 42,
    "hat" => 42,
    "oh" => 46,
    "open" => 46,
    "lt" => 45,
    "mt" => 47,
    "tom" => 47,
    "ht" => 50,
    "rd" => 51,
    "ride" => 51,
    "cr" => 49,
    "crash" => 49,
    "tam" => 54,
    "cow" => 56,
    "perc" => 60,
    "sh" => 70,
    "shaker" => 70
  }

  @typedoc "A running player."
  @type t :: pid()

  @doc """
  Play `score` out of `port`. Returns `{:ok, player}`; the player is linked to the caller and
  stops when the caller exits.

  Options:

    * `:channel` — which MIDI channel, 1 to 16, default 1
    * `:loop` — start again on reaching the end, default false
    * `:program` — send a program change before playing
  """
  @spec play(Port.t(), Score.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def play(port, %Score{} = score, opts \\ []) do
    GenServer.start_link(__MODULE__, {port, score, opts, self()})
  end

  @doc """
  Play `pattern` out of `port` from cycle zero, for as long as the player runs. Returns
  `{:ok, player}`; the player is linked to the caller.

  Options:

    * `:cps` — cycles per second, default 0.5
    * `:channel` — the MIDI channel for pitched notes, default 1; drums always go on 10
    * `:clock` — send MIDI clock (start, 24 pulses a beat at four beats to the cycle, stop),
      default false
  """
  @spec pattern(Port.t(), Pattern.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def pattern(port, %Pattern{} = pattern, opts \\ []) do
    GenServer.start_link(__MODULE__, {:pattern, port, pattern, opts, self()})
  end

  @doc """
  Swap the pattern a `pattern/3` player is walking: at the next cycle line by default, or
  `at: :now`.
  """
  @spec update_pattern(t(), Pattern.t(), keyword()) :: :ok
  def update_pattern(player, %Pattern{} = pattern, opts \\ []) do
    GenServer.cast(player, {:update_pattern, pattern, Keyword.get(opts, :at, :cycle)})
  end

  @doc "Change a `pattern/3` player's cycles per second from here on."
  @spec pattern_cps(t(), number()) :: :ok
  def pattern_cps(player, cps) when cps > 0, do: GenServer.cast(player, {:cps, cps / 1.0})

  @doc "Stop the player, sending every note off and the sustain pedal up on its channel."
  @spec stop(t()) :: :ok
  def stop(player) do
    if Process.alive?(player), do: GenServer.stop(player, :normal), else: :ok
  end

  @doc """
  The messages the onsets of `pattern` between cycles `from` and `to` become, as
  `{seconds, bytes}` counted from cycle zero and sorted. Pure; takes `pattern/3`'s options.
  A pitched value goes out on `:channel`, a drum name from `TuningFork.Kit.drums/0` on
  channel 10 as General MIDI percussion, and a value that is neither is skipped.
  """
  @spec pattern_messages(Pattern.t(), number(), number(), keyword()) :: [{float(), binary()}]
  def pattern_messages(%Pattern{} = pattern, from, to, opts \\ []) do
    cps = Keyword.get(opts, :cps, 0.5) / 1.0

    pattern
    |> Pattern.query({from / 1.0, to / 1.0})
    |> Enum.filter(&Pattern.onset?/1)
    |> Enum.flat_map(&note_pair(&1, cps, opts))
    |> Enum.sort_by(fn {at, bytes} -> {at, bytes} end)
  end

  defp note_pair(%{whole: {begins, ends}, value: value}, cps, opts) do
    case wire(value, opts) do
      nil ->
        []

      {note, channel} ->
        velocity = Message.velocity(gain_of(value))

        [
          {begins / cps, Message.note_on(note, velocity, channel: channel)},
          {ends / cps, Message.note_off(note, 0, channel: channel)}
        ]
    end
  end

  defp wire(value, opts) do
    case Kit.midi(value) do
      note when is_integer(note) -> {note, Keyword.get(opts, :channel, 1)}
      nil -> percussion(sound_of(value))
    end
  end

  defp sound_of(%{} = controls), do: Map.get(controls, :sound) || Map.get(controls, :s)
  defp sound_of(name) when is_binary(name), do: name
  defp sound_of(_other), do: nil

  defp percussion(name) when is_binary(name) do
    case Map.fetch(@percussion, name |> String.split(":", parts: 2) |> hd()) do
      {:ok, note} -> {note, 10}
      :error -> nil
    end
  end

  defp percussion(_other), do: nil

  defp gain_of(%{gain: gain}) when is_number(gain), do: gain
  defp gain_of(_value), do: 0.8

  @doc """
  The messages `score` becomes, as `{seconds, bytes}` in the order they are sent. Pure; takes
  the options of `play/3`.

      iex> score = TuningFork.Score.new(bpm: 120, beats: 4)
      iex> TuningFork.Midi.Out.messages(score, channel: 1)
      []
  """
  @spec messages(Score.t(), keyword()) :: [{float(), binary()}]
  def messages(%Score{} = score, opts \\ []) do
    score
    |> notes()
    |> Enum.flat_map(&pair(&1, score, opts))
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp notes(%Score{} = score) do
    Enum.reduce(score.layers, score.notes, fn layer, acc -> acc ++ layer.notes end)
  end

  defp pair({beat, voice}, score, opts) do
    case Kit.midi(voice.freq) || nearest(voice.freq) do
      nil ->
        []

      note ->
        at = Score.beat_to_seconds(score, beat)
        velocity = Message.velocity(voice.gain)

        [
          {at, Message.note_on(note, velocity, opts)},
          {at + TuningFork.Voice.duration(voice), Message.note_off(note, 0, opts)}
        ]
    end
  end

  defp nearest(freq) when is_number(freq) and freq > 0 do
    round(69 + 12 * :math.log2(freq / 440.0))
  end

  defp nearest(_freq), do: nil

  @impl true
  def init({:pattern, port, pattern, opts, caller}) do
    Process.flag(:trap_exit, true)
    Process.monitor(caller)
    now = System.monotonic_time(:millisecond)
    if Keyword.get(opts, :clock, false), do: Port.send(port, <<0xFA>>)

    state = %{
      port: port,
      opts: opts,
      pattern: pattern,
      next: nil,
      cps: Keyword.get(opts, :cps, 0.5) / 1.0,
      origin_ms: now,
      origin_cycle: 0.0,
      scheduled: 0.0,
      clock: Keyword.get(opts, :clock, false),
      pulses: 0
    }

    Process.send_after(self(), :tick, 0)
    {:ok, state}
  end

  def init({port, score, opts, caller}) do
    Process.flag(:trap_exit, true)
    Process.monitor(caller)

    if program = Keyword.get(opts, :program) do
      Port.send(port, Message.program(program, opts))
    end

    state = %{
      port: port,
      opts: opts,
      loop: Keyword.get(opts, :loop, false),
      length: Score.duration(score),
      messages: messages(score, opts),
      started: System.monotonic_time(:millisecond),
      round: 0
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info({:send, bytes}, state) do
    Port.send(state.port, bytes)

    {:noreply, state}
  end

  def handle_info(:round, state) do
    if state.loop do
      {:noreply, schedule(%{state | round: state.round + 1})}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info(:tick, state) do
    until = elapsed(state) + @lookahead * state.cps
    state = state |> installed(until) |> pulsed(until)

    state.pattern
    |> pattern_messages(state.scheduled, until, Keyword.put(state.opts, :cps, 1.0))
    |> Enum.each(fn {cycle, bytes} ->
      Process.send_after(self(), {:send, bytes}, due_at(state, cycle))
    end)

    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, %{state | scheduled: until}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:stop, :normal, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:update_pattern, pattern, :now}, state),
    do: {:noreply, %{state | pattern: pattern, next: nil}}

  def handle_cast({:update_pattern, pattern, :cycle}, state),
    do: {:noreply, %{state | next: pattern}}

  def handle_cast({:cps, cps}, state) do
    now = System.monotonic_time(:millisecond)
    {:noreply, %{state | cps: cps, origin_ms: now, origin_cycle: elapsed(state)}}
  end

  @impl true
  def terminate(_reason, state) do
    if Map.get(state, :clock, false), do: Port.send(state.port, <<0xFC>>)
    Port.send(state.port, Message.hush(state.opts))

    :ok
  end

  defp elapsed(state) do
    state.origin_cycle +
      (System.monotonic_time(:millisecond) - state.origin_ms) / 1_000 * state.cps
  end

  defp due_at(state, cycle) do
    wanted = state.origin_ms + (cycle - state.origin_cycle) / state.cps * 1_000

    max(round(wanted) - System.monotonic_time(:millisecond), 0)
  end

  defp installed(%{next: nil} = state, _until), do: state

  defp installed(state, until) do
    if Float.floor(until) > Float.floor(state.scheduled),
      do: %{state | pattern: state.next, next: nil},
      else: state
  end

  defp pulsed(%{clock: false} = state, _until), do: state

  defp pulsed(state, until) do
    wanted = trunc(until * 96)

    for pulse <- state.pulses..(wanted - 1)//1 do
      Process.send_after(self(), {:send, <<0xF8>>}, due_at(state, pulse / 96))
    end

    %{state | pulses: max(wanted, state.pulses)}
  end

  defp schedule(state) do
    Enum.each(state.messages, fn {at, bytes} ->
      Process.send_after(self(), {:send, bytes}, due(state, at))
    end)

    Process.send_after(self(), :round, due(state, state.length))

    state
  end

  defp due(state, at) do
    wanted = round(state.started + (state.round * state.length + at) * 1_000)

    max(wanted - System.monotonic_time(:millisecond), 0)
  end
end

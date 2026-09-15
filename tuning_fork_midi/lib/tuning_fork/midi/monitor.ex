defmodule TuningFork.Midi.Monitor do
  @moduledoc """
  Both directions of MIDI in one process, for a front end: an input played on a stage and
  watched, an output a pattern or a tapped note goes out of, and every event of either
  reported to subscribers as it happens.

      {:ok, monitor} = TuningFork.Midi.Monitor.start_link()
      :ok = TuningFork.Midi.Monitor.subscribe(monitor, self())
      :ok = TuningFork.Midi.Monitor.open_input(monitor, 0)
      :ok = TuningFork.Midi.Monitor.open_output(monitor, {:virtual, "TuningFork"})
      :ok = TuningFork.Midi.Monitor.play(monitor, pattern, cps: 0.5, clock: true)
  """

  use GenServer

  alias TuningFork.Midi.{In, Message, Out, Port}
  alias TuningFork.{Pattern, Stage}

  @sustain 64
  @all_notes_off 123
  @kept_events 64
  @tap_ms 150

  @typedoc "A port to open: an index from `TuningFork.Midi.Port.inputs/0` or `outputs/0`, or a virtual port by name."
  @type port_choice :: non_neg_integer() | {:virtual, String.t()}

  @typedoc "An event of either direction, newest first in `t:state/0`'s `:events`."
  @type event :: {:in | :out, Message.event(), integer()}

  @typedoc """
  What the monitor is doing, as `state/1` gives it: `:input` and `:output` are
  `{index, name}`, `{:virtual, name}` or `nil`; `:keys` the notes held on the input with
  their velocities; `:sounding` the notes the output has on; `:controls` the last value of
  each controller heard; `:events` the last #{@kept_events}, newest first.
  """
  @type state :: %{
          input: {non_neg_integer(), String.t()} | {:virtual, String.t()} | nil,
          output: {non_neg_integer(), String.t()} | {:virtual, String.t()} | nil,
          voice: term(),
          keys: %{non_neg_integer() => non_neg_integer()},
          sounding: [non_neg_integer()],
          pedal: boolean(),
          bend: integer(),
          controls: %{non_neg_integer() => non_neg_integer()},
          program: non_neg_integer() | nil,
          playing: boolean(),
          cps: float(),
          clock: boolean(),
          events: [event()]
        }

  @doc """
  Start a monitor.

  Options: `:stage` — the `TuningFork.Stage` the input is played on, default the one named
  `TuningFork.Stage`, `nil` for none; `:voice` — what the input plays, as
  `TuningFork.Midi.In` takes it, default `"gm_piano"`; `:name` — a name to register under.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "The inputs on this machine, as `TuningFork.Midi.Port.inputs/0` lists them, `[]` without MIDI."
  @spec inputs() :: [{non_neg_integer(), String.t()}]
  def inputs, do: listed(Port.inputs())

  @doc "The outputs on this machine, as `TuningFork.Midi.Port.outputs/0` lists them, `[]` without MIDI."
  @spec outputs() :: [{non_neg_integer(), String.t()}]
  def outputs, do: listed(Port.outputs())

  @doc "Open an input and play it, closing any input open before. `{:error, reason}` when it will not open."
  @spec open_input(GenServer.server(), port_choice()) :: :ok | {:error, term()}
  def open_input(monitor, choice), do: GenServer.call(monitor, {:open_input, choice})

  @doc "Close the input, letting every held note go."
  @spec close_input(GenServer.server()) :: :ok
  def close_input(monitor), do: GenServer.call(monitor, :close_input)

  @doc "Open an output, closing any output open before and stopping what played out of it."
  @spec open_output(GenServer.server(), port_choice()) :: :ok | {:error, term()}
  def open_output(monitor, choice), do: GenServer.call(monitor, {:open_output, choice})

  @doc "Close the output, stopping what played out of it."
  @spec close_output(GenServer.server()) :: :ok
  def close_output(monitor), do: GenServer.call(monitor, :close_output)

  @doc "What the input plays from here on, as `TuningFork.Midi.In`'s `:voice`."
  @spec voice(GenServer.server(), term()) :: :ok | {:error, term()}
  def voice(monitor, voice), do: GenServer.call(monitor, {:voice, voice})

  @doc """
  Play `pattern` out of the output with `TuningFork.Midi.Out.pattern/3`, taking its options,
  in place of whatever was playing. `{:error, :no_output}` with no output open.
  """
  @spec play(GenServer.server(), Pattern.t(), keyword()) :: :ok | {:error, term()}
  def play(monitor, %Pattern{} = pattern, opts \\ []),
    do: GenServer.call(monitor, {:play, pattern, opts})

  @doc "Swap the pattern playing out, at the next cycle line or `at: :now`."
  @spec update(GenServer.server(), Pattern.t(), keyword()) :: :ok | {:error, term()}
  def update(monitor, %Pattern{} = pattern, opts \\ []),
    do: GenServer.call(monitor, {:update, pattern, opts})

  @doc "Change the cycles per second of the pattern playing out."
  @spec cps(GenServer.server(), number()) :: :ok | {:error, term()}
  def cps(monitor, cps) when cps > 0, do: GenServer.call(monitor, {:cps, cps / 1.0})

  @doc "Stop the pattern playing out, every note off."
  @spec stop(GenServer.server()) :: :ok
  def stop(monitor), do: GenServer.call(monitor, :stop)

  @doc """
  Send one note out — on now, off after `:hold` milliseconds, default #{@tap_ms} — on
  `:channel`, default 1. `{:error, :no_output}` with no output open.
  """
  @spec tap(GenServer.server(), non_neg_integer(), non_neg_integer(), keyword()) ::
          :ok | {:error, term()}
  def tap(monitor, note, velocity \\ 100, opts \\ []),
    do: GenServer.call(monitor, {:tap, note, velocity, opts})

  @doc "Send raw `bytes` out. `{:error, :no_output}` with no output open."
  @spec send_bytes(GenServer.server(), binary()) :: :ok | {:error, term()}
  def send_bytes(monitor, bytes) when is_binary(bytes),
    do: GenServer.call(monitor, {:send, bytes})

  @doc """
  Have `pid` sent `{:midi_monitor, monitor, :in | :out, event, monotonic_nanoseconds}` for
  every event from here on, and `{:midi_monitor, monitor, :changed}` when a port opens or
  closes or playing starts or stops.
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(monitor, pid \\ self()), do: GenServer.call(monitor, {:subscribe, pid})

  @doc "Stop sending events to `pid`."
  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(monitor, pid \\ self()), do: GenServer.call(monitor, {:unsubscribe, pid})

  @doc "What the monitor is doing now."
  @spec state(GenServer.server()) :: state()
  def state(monitor), do: GenServer.call(monitor, :state)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       stage: Keyword.get(opts, :stage, Stage),
       voice: Keyword.get(opts, :voice, "gm_piano"),
       input: nil,
       listener: nil,
       output: nil,
       port: nil,
       player: nil,
       playing: false,
       cps: 0.5,
       clock: false,
       keys: %{},
       sounding: MapSet.new(),
       pedal: false,
       bend: 0,
       controls: %{},
       program: nil,
       events: [],
       subscribers: %{}
     }}
  end

  @impl true
  def handle_call({:open_input, choice}, _from, state) do
    state = drop_listener(state)

    case In.start_link(port: choice, stage: state.stage, voice: state.voice, to: self()) do
      {:ok, listener} ->
        state = %{state | listener: listener, input: named(choice, inputs())}
        {:reply, :ok, changed(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, changed(state)}
    end
  end

  def handle_call(:close_input, _from, state),
    do: {:reply, :ok, state |> drop_listener() |> changed()}

  def handle_call({:open_output, choice}, _from, state) do
    state = drop_port(state)

    case open_port(choice) do
      {:ok, port} ->
        state = %{state | port: port, output: named(choice, outputs())}
        {:reply, :ok, changed(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, changed(state)}
    end
  end

  def handle_call(:close_output, _from, state),
    do: {:reply, :ok, state |> drop_port() |> changed()}

  def handle_call({:voice, voice}, from, %{listener: nil} = state) do
    handle_call(:state, from, %{state | voice: voice})
    |> then(fn {:reply, _s, s} -> {:reply, :ok, s} end)
  end

  def handle_call({:voice, voice}, _from, state) do
    choice = choice_of(state.input)
    state = drop_listener(%{state | voice: voice})

    case In.start_link(port: choice, stage: state.stage, voice: voice, to: self()) do
      {:ok, listener} ->
        {:reply, :ok, changed(%{state | listener: listener, input: named(choice, inputs())})}

      {:error, reason} ->
        {:reply, {:error, reason}, changed(state)}
    end
  end

  def handle_call({:play, _pattern, _opts}, _from, %{port: nil} = state),
    do: {:reply, {:error, :no_output}, state}

  def handle_call({:play, pattern, opts}, _from, state) do
    state = drop_player(state)
    opts = Keyword.put(opts, :to, self())

    case Out.pattern(state.port, pattern, opts) do
      {:ok, player} ->
        state = %{
          state
          | player: player,
            playing: true,
            cps: Keyword.get(opts, :cps, 0.5) / 1.0,
            clock: Keyword.get(opts, :clock, false)
        }

        {:reply, :ok, changed(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update, _pattern, _opts}, _from, %{player: nil} = state),
    do: {:reply, {:error, :not_playing}, state}

  def handle_call({:update, pattern, opts}, _from, state) do
    {:reply, Out.update_pattern(state.player, pattern, opts), state}
  end

  def handle_call({:cps, _cps}, _from, %{player: nil} = state),
    do: {:reply, {:error, :not_playing}, state}

  def handle_call({:cps, cps}, _from, state) do
    {:reply, Out.pattern_cps(state.player, cps), changed(%{state | cps: cps})}
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, state |> drop_player() |> changed()}

  def handle_call({:tap, _note, _velocity, _opts}, _from, %{port: nil} = state),
    do: {:reply, {:error, :no_output}, state}

  def handle_call({:tap, note, velocity, opts}, _from, state) do
    channel = Keyword.get(opts, :channel, 1)
    off = Message.note_off(note, 0, channel: channel)
    Process.send_after(self(), {:send_out, off}, Keyword.get(opts, :hold, @tap_ms))

    {:reply, :ok, sent(state, Message.note_on(note, velocity, channel: channel))}
  end

  def handle_call({:send, _bytes}, _from, %{port: nil} = state),
    do: {:reply, {:error, :no_output}, state}

  def handle_call({:send, bytes}, _from, state), do: {:reply, :ok, sent(state, bytes)}

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, forget(state, pid)}
  end

  def handle_call(:state, _from, state), do: {:reply, public(state), state}

  @impl true
  def handle_info({:midi, event}, state) do
    {:noreply, state |> heard(event) |> noted(:in, event, System.monotonic_time(:nanosecond))}
  end

  def handle_info({:midi_out, _player, bytes, at}, state) do
    {:noreply,
     bytes
     |> Message.parse_all()
     |> Enum.reduce(state, &(&2 |> played(&1) |> noted(:out, &1, at)))}
  end

  def handle_info({:send_out, _bytes}, %{port: nil} = state), do: {:noreply, state}
  def handle_info({:send_out, bytes}, state), do: {:noreply, sent(state, bytes)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, forget(state, pid)}

  def handle_info({:EXIT, pid, _reason}, %{listener: pid} = state) do
    {:noreply, changed(%{state | listener: nil, input: nil, keys: %{}, pedal: false})}
  end

  def handle_info({:EXIT, pid, _reason}, %{player: pid} = state) do
    {:noreply, changed(%{state | player: nil, playing: false, sounding: MapSet.new()})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state |> drop_player() |> drop_listener() |> drop_port()
    :ok
  end

  defp listed({:ok, ports}), do: Enum.map(ports, fn {index, name} -> {index, to_string(name)} end)
  defp listed({:error, _reason}), do: []

  defp named({:virtual, name}, _ports), do: {:virtual, name}

  defp named(index, ports) when is_integer(index) do
    {index, Enum.find_value(ports, "port #{index}", fn {i, name} -> if i == index, do: name end)}
  end

  defp choice_of({:virtual, name}), do: {:virtual, name}
  defp choice_of({index, _name}), do: index
  defp choice_of(nil), do: nil

  defp open_port({:virtual, name}), do: Port.open_virtual_output(name)
  defp open_port(index) when is_integer(index), do: Port.open_output(index)

  defp drop_listener(%{listener: nil} = state), do: state

  defp drop_listener(%{listener: listener} = state) do
    Process.unlink(listener)
    if Process.alive?(listener), do: In.stop(listener)
    %{state | listener: nil, input: nil, keys: %{}, pedal: false}
  end

  defp drop_player(%{player: nil} = state), do: state

  defp drop_player(%{player: player} = state) do
    Process.unlink(player)
    Out.stop(player)
    %{state | player: nil, playing: false, sounding: MapSet.new()}
  end

  defp drop_port(state) do
    state = drop_player(state)
    if state.port, do: Port.close(state.port)
    %{state | port: nil, output: nil, sounding: MapSet.new()}
  end

  defp sent(state, bytes) do
    Port.send(state.port, bytes)
    at = System.monotonic_time(:nanosecond)

    bytes
    |> Message.parse_all()
    |> Enum.reduce(state, &(&2 |> played(&1) |> noted(:out, &1, at)))
  end

  defp heard(state, {:note_on, _channel, note, velocity}),
    do: %{state | keys: Map.put(state.keys, note, velocity)}

  defp heard(state, {:note_off, _channel, note, _velocity}),
    do: %{state | keys: Map.delete(state.keys, note)}

  defp heard(state, {:control, _channel, @sustain, value}) do
    %{state | pedal: value >= 64, controls: Map.put(state.controls, @sustain, value)}
  end

  defp heard(state, {:control, _channel, controller, value}),
    do: %{state | controls: Map.put(state.controls, controller, value)}

  defp heard(state, {:bend, _channel, amount}), do: %{state | bend: amount}
  defp heard(state, {:program, _channel, program}), do: %{state | program: program}
  defp heard(state, _other), do: state

  defp played(state, {:note_on, _channel, note, velocity}) when velocity > 0,
    do: %{state | sounding: MapSet.put(state.sounding, note)}

  defp played(state, {:note_on, _channel, note, _silent}),
    do: %{state | sounding: MapSet.delete(state.sounding, note)}

  defp played(state, {:note_off, _channel, note, _velocity}),
    do: %{state | sounding: MapSet.delete(state.sounding, note)}

  defp played(state, {:control, _channel, @all_notes_off, _value}),
    do: %{state | sounding: MapSet.new()}

  defp played(state, _other), do: state

  defp noted(state, side, event, at) do
    tell(state, {:midi_monitor, self(), side, event, at})
    %{state | events: Enum.take([{side, event, at} | state.events], @kept_events)}
  end

  defp changed(state) do
    tell(state, {:midi_monitor, self(), :changed})
    state
  end

  defp tell(state, message), do: Enum.each(Map.keys(state.subscribers), &send(&1, message))

  defp forget(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush]) && %{state | subscribers: subscribers}
    end
  end

  defp public(state) do
    state
    |> Map.take([
      :input,
      :output,
      :voice,
      :keys,
      :pedal,
      :bend,
      :controls,
      :program,
      :playing,
      :cps,
      :clock,
      :events
    ])
    |> Map.put(:sounding, state.sounding |> MapSet.to_list() |> Enum.sort())
  end
end

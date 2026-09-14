defmodule TuningFork.Midi.In do
  @moduledoc """
  Plays a MIDI input on a `TuningFork.Stage`: a keyboard held on a synth or a sampled
  instrument, with the sustain pedal, and every event passed on to a process that wants it.

      {:ok, _listener} = TuningFork.Midi.In.start_link(port: 0, voice: "gm_piano")
      {:ok, _listener} = TuningFork.Midi.In.start_link(port: {:virtual, "tuning_fork"}, voice: %{shape: :saw}, to: self())
  """

  use GenServer

  alias TuningFork.{Kit, Stage, Voice}
  alias TuningFork.Midi.{Message, Port}

  @sustain 64

  @doc """
  Open an input and start playing it.

  ## Options

    * `:port` — the index from `TuningFork.Midi.Port.inputs/0`, or `{:virtual, name}` for a
      port of this name that other applications can send into. Without one, nothing is
      opened and the listener plays whatever `{:midi_in, port, bytes, time}` messages are
      sent to it, as `TuningFork.Midi.Port.open_input/2` delivers them
    * `:stage` — the `TuningFork.Stage` to play on, default the one named `TuningFork.Stage`;
      `nil` to play nothing and only pass events on
    * `:voice` — what a note plays: a sound name such as `"gm_piano"` or `"sawtooth"`, a map
      of controls as `TuningFork.Kit.voice/3` takes with `:note` and `:gain` filled in from
      the key and velocity, or a function of `note, velocity` returning a `TuningFork.Voice`.
      Default `%{shape: :triangle}`
    * `:channel` — take only this MIDI channel, 1 to 16; default every channel
    * `:to` — a process sent `{:midi, event}` for every event read, as
      `TuningFork.Midi.Message.parse/1` gives them
    * `:name` — a name to register under

  The listener is linked to the caller. `{:error, reason}` when the port will not open.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "Stop listening, letting every held note go."
  @spec stop(GenServer.server()) :: :ok
  def stop(listener), do: GenServer.stop(listener, :normal)

  @impl true
  def init(opts) do
    with {:ok, port} <- open(Keyword.get(opts, :port)) do
      {:ok,
       %{
         port: port,
         stage: Keyword.get(opts, :stage, Stage),
         voice: Keyword.get(opts, :voice, %{shape: :triangle}),
         channel: Keyword.get(opts, :channel),
         to: Keyword.get(opts, :to),
         held: MapSet.new(),
         pedal: MapSet.new(),
         sustained: false
       }}
    end
  end

  @impl true
  def handle_info({:midi_in, _port, bytes, _time}, state) do
    {:noreply, bytes |> Message.parse_all() |> Enum.reduce(state, &event/2)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(MapSet.union(state.held, state.pedal), &Stage.release(state.stage, &1))
    if state.port, do: Port.close(state.port)
    :ok
  end

  defp open(nil), do: {:ok, nil}
  defp open({:virtual, name}), do: listened(Port.open_virtual_input(name, self()))
  defp open(index) when is_integer(index), do: listened(Port.open_input(index, self()))

  defp listened({:ok, port}) do
    case Port.listen(port) do
      :ok -> {:ok, port}
      {:error, reason} -> {:error, reason}
    end
  end

  defp listened({:error, reason}), do: {:error, reason}

  defp event(event, state) do
    if wanted?(event, state.channel) do
      if state.to, do: send(state.to, {:midi, event})
      played(event, state)
    else
      state
    end
  end

  defp wanted?(_event, nil), do: true
  defp wanted?(event, channel) when is_tuple(event), do: elem(event, 1) == channel
  defp wanted?(_realtime, _channel), do: true

  defp played(_event, %{stage: nil} = state), do: state

  defp played({:note_on, channel, note, velocity}, state) do
    key = {channel, note}
    Stage.hold(state.stage, key, voice(state.voice, note, velocity))

    %{state | held: MapSet.put(state.held, key), pedal: MapSet.delete(state.pedal, key)}
  end

  defp played({:note_off, channel, note, _velocity}, %{sustained: true} = state) do
    key = {channel, note}
    %{state | held: MapSet.delete(state.held, key), pedal: MapSet.put(state.pedal, key)}
  end

  defp played({:note_off, channel, note, _velocity}, state) do
    key = {channel, note}
    Stage.release(state.stage, key)
    %{state | held: MapSet.delete(state.held, key)}
  end

  defp played({:control, _channel, @sustain, value}, state) when value >= 64,
    do: %{state | sustained: true}

  defp played({:control, _channel, @sustain, _up}, state) do
    Enum.each(state.pedal, &Stage.release(state.stage, &1))
    %{state | sustained: false, pedal: MapSet.new()}
  end

  defp played(_other, state), do: state

  defp voice(fun, note, velocity) when is_function(fun, 2), do: fun.(note, velocity)

  defp voice(%Voice{} = voice, note, velocity) do
    %{voice | freq: 440.0 * :math.pow(2.0, (note - 69) / 12.0), gain: voice.gain * velocity / 127}
  end

  defp voice(%{} = controls, note, velocity) do
    Kit.voice(Map.merge(controls, %{note: note, gain: velocity / 127}), 1.0, wait: false)
  end

  defp voice(sound, note, velocity) when is_binary(sound),
    do: voice(%{sound: sound}, note, velocity)
end

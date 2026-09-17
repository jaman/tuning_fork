defmodule TuningFork.Stage do
  @moduledoc """
  A process that mixes sounding voices, loops, patterns and scores into one stream and
  writes it to a `TuningFork.Sink`.

      {:ok, _pid} = TuningFork.Stage.start_link(sink: TuningFork.Sink.Speaker)
      TuningFork.Stage.play(TuningFork.Voice.new(freq: 440.0))
  """

  use GenServer

  require Logger

  alias TuningFork.{Fx, Kit, Mixer, Pattern, Score, Store, Transport, Voice}
  alias TuningFork.Pattern.{Ahead, Player}
  alias TuningFork.Stage.Bed

  @type t :: GenServer.server()

  defstruct [
    :sink,
    :sink_state,
    :rate,
    :chunk,
    :channels,
    :voices,
    :writer,
    sounding: [],
    bed: nil,
    bed_gain: 1.0,
    muted: false,
    transport: nil,
    frame: 0,
    loops: %{},
    bodies: %{},
    waiting: %{},
    player: nil,
    pattern_gain: 1.0,
    fx: nil,
    limit: 0.7,
    scope: 4_096,
    last: nil,
    level: 0.0
  ]

  @doc """
  Start a stage, linked to the caller.

  A sink that will not open is logged and replaced by `TuningFork.Sink.Silent`; the stage
  still keeps time.

  ## Options

    * `:name` — the registered name, default `TuningFork.Stage`
    * `:rate` — samples per second, default 44100
    * `:chunk` — frames per write, default 512
    * `:channels` — 2 for stereo, the default, or 1 for mono. Passed to the sink as well
    * `:sink` — a `TuningFork.Sink`, default `TuningFork.Sink.configured/0`
    * `:sink_opts` — passed to the sink's `open/1`, with `:rate` and `:channels` filled in
    * `:voices` — most voices sounding at once, default 16. Past that the oldest are dropped
    * `:fx` — effects over everything the stage produces, as `[reverb: [...]]`, taking what
      `TuningFork.Fx.Live.new/3` takes
    * `:limit` — the threshold `TuningFork.Mixer.soft_clip/2` rounds peaks off above, 0.0
      to 1.0, default 0.7; `nil` for none
    * `:scope` — frames of recent audio kept for `scope/2`, default 4096
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Sound a voice. Returns immediately; the voice is rendered in the stage. Ignored while muted."
  @spec play(t(), Voice.t()) :: :ok
  def play(stage \\ __MODULE__, %Voice{} = voice) do
    GenServer.cast(stage, {:play, voice})
  end

  @doc """
  Sound `voice` and keep it sounding under `key` until `release/3`, however long its
  envelope's hold is. A voice already held under `key` is released first. Ignored while
  muted.

      Stage.hold(stage, {1, 60}, Kit.voice(%{note: 60, s: "gm_piano"}, 1.0))
      Stage.release(stage, {1, 60})
  """
  @spec hold(t(), term(), Voice.t()) :: :ok
  def hold(stage \\ __MODULE__, key, %Voice{} = voice) do
    GenServer.cast(stage, {:hold, key, voice})
  end

  @doc """
  Let the voice held under `key` go, fading over `seconds` (default 0.05) from where it is.
  Nothing happens when no voice is held under `key`.
  """
  @spec release(t(), term(), number()) :: :ok
  def release(stage \\ __MODULE__, key, seconds \\ 0.05) do
    GenServer.cast(stage, {:release, key, seconds})
  end

  @doc """
  Sound already-rendered PCM.

  It must be at the stage's rate and channel count. Ignored while muted.
  """
  @spec play_pcm(t(), binary()) :: :ok
  def play_pcm(stage \\ __MODULE__, pcm) when is_binary(pcm) do
    GenServer.cast(stage, {:play_pcm, pcm})
  end

  @doc """
  Loop `pcm` underneath everything else, replacing any bed already playing.

  `pcm` must be at the stage's rate and channel count. It is read by sample position and
  wraps where the buffer ends, however short it is. An empty binary clears the bed.
  """
  @spec bed(t(), binary()) :: :ok
  def bed(stage \\ __MODULE__, pcm) when is_binary(pcm) do
    GenServer.cast(stage, {:bed, pcm})
  end

  @doc "Stop the bed. Anything sounding over it keeps playing."
  @spec clear_bed(t()) :: :ok
  def clear_bed(stage \\ __MODULE__), do: GenServer.cast(stage, {:bed, <<>>})

  @doc """
  Loop a set of named layers underneath everything else, all read from one playhead.

  `layers` maps a name to PCM at the stage's rate and channel count; each wraps at its
  own length. The set replaces the one playing unless `keep: true`, which merges into it.
  `bed/2` is the same as a set with one layer named `:bed`.

  ## Options

    * `:gains` — a map from name to 0.0..1.0, default 1.0 for every layer
    * `:keep` — merge into the playing set instead of replacing it. Default `false`
    * `:at` — `{:bar, frames}` delays the change until the playhead next reaches a
      multiple of `frames`. Default: at once
    * `:fade_ms` — cross-fade from the old set to the new over this many milliseconds.
      Default `0`
  """
  @spec layers(t(), %{term() => binary()}, keyword()) :: :ok
  def layers(stage \\ __MODULE__, layers, opts \\ []) when is_map(layers) do
    GenServer.cast(stage, {:layers, layers, opts})
  end

  @doc "Set the gain of the named layers, 0.0 to 1.0, from the next chunk."
  @spec layer_gains(t(), %{term() => number()}) :: :ok
  def layer_gains(stage \\ __MODULE__, gains) when is_map(gains) do
    GenServer.cast(stage, {:layer_gains, gains})
  end

  @doc "The playhead of the layer set, in frames since it started, or `nil` with no set."
  @spec bed_position(t()) :: non_neg_integer() | nil
  def bed_position(stage \\ __MODULE__), do: GenServer.call(stage, :bed_position)

  @doc """
  Set how loud the bed is, from 0.0 to 1.0, from the next chunk. Values outside that range
  are clamped.
  """
  @spec bed_gain(t(), float()) :: :ok
  def bed_gain(stage \\ __MODULE__, gain) do
    GenServer.cast(stage, {:bed_gain, gain / 1.0})
  end

  @doc "Silence everything currently sounding. The bed and any transport keep going."
  @spec stop_all(t()) :: :ok
  def stop_all(stage \\ __MODULE__), do: GenServer.cast(stage, :stop_all)

  @doc """
  Set whether `play/2` and `play_pcm/2` are ignored. Muting does not silence what is already
  sounding or affect the bed.
  """
  @spec mute(t(), boolean()) :: :ok
  def mute(stage \\ __MODULE__, muted?), do: GenServer.cast(stage, {:mute, muted?})

  @doc """
  Play a score in time, note by note, replacing any score already playing.

  `opts` are `TuningFork.Transport.new/3`'s: `:loop` and `:playing`. A transport that reaches
  the end without looping is dropped.
  """
  @spec start_score(t(), Score.t(), keyword()) :: :ok
  def start_score(stage \\ __MODULE__, %Score{} = score, opts \\ []) do
    GenServer.cast(stage, {:start_score, score, opts})
  end

  @doc "Stop the transport. Anything it has already started is left to finish sounding."
  @spec stop_score(t()) :: :ok
  def stop_score(stage \\ __MODULE__), do: GenServer.cast(stage, :stop_score)

  @doc """
  Start a named loop, playing `score` round and round from its own beat zero.

      Stage.start_loop(stage, :bass, Score.from_parts([bass]))

  Starting a loop under a name already running replaces it from the next chunk. `opts` are
  `TuningFork.Transport.new/3`'s, with `:loop` defaulting to true, and one more:

    * `:body` — a zero-arity function returning `{:ok, score}` or `{:error, reason}`, run
      once for each round to give the next round's score. It is run in its own process
      during the round before; a body that raises, returns an error or does not finish in
      time leaves the loop playing what it played last
  """
  @spec start_loop(t(), term(), Score.t(), keyword()) :: :ok
  def start_loop(name, %Score{} = score), do: start_loop(__MODULE__, name, score, [])

  def start_loop(name, %Score{} = score, opts) when is_list(opts) do
    start_loop(__MODULE__, name, score, opts)
  end

  def start_loop(stage, name, %Score{} = score), do: start_loop(stage, name, score, [])

  def start_loop(stage, name, %Score{} = score, opts) do
    GenServer.cast(stage, {:start_loop, name, score, opts})
  end

  @doc """
  Swap a loop's score without moving where it has got to.

  `at: :round`, the default, holds the new score until the loop comes round; `at: :now` takes
  effect on the next chunk. `:body` replaces the loop's body. Ignored for a name that is not
  running.
  """
  @spec update_loop(t(), term(), Score.t(), keyword()) :: :ok
  def update_loop(name, %Score{} = score), do: update_loop(__MODULE__, name, score, [])

  def update_loop(name, %Score{} = score, opts) when is_list(opts) do
    update_loop(__MODULE__, name, score, opts)
  end

  def update_loop(stage, name, %Score{} = score), do: update_loop(stage, name, score, [])

  def update_loop(stage, name, %Score{} = score, opts) do
    GenServer.cast(stage, {:update_loop, name, score, opts})
  end

  @doc "Stop one loop. What it has already started is left to finish sounding."
  @spec stop_loop(t(), term()) :: :ok
  def stop_loop(stage \\ __MODULE__, name), do: GenServer.cast(stage, {:stop_loop, name})

  @doc "Stop every loop at once."
  @spec stop_loops(t()) :: :ok
  def stop_loops(stage \\ __MODULE__), do: GenServer.cast(stage, :stop_loops)

  @doc """
  Every loop running, as `%{name => %{beat: beat, rounds: rounds, pending?: boolean}}`.

  `rounds` is how many times that loop has been round; `pending?` is whether a swapped score
  is waiting for the next round.
  """
  @spec loops(t()) :: %{
          term() => %{beat: float(), rounds: non_neg_integer(), pending?: boolean()}
        }
  def loops(stage \\ __MODULE__), do: GenServer.call(stage, :loops)

  @doc """
  Block until loop `name` next comes round.

  Returns `:ok` when it does, `{:error, :no_such_loop}` at once when nothing is running under
  that name, or `{:error, :timeout}` after `timeout` milliseconds. A loop that is not looping
  never comes round.
  """
  @spec after_round(t(), term(), timeout()) :: :ok | {:error, :no_such_loop | :timeout}
  def after_round(stage \\ __MODULE__, name, timeout \\ 30_000) do
    GenServer.call(stage, {:after_round, name}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
  end

  @doc """
  Play a `TuningFork.Pattern` from cycle zero until `stop_pattern/1`, replacing any pattern
  already playing.

  `opts` are `TuningFork.Pattern.Player.new/3`'s: `:cps`, `:voice`, `:voices` and
  `:parallel`. The
  pattern is synthesised in a process of its own (`TuningFork.Pattern.Ahead`), a few
  chunks ahead of the stream, so a change to it — `update_pattern/3`, `pattern_gain/2`,
  `pattern_cps/2`, `hush/1` — sounds within those chunks, and `cycle/1` reports the
  place the synthesis has reached.
  """
  @spec start_pattern(t(), Pattern.t(), keyword()) :: :ok
  def start_pattern(%Pattern{} = pattern), do: start_pattern(__MODULE__, pattern, [])

  def start_pattern(%Pattern{} = pattern, opts) when is_list(opts) do
    start_pattern(__MODULE__, pattern, opts)
  end

  def start_pattern(stage, %Pattern{} = pattern), do: start_pattern(stage, pattern, [])

  def start_pattern(stage, %Pattern{} = pattern, opts) do
    GenServer.cast(stage, {:start_pattern, pattern, opts})
  end

  @doc """
  Swap the playing pattern without moving the position.

  `opts` are `TuningFork.Pattern.Player.update/3`'s: `at: :cycle`, the default, holds it until
  the next cycle line; `at: :now` takes effect on the next chunk. Ignored when no pattern is
  playing.
  """
  @spec update_pattern(t(), Pattern.t(), keyword()) :: :ok
  def update_pattern(%Pattern{} = pattern), do: update_pattern(__MODULE__, pattern, [])

  def update_pattern(%Pattern{} = pattern, opts) when is_list(opts) do
    update_pattern(__MODULE__, pattern, opts)
  end

  def update_pattern(stage, %Pattern{} = pattern), do: update_pattern(stage, pattern, [])

  def update_pattern(stage, %Pattern{} = pattern, opts) do
    GenServer.cast(stage, {:update_pattern, pattern, opts})
  end

  @doc "Stop the pattern. Anything it has already started is left to finish sounding."
  @spec stop_pattern(t()) :: :ok
  def stop_pattern(stage \\ __MODULE__), do: GenServer.cast(stage, :stop_pattern)

  @doc "Run the pattern at a different speed, in cycles per second, keeping its place."
  @spec pattern_cps(t(), number()) :: :ok
  def pattern_cps(stage \\ __MODULE__, cps) when cps > 0 do
    GenServer.cast(stage, {:pattern_cps, cps})
  end

  @doc "Scale the pattern's whole output by `gain`, sounding notes included, from the next chunk; kept for patterns started later."
  @spec pattern_gain(t(), number()) :: :ok
  def pattern_gain(stage \\ __MODULE__, gain) when gain >= 0 do
    GenServer.cast(stage, {:pattern_gain, gain})
  end

  @doc """
  Run the pattern at `cpm` cycles per minute, keeping its place.
  """
  @spec pattern_cpm(t(), number()) :: :ok
  def pattern_cpm(stage \\ __MODULE__, cpm) when cpm > 0 do
    pattern_cps(stage, cps_of(cpm))
  end

  @doc """
  Cycles per second from cycles per minute.

      iex> TuningFork.Stage.cps_of(120)
      2.0
  """
  @spec cps_of(number()) :: float()
  def cps_of(cpm) when cpm > 0, do: cpm / 60.0

  @doc "Cycles per minute from cycles per second."
  @spec cpm_of(number()) :: float()
  def cpm_of(cps) when cps > 0, do: cps * 60.0

  @doc """
  Silence everything the pattern has already started, without stopping the pattern.
  """
  @spec hush(t()) :: :ok
  def hush(stage \\ __MODULE__), do: GenServer.cast(stage, :hush)

  @doc """
  Where the pattern has reached, in cycles, or `nil` when none is playing.

  Whole numbers are cycle lines, so `3.75` is three quarters of the way through cycle three.
  """
  @spec cycle(t()) :: float() | nil
  def cycle(stage \\ __MODULE__), do: GenServer.call(stage, :cycle)

  @doc """
  The peak sample of the last chunk written to the sink, after effects and limiting, 0.0 to
  1.0. `0.0` before anything has been written.
  """
  @spec level(t()) :: float()
  def level(stage \\ __MODULE__), do: GenServer.call(stage, :level)

  @doc """
  The last `:scope` frames of the left channel as written to the sink, aligned to a rising
  zero crossing and thinned to `points` samples from -1.0 to 1.0. `[]` before anything has
  been written.
  """
  @spec scope(t(), pos_integer()) :: [float()]
  def scope(stage \\ __MODULE__, points \\ 128) do
    GenServer.call(stage, {:scope, points})
  end

  @doc """
  Swap the playing score without moving the position.

  Heard from the next chunk. Notes already sounding finish as they were. Ignored when no
  score is playing.
  """
  @spec update_score(t(), Score.t()) :: :ok
  def update_score(stage \\ __MODULE__, %Score{} = score) do
    GenServer.cast(stage, {:update_score, score})
  end

  @doc "Which beat the transport is on, or `nil` if no score is playing."
  @spec beat(t()) :: float() | nil
  def beat(stage \\ __MODULE__), do: GenServer.call(stage, :beat)

  @doc "How many voices are sounding right now, the transport's included."
  @spec sounding(t()) :: non_neg_integer()
  def sounding(stage \\ __MODULE__), do: GenServer.call(stage, :sounding)

  @impl true
  def init(opts) do
    sink = Keyword.get(opts, :sink) || TuningFork.Sink.configured()
    rate = Keyword.get(opts, :rate, 44_100)
    chunk = Keyword.get(opts, :chunk, 512)
    channels = Keyword.get(opts, :channels, 2)

    sink_opts =
      opts
      |> Keyword.get(:sink_opts, [])
      |> Keyword.put_new(:rate, rate)
      |> Keyword.put_new(:channels, channels)

    state = %__MODULE__{
      sink: sink,
      rate: rate,
      chunk: chunk,
      channels: channels,
      voices: Keyword.get(opts, :voices, 16),
      limit: Keyword.get(opts, :limit, 0.7),
      scope: Keyword.get(opts, :scope, 4_096),
      fx: live_fx(Keyword.get(opts, :fx, []), rate, channels)
    }

    case sink.open(sink_opts) do
      {:ok, sink_state} ->
        state = %{state | sink_state: sink_state}
        {:ok, %{state | writer: start_writer(state)}}

      {:error, reason} ->
        Logger.info(
          "tuning_fork: #{inspect(sink)} unavailable (#{inspect(reason)}), staying silent"
        )

        silent = %{state | sink: TuningFork.Sink.Silent, sink_state: :silent}
        {:ok, %{silent | writer: start_writer(silent)}}
    end
  end

  @impl true
  def handle_cast({:play, _voice}, %{muted: true} = state), do: {:noreply, state}

  def handle_cast({:play, voice}, state) do
    {:noreply, add(state, Voice.Live.start(voice, state.rate))}
  end

  def handle_cast({:hold, _key, _voice}, %{muted: true} = state), do: {:noreply, state}

  def handle_cast({:hold, key, voice}, state) do
    live = Voice.Live.start(%{voice | envelope: held(voice.envelope)}, state.rate)

    {:noreply, state |> let_go(key, 0.05) |> add({key, live})}
  end

  def handle_cast({:release, key, seconds}, state), do: {:noreply, let_go(state, key, seconds)}

  def handle_cast({:play_pcm, _pcm}, %{muted: true} = state), do: {:noreply, state}
  def handle_cast({:play_pcm, pcm}, state), do: {:noreply, add(state, pcm)}

  def handle_cast({:bed, <<>>}, state), do: {:noreply, %{state | bed: nil}}

  def handle_cast({:bed, pcm}, state),
    do: {:noreply, %{state | bed: Bed.replace(state.bed, %{bed: pcm}, [])}}

  def handle_cast({:layers, layers, opts}, state) do
    {:noreply,
     %{state | bed: Bed.replace(state.bed, layers, Keyword.put(opts, :rate, state.rate))}}
  end

  def handle_cast({:layer_gains, gains}, state) do
    {:noreply, %{state | bed: Bed.gains(state.bed, gains)}}
  end

  def handle_cast({:bed_gain, gain}, state) do
    {:noreply, %{state | bed_gain: max(0.0, min(1.0, gain))}}
  end

  def handle_cast(:stop_all, state), do: {:noreply, %{state | sounding: []}}
  def handle_cast({:mute, muted?}, state), do: {:noreply, %{state | muted: muted?}}

  def handle_cast({:start_score, score, opts}, state) do
    {:noreply, %{state | transport: Transport.new(score, state.rate, opts)}}
  end

  def handle_cast(:stop_score, state), do: {:noreply, %{state | transport: nil}}

  def handle_cast({:start_loop, name, score, opts}, state) do
    {body, opts} = Keyword.pop(opts, :body)
    opts = Keyword.put_new(opts, :loop, true)

    state = put_in(state.loops[name], Transport.new(score, state.rate, opts))
    state = renew(state, name, body)

    {:noreply, state}
  end

  def handle_cast({:update_loop, name, score, opts}, state) do
    case Map.fetch(state.loops, name) do
      :error ->
        {:noreply, state}

      {:ok, transport} ->
        {body, opts} = Keyword.pop(opts, :body)
        at = Keyword.get(opts, :at, :round)

        state = put_in(state.loops[name], Transport.update(transport, score, at: at))

        {:noreply, if(body, do: renew(state, name, body), else: state)}
    end
  end

  def handle_cast({:round_ready, name, round, score}, state) do
    case Map.fetch(state.loops, name) do
      {:ok, transport} ->
        if Transport.rounds(transport) == round do
          {:noreply, put_in(state.loops[name], Transport.update(transport, score, at: :round))}
        else
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_cast({:stop_loop, name}, state) do
    {:noreply,
     %{state | loops: Map.delete(state.loops, name), bodies: Map.delete(state.bodies, name)}}
  end

  def handle_cast(:stop_loops, state), do: {:noreply, %{state | loops: %{}, bodies: %{}}}

  def handle_cast({:start_pattern, pattern, opts}, state) do
    stop_ahead(state.player)

    player =
      pattern |> Player.new(state.rate, live_voice(opts)) |> Player.gain(state.pattern_gain)

    {:ok, ahead} = Ahead.start_link(player: player, chunk: state.chunk, channels: state.channels)
    {:noreply, %{state | player: ahead}}
  end

  def handle_cast({:update_pattern, _pattern, _opts}, %{player: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:update_pattern, pattern, opts}, state) do
    Ahead.apply(state.player, &Player.update(&1, pattern, opts))
    {:noreply, state}
  end

  def handle_cast(:stop_pattern, state) do
    stop_ahead(state.player)
    {:noreply, %{state | player: nil}}
  end

  def handle_cast({:pattern_gain, gain}, %{player: nil} = state),
    do: {:noreply, %{state | pattern_gain: gain / 1.0}}

  def handle_cast({:pattern_gain, gain}, state) do
    Ahead.apply(state.player, &Player.gain(&1, gain))
    {:noreply, %{state | pattern_gain: gain / 1.0}}
  end

  def handle_cast({:pattern_cps, _cps}, %{player: nil} = state), do: {:noreply, state}

  def handle_cast({:pattern_cps, cps}, state) do
    Ahead.apply(state.player, &Player.cps(&1, cps))
    {:noreply, state}
  end

  def handle_cast(:hush, %{player: nil} = state), do: {:noreply, state}

  def handle_cast(:hush, state) do
    Ahead.apply(state.player, &Player.hush/1)
    {:noreply, state}
  end

  def handle_cast({:update_score, _score}, %{transport: nil} = state), do: {:noreply, state}

  def handle_cast({:update_score, score}, state) do
    {:noreply, %{state | transport: Transport.update(state.transport, score)}}
  end

  @impl true
  def handle_call(:loops, _from, state) do
    reading =
      Map.new(state.loops, fn {name, transport} ->
        {name,
         %{
           beat: Transport.beat(transport),
           rounds: Transport.rounds(transport),
           pending?: Transport.pending?(transport)
         }}
      end)

    {:reply, reading, state}
  end

  def handle_call({:after_round, name}, from, state) do
    case Map.fetch(state.loops, name) do
      :error ->
        {:reply, {:error, :no_such_loop}, state}

      {:ok, _transport} ->
        {:noreply, update_in(state.waiting[name], &[from | &1 || []])}
    end
  end

  def handle_call(:sounding, _from, state) do
    playing = length(state.sounding) + transport_sounding(state.transport)

    {:reply, playing, state}
  end

  def handle_call(:beat, _from, %{transport: nil} = state), do: {:reply, nil, state}

  def handle_call(:beat, _from, state) do
    {:reply, Transport.beat(state.transport), state}
  end

  def handle_call(:cycle, _from, %{player: nil} = state), do: {:reply, nil, state}

  def handle_call(:cycle, _from, state), do: {:reply, Ahead.cycle(state.player), state}

  def handle_call(:level, _from, state), do: {:reply, state.level, state}

  def handle_call(:bed_position, _from, state), do: {:reply, Bed.position(state.bed), state}

  def handle_call({:scope, points}, _from, state) do
    {:reply, thinned(state.last, state.channels, points), state}
  end

  def handle_call(:next_chunk, _from, state) do
    {voices, remaining} = next_chunk(state)
    {under, bed} = Bed.chunk(state.bed, state.chunk, state.channels)
    {scored, transport} = transport_chunk(state)
    {looped, loops, came_round} = loops_chunk(state)
    patterned = pattern_chunk(state)

    mixed =
      Mixer.mix([Mixer.scale(under, state.bed_gain), voices, scored, looped, patterned])

    {effected, fx} = effect(state.fx, mixed)
    out = limit(effected, state.limit)

    moved = %{
      state
      | sounding: remaining,
        bed: bed,
        frame: state.frame + state.chunk,
        transport: transport,
        loops: loops,
        waiting: answer(state.waiting, came_round),
        fx: fx,
        level: Mixer.peak(out) / 32_767,
        last: window(state.last, out, state.scope, state.channels)
    }

    Enum.each(came_round, &work(moved, &1))

    {:reply, out, moved}
  end

  defp live_voice(opts), do: Keyword.put_new(opts, :voice, &Kit.voice(&1, &2, wait: false))

  defp renew(state, _name, nil), do: state

  defp renew(state, name, body) do
    state = put_in(state.bodies[name], body)
    work(state, name)

    state
  end

  defp work(state, name) do
    with {:ok, body} <- Map.fetch(state.bodies, name),
         {:ok, transport} <- Map.fetch(state.loops, name) do
      stage = self()
      round = Transport.rounds(transport)
      at = state.frame + Transport.remaining(transport)

      spawn(fn -> deliver(stage, name, round, at, body) end)
    end

    :ok
  end

  defp deliver(stage, name, round, at, body) do
    case Store.as(name, at, body) do
      {:ok, %Score{} = score} ->
        GenServer.cast(stage, {:round_ready, name, round, score})

      {:error, reason} ->
        Logger.debug("tuning_fork: #{inspect(name)} will not play next round — #{reason}")
    end
  rescue
    error ->
      Logger.debug("tuning_fork: #{inspect(name)} raised — #{Exception.message(error)}")
  end

  defp answer(waiting, []), do: waiting

  defp answer(waiting, came_round) do
    Enum.reduce(came_round, waiting, fn name, acc ->
      {froms, acc} = Map.pop(acc, name, [])
      Enum.each(froms, &GenServer.reply(&1, :ok))

      acc
    end)
  end

  defp limit(pcm, nil), do: pcm
  defp limit(pcm, threshold), do: Mixer.soft_clip(pcm, threshold)

  defp window(nil, chunk, frames, channels), do: window(<<>>, chunk, frames, channels)

  defp window(kept, chunk, frames, channels) do
    room = frames * Mixer.bytes_per_frame(channels)
    grown = kept <> chunk

    if byte_size(grown) > room do
      binary_part(grown, byte_size(grown) - room, room)
    else
      grown
    end
  end

  defp thinned(nil, _channels, _points), do: []

  defp thinned(pcm, channels, points) do
    left =
      for <<sample::16-signed-little, _rest::binary-size(channels * 2 - 2) <- pcm>>, do: sample

    case triggered(left) do
      [] -> []
      aligned -> sampled(aligned, points)
    end
  end

  defp sampled(samples, points) do
    count = length(samples)
    step = max(div(count, points), 1)

    samples
    |> Enum.take_every(step)
    |> Enum.take(points)
    |> Enum.map(&(&1 / 32_767))
  end

  defp triggered(samples) when length(samples) < 8, do: samples

  defp triggered(samples) do
    look = div(length(samples), 4)

    case rising(Enum.take(samples, look), 0) do
      nil -> samples
      at -> Enum.drop(samples, at)
    end
  end

  defp rising([first, second | rest], at) do
    if first <= 0 and second > 0, do: at, else: rising([second | rest], at + 1)
  end

  defp rising(_short, _at), do: nil

  defp pattern_chunk(%__MODULE__{player: nil} = state),
    do: Mixer.silence(state.chunk, state.channels)

  defp pattern_chunk(%__MODULE__{} = state), do: Ahead.next(state.player)

  defp stop_ahead(nil), do: :ok
  defp stop_ahead(ahead), do: if(Process.alive?(ahead), do: Ahead.stop(ahead), else: :ok)

  defp effect(nil, pcm), do: {pcm, nil}
  defp effect(fx, pcm), do: Fx.Live.advance(fx, pcm)

  defp live_fx([], _rate, _channels), do: nil
  defp live_fx(effects, rate, channels), do: Fx.Live.new(effects, rate, channels)

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    stop_writer(state.writer)
    state.sink.close(state.sink_state)
    :ok
  end

  defp stop_writer(nil), do: :ok

  defp stop_writer(writer) do
    if Process.alive?(writer) do
      Process.unlink(writer)
      Process.exit(writer, :kill)
    end

    :ok
  end

  defp add(state, pcm) do
    sounding = Enum.take([pcm | state.sounding], state.voices)
    %{state | sounding: sounding}
  end

  @held_seconds 3_600.0

  defp held(nil), do: TuningFork.Envelope.new(sustain: 1.0, hold: @held_seconds)
  defp held(%TuningFork.Envelope{} = envelope), do: %{envelope | hold: @held_seconds}

  defp let_go(state, key, seconds) do
    sounding =
      Enum.map(state.sounding, fn
        {^key, live} -> Voice.Live.release(live, seconds)
        other -> other
      end)

    %{state | sounding: sounding}
  end

  defp next_chunk(%__MODULE__{sounding: []} = state) do
    {Mixer.silence(state.chunk, state.channels), []}
  end

  defp next_chunk(%__MODULE__{} = state) do
    {chunks, rest} =
      Enum.reduce(state.sounding, {[], []}, fn sounding, {chunks, rest} ->
        {chunk, remaining} = take(sounding, state.chunk, state.channels)
        {[chunk | chunks], if(remaining == :done, do: rest, else: [remaining | rest])}
      end)

    {Mixer.mix(chunks), Enum.reverse(rest)}
  end

  defp take(%Voice.Live{} = live, frames, channels) do
    {chunk, live} = Voice.Live.advance(live, frames, channels)

    {chunk, if(Voice.Live.done?(live), do: :done, else: live)}
  end

  defp take({key, %Voice.Live{} = live}, frames, channels) do
    case take(live, frames, channels) do
      {chunk, :done} -> {chunk, :done}
      {chunk, live} -> {chunk, {key, live}}
    end
  end

  defp take(pcm, frames, channels) when is_binary(pcm) do
    {chunk, remaining} = Mixer.take(pcm, frames, channels)

    {chunk, if(remaining == <<>>, do: :done, else: remaining)}
  end

  defp transport_sounding(nil), do: 0
  defp transport_sounding(transport), do: Transport.sounding(transport)

  defp loops_chunk(%__MODULE__{loops: loops} = state) when map_size(loops) == 0 do
    {Mixer.silence(state.chunk, state.channels), loops, []}
  end

  defp loops_chunk(%__MODULE__{} = state) do
    {blocks, loops} =
      Enum.map_reduce(state.loops, %{}, fn {name, transport}, kept ->
        {pcm, moved} = Transport.advance(transport, state.chunk, state.channels)

        {pcm, Map.put(kept, name, moved)}
      end)

    came_round =
      for {name, moved} <- loops,
          Transport.rounds(moved) > Transport.rounds(Map.fetch!(state.loops, name)),
          do: name

    {Mixer.mix([Mixer.silence(state.chunk, state.channels) | blocks]), loops, came_round}
  end

  defp transport_chunk(%__MODULE__{transport: nil} = state) do
    {Mixer.silence(state.chunk, state.channels), nil}
  end

  defp transport_chunk(%__MODULE__{} = state) do
    {pcm, transport} = Transport.advance(state.transport, state.chunk, state.channels)

    {pcm, unless(Transport.finished?(transport), do: transport)}
  end

  defp start_writer(%__MODULE__{sink: TuningFork.Sink.Silent} = state) do
    stage = self()
    interval = max(1, round(state.chunk * 1_000 / state.rate))

    spawn_link(fn -> silent_loop(stage, interval) end)
  end

  defp start_writer(%__MODULE__{} = state) do
    stage = self()

    spawn_link(fn ->
      writer_loop(stage, state.sink, state.sink_state)
    end)
  end

  defp silent_loop(stage, interval) do
    case safe_chunk(stage) do
      nil ->
        :ok

      _discarded ->
        Process.sleep(interval)
        silent_loop(stage, interval)
    end
  end

  defp writer_loop(stage, sink, sink_state) do
    case safe_chunk(stage) do
      nil ->
        :ok

      chunk ->
        case sink.write(sink_state, chunk) do
          {:error, reason} ->
            Logger.error("#{inspect(sink)} stopped taking samples: #{inspect(reason)}")
            :ok

          _written ->
            writer_loop(stage, sink, sink_state)
        end
    end
  end

  defp safe_chunk(stage) do
    GenServer.call(stage, :next_chunk, 5_000)
  catch
    :exit, _ -> nil
  end
end

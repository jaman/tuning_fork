defmodule TuningFork.Pattern.Player do
  @moduledoc """
  Walks a pattern in time, rendering the events that come due to PCM block by block.

      player = TuningFork.Pattern.Player.new(pattern, 44_100, cps: 0.5)
      {pcm, player} = TuningFork.Pattern.Player.advance(player, 512, 2)
  """

  alias TuningFork.{Kit, Mixer, Pattern, Reverb}
  alias TuningFork.Pattern.Control
  alias TuningFork.Voice.Live

  @typedoc "Where a voice goes: its orbit, and how much of it is sent to that orbit's room."
  @type route :: {non_neg_integer(), float()}

  @type t :: %__MODULE__{
          pattern: Pattern.t(),
          next: {Pattern.t(), :cycle} | nil,
          rate: pos_integer(),
          cps: float(),
          cycle: float(),
          voice: (term(), float() -> TuningFork.Voice.t() | nil),
          voices: pos_integer(),
          sounding: [{non_neg_integer(), Live.t(), :playing | :fading, route()}],
          pending: [Pattern.event()],
          buses: %{non_neg_integer() => map()},
          reverbs: %{non_neg_integer() => TuningFork.Reverb.t()}
        }

  defstruct [
    :pattern,
    :rate,
    :voice,
    next: nil,
    cps: 0.5,
    cycle: 0.0,
    voices: 32,
    sounding: [],
    pending: [],
    buses: %{},
    reverbs: %{}
  ]

  @quiet_bus %{room: 0.0, roomsize: 2.0, postgain: 1.0, xfade: 1.0, compressor: 0.0}
  @compress_from 0.5

  @doc """
  A player at cycle zero of `pattern`, running at `rate` samples per second.

  ## Options

    * `:cps` — cycles per second, default 0.5
    * `:voice` — a function from a value and a length in seconds to a `TuningFork.Voice` or
      `nil`. Default `TuningFork.Kit.voice/2`
    * `:voices` — most notes sounding at once, default 32. Past that the oldest are faded out
      over 10 ms
  """
  @spec new(Pattern.t(), pos_integer(), keyword()) :: t()
  def new(%Pattern{} = pattern, rate, opts \\ []) do
    warm(pattern, 0.0)

    %__MODULE__{
      pattern: pattern,
      rate: rate,
      cps: Keyword.get(opts, :cps, 0.5) / 1.0,
      voice: Keyword.get(opts, :voice, &Kit.voice/2),
      voices: Keyword.get(opts, :voices, 32)
    }
  end

  @doc """
  Render `cycles` of a pattern to signed 16-bit little-endian PCM, without a sound device.

      pcm = Player.render(pattern, 44_100, cycles: 4, cps: 0.5)

  The result is exactly `cycles` cycles long; whatever is still ringing at the end is folded
  back over the beginning.

  ## Options

    * `:cycles` — how many to render, default 4
    * `:cps` — cycles per second, default 0.5
    * `:channels` — 2 for stereo, the default
    * `:tail` — seconds rendered past the last cycle and folded back over the start, default 1.0
    * `:voice`, `:voices` — as `new/3` takes them
  """
  @spec render(Pattern.t(), pos_integer(), keyword()) :: binary()
  def render(%Pattern{} = pattern, rate, opts \\ []) do
    cycles = Keyword.get(opts, :cycles, 4)
    cps = Keyword.get(opts, :cps, 0.5)
    channels = Keyword.get(opts, :channels, 2)
    tail = Keyword.get(opts, :tail, 1.0)

    frames = trunc(cycles / cps * rate)
    over = trunc(tail * rate)
    block = 2_048

    {body, player} = blocks(new(pattern, rate, opts), frames, block, channels)
    quiet = %{player | pattern: Pattern.silence(), next: nil}
    {ring, _done} = blocks(quiet, over, block, channels)

    Mixer.fold(body <> ring, frames, channels)
  end

  defp blocks(player, frames, block, channels, acc \\ <<>>)

  defp blocks(player, frames, _block, _channels, acc) when frames <= 0, do: {acc, player}

  defp blocks(player, frames, block, channels, acc) do
    size = min(block, frames)
    {chunk, player} = advance(player, size, channels)

    blocks(player, frames - size, block, channels, acc <> chunk)
  end

  @doc """
  The next `frames` frames, and the player advanced past them.

  The result is always exactly `frames` frames for `channels` channels. Events beginning inside
  the block start at their own sample rather than at the block boundary.
  """
  @spec advance(t(), pos_integer(), pos_integer()) :: {binary(), t()}
  def advance(%__MODULE__{} = player, frames, channels \\ 2) do
    reached = player.cycle + frames / player.rate * player.cps
    player = install(player, reached)

    {starting, buses, pending} = due(player, reached, frames)
    player = %{player | buses: Map.merge(player.buses, buses), pending: pending}

    {blocks, sounding} = advance_all(player.sounding ++ starting, frames, channels)
    {mixed, player} = through_buses(player, blocks, frames, channels)

    {mixed, %{player | cycle: reached, sounding: cap(sounding, player.voices)}}
  end

  defp through_buses(player, blocks, frames, channels) do
    {mixed, player} =
      blocks
      |> Enum.group_by(fn {{orbit, _room}, _pcm} -> orbit end)
      |> Enum.map_reduce(player, fn {orbit, pieces}, acc ->
        bus = Map.get(acc.buses, orbit, @quiet_bus)
        silence = Mixer.silence(frames, channels)
        dry = Mixer.mix([silence | Enum.map(pieces, &elem(&1, 1))])
        sends = for {{_orbit, room}, pcm} <- pieces, room > 0.0, do: Mixer.scale(pcm, room)

        {wet, reverb} =
          case sends do
            [] ->
              {silence, Map.get(acc.reverbs, orbit)}

            _some ->
              Reverb.wet(
                Map.get(acc.reverbs, orbit) || Reverb.new(acc.rate),
                Mixer.mix([silence | sends]),
                channels,
                bus.roomsize
              )
          end

        {levelled(Mixer.mix(dry, wet), bus),
         %{acc | reverbs: Map.put(acc.reverbs, orbit, reverb)}}
      end)

    case mixed do
      [] -> {Mixer.silence(frames, channels), player}
      several -> {Mixer.mix([Mixer.silence(frames, channels) | several]), player}
    end
  end

  defp levelled(pcm, bus) do
    gain = bus.postgain * bus.xfade

    pcm
    |> compressed(bus.compressor)
    |> then(&if(gain == 1.0, do: &1, else: Mixer.scale(&1, gain)))
  end

  defp compressed(pcm, amount) when amount <= 0, do: pcm

  defp compressed(pcm, amount) do
    peak = Mixer.peak(pcm) / 32_767
    squeeze = min(amount, 1.0)

    if peak <= @compress_from do
      pcm
    else
      Mixer.scale(pcm, 1.0 - squeeze * (1.0 - @compress_from / peak))
    end
  end

  defp cap(sounding, voices) when length(sounding) <= voices, do: sounding

  defp cap(sounding, voices) do
    {kept, over} = Enum.split(sounding, voices)

    fading =
      over
      |> Enum.take(voices)
      |> Enum.map(fn
        {offset, live, :playing, orbit} -> {offset, Live.release(live, 0.01), :fading, orbit}
        already -> already
      end)

    kept ++ fading
  end

  @doc """
  Swap the pattern without stopping. The position carries on.

  `at: :cycle`, the default, holds it until the next cycle line. `at: :now` takes effect on the
  next block. Notes already sounding finish as the pattern read when they started.
  """
  @spec update(t(), Pattern.t(), keyword()) :: t()
  def update(%__MODULE__{} = player, %Pattern{} = pattern, opts \\ []) do
    warm(pattern, player.cycle)

    case Keyword.get(opts, :at, :cycle) do
      :now -> %{player | pattern: pattern, next: nil}
      :cycle -> %{player | next: {pattern, :cycle}}
    end
  end

  @doc "Whether a pattern is waiting for the next cycle line to come in."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{next: nil}), do: false
  def pending?(%__MODULE__{}), do: true

  @doc "Where the player has reached, in cycles."
  @spec cycle(t()) :: float()
  def cycle(%__MODULE__{cycle: cycle}), do: cycle

  @doc """
  How many notes are sounding right now, the ones fading out included.
  """
  @spec sounding(t()) :: non_neg_integer()
  def sounding(%__MODULE__{sounding: sounding}), do: length(sounding)

  @doc "How many notes are sounding and not fading out. Never more than the `:voices` cap."
  @spec playing(t()) :: non_neg_integer()
  def playing(%__MODULE__{sounding: sounding}) do
    Enum.count(sounding, fn {_offset, _live, how, _orbit} -> how == :playing end)
  end

  @doc "Stop everything sounding. The position carries on."
  @spec hush(t()) :: t()
  def hush(%__MODULE__{} = player), do: %{player | sounding: []}

  @doc "Run at a different speed from the next block on. The position carries on."
  @spec cps(t(), number()) :: t()
  def cps(%__MODULE__{} = player, cps) when cps > 0, do: %{player | cps: cps / 1.0}

  @warm_cycles 8

  defp warm(pattern, from) do
    pattern
    |> Pattern.query({from, from + @warm_cycles})
    |> Enum.map(& &1.value)
    |> Kit.prefetch()
  end

  defp install(%__MODULE__{next: nil} = player, _reached), do: player

  defp install(%__MODULE__{next: {pattern, :cycle}} = player, reached) do
    if trunc(reached) > trunc(player.cycle) or player.cycle == 0.0 do
      %{player | pattern: pattern, next: nil}
    else
      player
    end
  end

  defp due(%__MODULE__{} = player, reached, frames) do
    from = player.cycle
    to = reached

    fresh =
      player.pattern
      |> Pattern.query({from, to})
      |> Enum.filter(&Pattern.onset?/1)

    {echoing, pending} =
      (player.pending ++ Enum.flat_map(fresh, &Control.echoes_of/1))
      |> Enum.split_with(fn %{whole: {begins, _ends}} -> begins < to end)

    events = fresh ++ echoing

    entries =
      Enum.flat_map(events, fn %{whole: {begins, ends}, value: value} ->
        seconds = (ends - begins) / player.cps

        case player.voice.(value, seconds) do
          nil ->
            []

          voice ->
            offset = round((begins - from) / player.cps * player.rate)
            at = max(offset, 0) |> min(frames - 1)

            [{at, Live.start(voice, player.rate), :playing, route_of(value)}]
        end
      end)

    {entries, from_events(events), pending}
  end

  defp bus_of(%{orbit: orbit}) when is_number(orbit), do: trunc(orbit)
  defp bus_of(_value), do: 0

  defp route_of(%{room: room} = value) when is_number(room),
    do: {bus_of(value), room |> max(0.0) |> min(1.0) |> Kernel.*(1.0)}

  defp route_of(value), do: {bus_of(value), 0.0}

  defp from_events(events) do
    events
    |> Enum.map(& &1.value)
    |> Enum.filter(&is_map/1)
    |> Enum.group_by(&bus_of/1)
    |> Map.new(fn {orbit, values} -> {orbit, settings(values)} end)
  end

  defp settings(values) do
    %{
      room: loudest(values, :room, 0.0),
      roomsize: loudest(values, :roomsize, 2.0),
      postgain: loudest(values, :postgain, 1.0),
      xfade: loudest(values, :xfade, 1.0),
      compressor: loudest(values, :compressor, 0.0)
    }
  end

  defp loudest(values, key, fallback) do
    values
    |> Enum.map(&Map.get(&1, key))
    |> Enum.filter(&is_number/1)
    |> case do
      [] -> fallback
      asked -> Enum.max(asked) / 1.0
    end
  end

  @doc """
  What each bus is set to, keyed by orbit: a map of `room`, `roomsize`, `postgain`, `xfade`
  and `compressor`. An orbit the pattern has never mentioned has no entry.
  """
  @spec buses(t()) :: %{non_neg_integer() => map()}
  def buses(%__MODULE__{buses: buses}), do: buses

  @doc """
  Bus zero's `{room, roomsize}`.
  """
  @spec room(t()) :: {float(), float()}
  def room(%__MODULE__{} = player) do
    bus = Map.get(player.buses, 0, @quiet_bus)

    {bus.room, bus.roomsize}
  end

  defp advance_all(sounding, frames, channels) do
    Enum.reduce(sounding, {[], []}, fn {offset, live, how, orbit}, {blocks, kept} ->
      {pcm, live} = Live.advance(live, frames - offset, channels)
      placed = Mixer.silence(offset, channels) <> pcm

      kept = if Live.done?(live), do: kept, else: [{0, live, how, orbit} | kept]

      {[{orbit, placed} | blocks], kept}
    end)
  end
end

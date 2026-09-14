defmodule TuningFork.Score do
  @moduledoc """
  Notes on a beat grid with a tempo map, rendered to one buffer that loops without a break.

      Score.from_parts([bass, arpeggio, drums], beats: 64)
      |> Score.render(44_100)
  """

  alias TuningFork.{Fx, Mixer, Part, Voice}

  @type layer :: %{fx: keyword(), notes: [{float(), Voice.t()}]}
  @type t :: %__MODULE__{
          bpm: float(),
          beats: float(),
          changes: [{float(), float()}],
          notes: [{float(), Voice.t()}],
          layers: [layer()]
        }

  defstruct bpm: 120.0, beats: 16.0, changes: [], notes: [], layers: []

  @doc """
  An empty score.

  ## Options

    * `:bpm` — the tempo it starts at, default 120
    * `:beats` — how long it runs, default 16
    * `:changes` — tempo changes after the start, as `[{beat, bpm}]`. Sorted by beat, and
      where two name the same beat the later one in the list wins
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      bpm: Keyword.get(opts, :bpm, 120.0) * 1.0,
      beats: Keyword.get(opts, :beats, 16) * 1.0,
      changes: opts |> Keyword.get(:changes, []) |> normalise_changes()
    }
  end

  @doc """
  Change tempo at `beat`, for everything from there until the next change.

  A change at a beat that already has one replaces it. A score runs at one tempo at a time.
  """
  @spec tempo(t(), number(), number()) :: t()
  def tempo(%__MODULE__{} = score, beat, bpm) do
    %{score | changes: normalise_changes(score.changes ++ [{beat * 1.0, bpm * 1.0}])}
  end

  @doc """
  Every tempo this score runs at, as `[{beat, bpm}]`, starting from beat zero.

  A change stated at beat zero is the starting tempo and replaces `:bpm`.
  """
  @spec tempo_map(t()) :: [{float(), float()}]
  def tempo_map(%__MODULE__{bpm: bpm, changes: changes}) do
    case changes do
      [{at, _first} | _rest] when at == 0.0 -> changes
      _later -> [{0.0, bpm} | changes]
    end
  end

  @doc "Where `beat` falls, in seconds, read through the tempo map."
  @spec beat_to_seconds(t(), number()) :: float()
  def beat_to_seconds(%__MODULE__{} = score, beat) do
    score |> tempo_map() |> forward(beat * 1.0, 0.0)
  end

  @doc "Which beat `seconds` falls on, read through the tempo map. The inverse of `beat_to_seconds/2`."
  @spec seconds_to_beat(t(), number()) :: float()
  def seconds_to_beat(%__MODULE__{} = score, seconds) do
    score |> tempo_map() |> backward(seconds * 1.0, 0.0)
  end

  defp normalise_changes(changes) do
    changes
    |> Enum.map(fn {beat, bpm} -> {beat * 1.0, bpm * 1.0} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce([], fn
      {beat, _bpm} = change, [{beat, _old} | rest] -> [change | rest]
      change, acc -> [change | acc]
    end)
    |> Enum.reverse()
  end

  defp forward([{at, bpm}], beat, acc), do: acc + (beat - at) * 60.0 / bpm

  defp forward([{at, bpm}, {next_at, _next_bpm} = next | rest], beat, acc) do
    if beat <= next_at do
      acc + (beat - at) * 60.0 / bpm
    else
      forward([next | rest], beat, acc + (next_at - at) * 60.0 / bpm)
    end
  end

  defp backward([{at, bpm}], seconds, acc), do: at + (seconds - acc) * bpm / 60.0

  defp backward([{at, bpm}, {next_at, _next_bpm} = next | rest], seconds, acc) do
    spent = (next_at - at) * 60.0 / bpm

    if seconds <= acc + spent do
      at + (seconds - acc) * bpm / 60.0
    else
      backward([next | rest], seconds, acc + spent)
    end
  end

  @doc "Place a voice on a beat."
  @spec add(t(), number(), Voice.t()) :: t()
  def add(%__MODULE__{} = score, beat, %Voice{} = voice) do
    %{score | notes: [{beat * 1.0, voice} | score.notes]}
  end

  @doc "Place the same voice on each of `beats`."
  @spec add_all(t(), [number()], Voice.t()) :: t()
  def add_all(%__MODULE__{} = score, beats, %Voice{} = voice) do
    Enum.reduce(beats, score, &add(&2, &1, voice))
  end

  @doc """
  Place a voice every `every` beats, from `from` up to but not including `:beats`.

  Raises `ArgumentError` unless `every` is greater than zero.
  """
  @spec repeat(t(), number(), number(), Voice.t()) :: t()
  def repeat(%__MODULE__{} = score, from, every, %Voice{} = voice) when every > 0 do
    beats = Stream.iterate(from * 1.0, &(&1 + every)) |> Enum.take_while(&(&1 < score.beats))
    add_all(score, beats, voice)
  end

  def repeat(%__MODULE__{}, _from, every, %Voice{}) do
    raise ArgumentError, "repeat/4 needs a step greater than zero, got: #{inspect(every)}"
  end

  @doc "How long the score runs, in seconds: where `:beats` falls on the tempo map."
  @spec duration(t()) :: float()
  def duration(%__MODULE__{beats: beats} = score), do: beat_to_seconds(score, beats)

  @window 8_192

  @doc """
  Render to signed 16-bit little-endian PCM that loops without a break.

  `rate` is samples per second. The result is `duration/1` seconds long, and at least one
  frame; anything running past the end is folded back over the start. Each voice lands where
  its `:pan` says.

  ## Options

    * `:channels` — 2 for stereo, the default, or 1 for mono
  """
  @spec render(t(), pos_integer(), keyword()) :: binary()
  def render(%__MODULE__{} = score, rate, opts \\ []) do
    channels = Keyword.get(opts, :channels, 2)
    frames = max(1, trunc(duration(score) * rate))

    [%{fx: [], notes: score.notes} | score.layers]
    |> Enum.reject(&(&1.notes == []))
    |> Enum.map(&layer(&1, score, rate, frames, channels))
    |> case do
      [] -> Mixer.silence(frames, channels)
      [only] -> only
      several -> Mixer.mix(several)
    end
  end

  defp layer(%{fx: fx, notes: notes}, score, rate, frames, channels) do
    dry = timeline(notes, score, rate, frames, channels)

    case fx do
      [] -> dry
      effects -> dry |> Fx.apply(rate, effects, channels) |> fold(frames, channels)
    end
  end

  defp timeline(notes, score, rate, frames, channels) do
    {placed, _rendered} =
      Enum.flat_map_reduce(notes, %{}, fn {beat, voice}, cache ->
        offset = trunc(beat_to_seconds(score, beat) * rate)
        {pcm, cache} = synthesise(voice, rate, cache)
        placed = pcm |> Mixer.scale(voice.gain) |> Mixer.pan(voice.pan, channels)

        {wrap(offset, placed, frames, channels), cache}
      end)

    0..div(frames - 1, @window)
    |> Enum.map(fn index ->
      start = index * @window
      window(placed, start, min(@window, frames - start), channels)
    end)
    |> IO.iodata_to_binary()
  end

  defp fold(pcm, frames, channels), do: Mixer.fold(pcm, frames, channels)

  defp synthesise(voice, rate, cache) do
    key = %{voice | gain: 1.0, pan: 0.0, sample: sample_key(voice.sample)}

    case cache do
      %{^key => pcm} ->
        {pcm, cache}

      _new ->
        then(Voice.render(%{voice | gain: 1.0, pan: 0.0}, rate), &{&1, Map.put(cache, key, &1)})
    end
  end

  defp sample_key(nil), do: nil
  defp sample_key(%{id: id}), do: id

  defp wrap(offset, pcm, frames, channels) when offset >= frames do
    wrap(offset - frames, pcm, frames, channels)
  end

  defp wrap(offset, pcm, frames, channels) do
    room = (frames - offset) * Mixer.bytes_per_frame(channels)

    case pcm do
      <<head::binary-size(room), tail::binary>> when tail != <<>> ->
        [{offset, head} | wrap(0, tail, frames, channels)]

      _fits ->
        [{offset, pcm}]
    end
  end

  defp window(placed, start, length, channels) do
    finish = start + length

    placed
    |> Enum.filter(fn {offset, pcm} ->
      offset < finish and offset + frames(pcm, channels) > start
    end)
    |> Enum.reduce(Mixer.silence(length, channels), fn {offset, pcm}, base ->
      {slice, at} = clip(pcm, offset, start, length, channels)
      {mixed, _over} = Mixer.mix_at(base, slice, at, channels)
      mixed
    end)
  end

  defp clip(pcm, offset, start, length, channels) do
    width = Mixer.bytes_per_frame(channels)
    from = max(0, start - offset) * width
    at = max(0, offset - start)
    take = min(byte_size(pcm) - from, (length - at) * width)

    {binary_part(pcm, from, take), at}
  end

  defp frames(pcm, channels), do: div(byte_size(pcm), Mixer.bytes_per_frame(channels))

  @doc """
  Build a score by mixing parts together.

  Each part is read from its own beat zero. Every part must have the same `:bpm`; parts that
  disagree raise `ArgumentError`.

  ## Options

    * `:bpm` — the tempo, default the parts'. All parts play at it
    * `:beats` — how long the score is, default the longest part's `TuningFork.Part.beats/1`
    * `:changes` — tempo changes, as `new/1` takes them
  """
  @spec from_parts([Part.t()], keyword()) :: t()
  def from_parts(parts, opts \\ []) do
    bpm = Keyword.get(opts, :bpm) || bpm_of(parts)

    beats =
      Keyword.get(opts, :beats) || parts |> Enum.map(&Part.beats/1) |> Enum.max(fn -> 0 end)

    {plain, effected} = Enum.split_with(parts, &(&1.fx == []))

    %__MODULE__{
      bpm: bpm * 1.0,
      beats: beats * 1.0,
      changes: opts |> Keyword.get(:changes, []) |> normalise_changes(),
      notes: Enum.flat_map(plain, &Part.notes/1),
      layers: Enum.map(effected, &%{fx: &1.fx, notes: Part.notes(&1)})
    }
  end

  @doc "The frequency of a named note, such as `:a3`, `:fs4` or `:eb5`."
  @spec note(atom() | number()) :: float()
  defdelegate note(name), to: TuningFork.Notes, as: :freq

  @doc "The frequency `interval` semitones from `name`."
  @spec note(atom() | number(), integer()) :: float()
  defdelegate note(name, interval), to: TuningFork.Notes, as: :step

  defp bpm_of([]), do: 120.0

  defp bpm_of([%Part{bpm: bpm} | _rest] = parts) do
    case parts |> Enum.map(& &1.bpm) |> Enum.uniq() do
      [_one] ->
        bpm

      several ->
        raise ArgumentError,
              "from_parts/2 mixes parts into one score at one tempo, but these are written at " <>
                "#{Enum.map_join(several, ", ", &to_string/1)} bpm. Give every part the same " <>
                ":bpm, or build a score for each."
    end
  end
end

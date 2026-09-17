defmodule TuningFork.Midi do
  @moduledoc """
  Reads a Standard MIDI File, and turns one into a `TuningFork.Score`.

      "song.mid"
      |> TuningFork.Midi.read!()
      |> TuningFork.Midi.to_score(synths: %{0 => lead, 1 => bass}, default: pad)
      |> TuningFork.Score.render(44_100)
  """

  import Bitwise

  alias TuningFork.{Curve, Envelope, Score, Voice}

  @ticks 480

  @type event ::
          {:note_on, 0..15, 0..127, 0..127}
          | {:note_off, 0..15, 0..127, 0..127}
          | {:program, 0..15, 0..127}
          | {:control, 0..15, 0..127, 0..127}
          | {:pitch_bend, 0..15, integer()}
          | {:tempo, pos_integer()}
          | {:track_name, binary()}

  @type t :: %__MODULE__{
          format: 0..2,
          division: pos_integer(),
          tracks: [[{non_neg_integer(), event()}]]
        }

  defstruct format: 1, division: 480, tracks: []

  @drum_channel 9

  @gm_percussion 27..87

  @kit 35..59

  @doc """
  A `TuningFork.Score` as a Standard MIDI File, ready to write.

      iex> score = TuningFork.Score.new(bpm: 120, beats: 4)
      iex> <<"MThd", _rest::binary>> = TuningFork.Midi.encode(score)

  Writes format 0, one track, 480 ticks a beat. A note becomes a note on and a note off
  separated by the voice's duration; a voice's pitch becomes the nearest semitone and its gain
  becomes velocity. The score's tempo is the first event. Nothing else about a voice is
  written.

  ## Options

    * `:channel` — 1 to 16, default 1
    * `:name` — a track name to write into the file
  """
  @spec encode(Score.t(), keyword()) :: binary()
  def encode(%Score{} = score, opts \\ []) do
    track = track_chunk(score, opts)

    <<"MThd", 6::32, 0::16, 1::16, @ticks::16>> <> track
  end

  @doc """
  Write `score` to `path` as a Standard MIDI File.

  Takes `encode/2`'s options.
  """
  @spec write!(Score.t(), Path.t(), keyword()) :: :ok
  def write!(%Score{} = score, path, opts \\ []) do
    File.write!(path, encode(score, opts))
  end

  defp track_chunk(score, opts) do
    events =
      [{0, tempo_event(score)}] ++
        name_event(opts) ++
        (score |> note_events(opts) |> Enum.sort_by(&elem(&1, 0)))

    body =
      events
      |> Enum.map_reduce(0, fn {at, bytes}, was ->
        {delta(at - was) <> bytes, at}
      end)
      |> elem(0)
      |> IO.iodata_to_binary()

    ending = delta(0) <> <<0xFF, 0x2F, 0x00>>

    <<"MTrk", byte_size(body <> ending)::32>> <> body <> ending
  end

  defp tempo_event(%Score{bpm: bpm}) do
    <<0xFF, 0x51, 0x03, round(60_000_000 / bpm)::24>>
  end

  defp name_event(opts) do
    case Keyword.get(opts, :name) do
      nil -> []
      name -> [{0, <<0xFF, 0x03, byte_size(name)>> <> name}]
    end
  end

  defp note_events(%Score{} = score, opts) do
    channel = (Keyword.get(opts, :channel, 1) - 1) |> max(0) |> min(15)

    score.layers
    |> Enum.reduce(score.notes, fn layer, acc -> acc ++ layer.notes end)
    |> Enum.flat_map(fn {beat, voice} ->
      case semitone(voice.freq) do
        nil ->
          []

        note ->
          on = round(beat * @ticks)
          off = on + max(round(Voice.duration(voice) / seconds_per_beat(score) * @ticks), 1)
          loud = (voice.gain * 127) |> round() |> max(1) |> min(127)

          [
            {on, <<0x90 + channel, note, loud>>},
            {off, <<0x80 + channel, note, 0>>}
          ]
      end
    end)
  end

  defp seconds_per_beat(%Score{bpm: bpm}), do: 60.0 / bpm

  defp semitone(freq) when is_number(freq) and freq > 0 do
    round(69 + 12 * :math.log2(freq / 440.0)) |> max(0) |> min(127)
  end

  defp semitone(_freq), do: nil

  defp delta(value) when value <= 0, do: <<0>>

  defp delta(value) do
    {last, front} = value |> sevens([]) |> List.pop_at(-1)

    front
    |> Enum.map(&<<Bitwise.bor(&1, 0x80)>>)
    |> Kernel.++([<<last>>])
    |> IO.iodata_to_binary()
  end

  defp sevens(0, acc), do: acc
  defp sevens(value, acc), do: sevens(Bitwise.bsr(value, 7), [Bitwise.band(value, 0x7F) | acc])

  @doc "Read and parse a MIDI file from disk. Raises as `parse!/1` does."
  @spec read!(Path.t()) :: t()
  def read!(path), do: path |> File.read!() |> parse!()

  @doc "Parse a MIDI file, raising `ArgumentError` where `parse/1` would report an error."
  @spec parse!(binary()) :: t()
  def parse!(binary) do
    case parse(binary) do
      {:ok, midi} -> midi
      {:error, reason} -> raise ArgumentError, "could not read that MIDI file: #{inspect(reason)}"
    end
  end

  @doc """
  Parse a MIDI file of format 0, 1 or 2 with ticks-per-beat division.

  Tracks come back with absolute ticks rather than the deltas the file stores. Chunks that are
  not tracks are skipped, a note on at velocity zero is returned as a note off, and aftertouch
  is dropped.

  Fails with `{:error, :not_a_midi_file}`, `{:error, {:unsupported_format, format}}`,
  `{:error, :smpte_division_unsupported}` or `{:error, :zero_division}`.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(<<"MThd", 6::32, format::16, _tracks::16, division::16, rest::binary>>) do
    cond do
      format > 2 ->
        {:error, {:unsupported_format, format}}

      (division &&& 0x8000) != 0 ->
        {:error, :smpte_division_unsupported}

      division == 0 ->
        {:error, :zero_division}

      true ->
        {:ok, %__MODULE__{format: format, division: division, tracks: tracks(rest, [])}}
    end
  end

  def parse(_other), do: {:error, :not_a_midi_file}

  @doc """
  Turn a parsed file into a score.

  Tempo changes become the score's tempo map, note lengths become envelope decay, velocity
  scales the synth's gain, and pitch bend becomes a frequency multiplier and a `:freq` curve.
  Control changes other than pitch bend are dropped.

  ## Options

    * `:synths` — `%{channel => Voice.t()}`
    * `:drums` — `%{note_number => Voice.t()}`, used on the percussion channels
    * `:drum_channels` — which channels those are, default `[9]`. `:auto` to guess, as
      `drum_channels/2` does
    * `:default` — what anything unclaimed is played with, default `TuningFork.Voice.new/1`
    * `:bpm` — play at this tempo, ignoring the file's own tempo and every change in it
    * `:quantize` — note lengths rounded to this many seconds, default 0.01. `nil` for none
    * `:bend_range` — semitones a full pitch bend covers, default 2
    * `:bend_points` — most breakpoints kept per bend curve, default 8
    * `:beats` — how long the score is, default however long the file runs, rounded up
  """
  @spec to_score(t(), keyword()) :: Score.t()
  def to_score(%__MODULE__{} = midi, opts \\ []) do
    events = merged(midi)
    {bpm, changes} = tempo_of(events, midi.division, opts)

    opts = Keyword.put(opts, :drum_channels, drum_channels(midi, opts))

    notes = paired(events, midi.division)
    bends = bend_curves(events, midi.division, opts)

    score = %Score{
      bpm: bpm,
      beats: Keyword.get(opts, :beats) || length_of(notes),
      changes: changes
    }

    Enum.reduce(notes, score, fn note, acc ->
      Score.add(acc, note.beat, voice_for(note, seconds_of(score, note), bends, opts))
    end)
  end

  defp seconds_of(score, note) do
    Score.beat_to_seconds(score, note.beat + note.beats) -
      Score.beat_to_seconds(score, note.beat)
  end

  @doc """
  Which channels hold drums, resolving `:auto` against the file.

  Takes `to_score/2`'s `:drum_channels` option and returns the channel list it would use.
  With `:auto`, channel 9 is always included, and another channel is included only when it
  has no program change, every note on it is in 27..87, and at least half its distinct note
  numbers are in 35..59.
  """
  @spec drum_channels(t(), keyword()) :: [0..15]
  def drum_channels(%__MODULE__{} = midi, opts \\ []) do
    case Keyword.get(opts, :drum_channels, [@drum_channel]) do
      :auto -> guess_drums(midi)
      channels when is_list(channels) -> channels
    end
  end

  defp guess_drums(%__MODULE__{} = midi) do
    programmed =
      for {_tick, {:program, channel, _number}} <- merged(midi), uniq: true, do: channel

    guessed =
      midi
      |> notes()
      |> Enum.group_by(& &1.channel, & &1.note)
      |> Enum.filter(fn {channel, numbers} ->
        channel not in programmed and
          Enum.all?(numbers, &(&1 in @gm_percussion)) and
          mostly_kit?(numbers)
      end)
      |> Enum.map(&elem(&1, 0))

    [@drum_channel | guessed] |> Enum.uniq() |> Enum.sort()
  end

  defp mostly_kit?(numbers) do
    distinct = Enum.uniq(numbers)

    Enum.count(distinct, &(&1 in @kit)) * 2 >= length(distinct)
  end

  @doc """
  One channel of the file as Strudel mini-notation: a `<…>` of bars, each a `[…]` of
  steps — a note, a chord `[c4,e4]`, or a rest `~`, held with `@n` — and how many bars
  it is, so a recorded piece can be played through the kit's instruments.

      {bars, mini} = TuningFork.Midi.mini(midi, channel: 0, steps_per_beat: 4)
      Strudel.pattern(~s|note("\#{mini}").s("gm_piano")|)

  Onsets snap to the grid leaning late — an onset up to three quarters of a step after
  a step is on it, so grace notes and rounding that push a file's notes late leave
  them on their steps; lengths round; a note reaching past the next onset or the
  bar's end is cut there; a length under a step is a step.

  ## Options

    * `:channel` — the channel to take, default `0`
    * `:beats_per_bar`, `:steps_per_beat` — the grid: `:beats_per_bar` default 4,
      `:steps_per_beat` default 4 (sixteenths)
    * `:from`, `:bars` — the first bar to take and how many; default from the start,
      to the last note
    * `:voice` — `:lowest` or `:highest` to take one note of every chord, default
      `:all`
    * `:on` — `:beats` to keep only the notes struck on a beat, for a bass line from
      a stride left hand; default `:steps`, every note
    * `:transpose` — semitones added to every note, default 0
  """
  @spec mini(t(), keyword()) :: {non_neg_integer(), String.t()}
  def mini(%__MODULE__{} = midi, opts \\ []) do
    channel = Keyword.get(opts, :channel, 0)
    per_bar = Keyword.get(opts, :beats_per_bar, 4)
    per_beat = Keyword.get(opts, :steps_per_beat, 4)
    steps = per_bar * per_beat
    transpose = Keyword.get(opts, :transpose, 0)
    first = Keyword.get(opts, :from, 0)

    onsets =
      midi
      |> notes()
      |> Enum.filter(&(&1.channel == channel))
      |> Enum.map(fn note ->
        {floor(note.beat * per_beat + 0.25), max(1, round(note.beats * per_beat)),
         note.note + transpose}
      end)
      |> Enum.group_by(&elem(&1, 0))
      |> Map.filter(fn {step, _} ->
        Keyword.get(opts, :on, :steps) == :steps or rem(step, per_beat) == 0
      end)
      |> Map.new(fn {step, notes} -> {step, voiced(notes, Keyword.get(opts, :voice, :all))} end)

    count =
      case Keyword.get(opts, :bars) do
        nil -> if onsets == %{}, do: 0, else: div(Enum.max(Map.keys(onsets)), steps) + 1 - first
        bars -> bars
      end

    bars =
      for bar <- first..(first + count - 1)//1 do
        from = bar * steps
        starts = for step <- from..(from + steps - 1), Map.has_key?(onsets, step), do: step
        "[" <> Enum.join(bar_elements(starts, onsets, from, steps), " ") <> "]"
      end

    {max(count, 0), "<" <> Enum.join(bars, " ") <> ">"}
  end

  defp voiced(notes, :all), do: notes
  defp voiced(notes, :lowest), do: [Enum.min_by(notes, &elem(&1, 2))]
  defp voiced(notes, :highest), do: [Enum.max_by(notes, &elem(&1, 2))]

  defp bar_elements([], _onsets, _from, steps), do: [held("~", steps)]

  defp bar_elements(starts, onsets, from, steps) do
    ends = tl(starts) ++ [from + steps]

    {elements, _} =
      Enum.zip(starts, ends)
      |> Enum.reduce({[], from}, fn {start, next}, {acc, at} ->
        rest = if start > at, do: [held("~", start - at)], else: []
        notes = Map.fetch!(onsets, start)
        length = notes |> Enum.map(&elem(&1, 1)) |> Enum.max() |> min(next - start)

        names =
          notes
          |> Enum.map(&elem(&1, 2))
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.map(&Atom.to_string(TuningFork.Notes.name_of(&1)))

        sound = if length(names) == 1, do: hd(names), else: "[" <> Enum.join(names, ",") <> "]"
        gap = if start + length < next, do: [held("~", next - start - length)], else: []
        {acc ++ rest ++ [held(sound, length)] ++ gap, next}
      end)

    elements
  end

  defp held(text, 1), do: text
  defp held(text, steps), do: "#{text}@#{steps}"

  @doc "Every event in the file, in tick order, as `{tick, event}`, with the tracks merged."
  @spec merged(t()) :: [{non_neg_integer(), event()}]
  def merged(%__MODULE__{tracks: tracks}) do
    tracks |> Enum.concat() |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  The notes in the file, paired up and measured in beats, ordered by beat.

  Each note is `%{beat:, beats:, note:, velocity:, channel:, program:}`, where `:beat` and
  `:beats` are floats, `:program` is the channel's program at the time the note started, and
  the rest come from the file. A second note on for a pitch already sounding closes the
  first; a note left open at the end of the file is given one beat.
  """
  @spec notes(t()) :: [map()]
  def notes(%__MODULE__{} = midi), do: midi |> merged() |> paired(midi.division)

  defp tracks(<<"MTrk", length::32, body::binary-size(length), rest::binary>>, acc) do
    tracks(rest, [events(body, 0, nil, []) | acc])
  end

  defp tracks(<<_id::binary-size(4), length::32, _body::binary-size(length), rest::binary>>, acc) do
    tracks(rest, acc)
  end

  defp tracks(_done, acc), do: Enum.reverse(acc)

  defp events(<<>>, _tick, _status, acc), do: Enum.reverse(acc)

  defp events(data, tick, status, acc) do
    {delta, rest} = varint(data)
    tick = tick + delta

    case event(rest, status) do
      :done -> Enum.reverse(acc)
      {nil, status, rest} -> events(rest, tick, status, acc)
      {event, status, rest} -> events(rest, tick, status, [{tick, event} | acc])
    end
  end

  defp event(<<0xFF, type, rest::binary>>, status) do
    {length, rest} = varint(rest)
    <<data::binary-size(length), rest::binary>> = rest

    case meta(type, data) do
      :end_of_track -> :done
      other -> {other, status, rest}
    end
  end

  defp event(<<sysex, rest::binary>>, status) when sysex in [0xF0, 0xF7] do
    {length, rest} = varint(rest)
    <<_data::binary-size(length), rest::binary>> = rest

    {nil, status, rest}
  end

  defp event(<<byte, _rest::binary>> = data, status) when byte < 0x80 and not is_nil(status) do
    {event, rest} = channel_event(status, data)
    {event, status, rest}
  end

  defp event(<<status, rest::binary>>, _previous) when status >= 0x80 do
    {event, rest} = channel_event(status, rest)
    {event, status, rest}
  end

  defp event(_unreadable, _status), do: :done

  defp channel_event(status, data) do
    channel = status &&& 0x0F

    case status &&& 0xF0 do
      0x80 ->
        <<note, velocity, rest::binary>> = data
        {{:note_off, channel, note, velocity}, rest}

      0x90 ->
        <<note, velocity, rest::binary>> = data
        kind = if velocity == 0, do: :note_off, else: :note_on
        {{kind, channel, note, velocity}, rest}

      0xA0 ->
        <<_note, _pressure, rest::binary>> = data
        {nil, rest}

      0xB0 ->
        <<controller, value, rest::binary>> = data
        {{:control, channel, controller, value}, rest}

      0xC0 ->
        <<program, rest::binary>> = data
        {{:program, channel, program}, rest}

      0xD0 ->
        <<_pressure, rest::binary>> = data
        {nil, rest}

      0xE0 ->
        <<low, high, rest::binary>> = data
        {{:pitch_bend, channel, ((high <<< 7 ||| low) - 8_192) / 8_192.0}, rest}
    end
  end

  defp meta(0x51, <<microseconds::24>>), do: {:tempo, microseconds}
  defp meta(0x2F, _data), do: :end_of_track
  defp meta(0x03, name), do: {:track_name, name}
  defp meta(_type, _data), do: nil

  defp varint(binary, acc \\ 0)
  defp varint(<<0::1, value::7, rest::binary>>, acc), do: {acc * 128 + value, rest}
  defp varint(<<1::1, value::7, rest::binary>>, acc), do: varint(rest, acc * 128 + value)
  defp varint(<<>>, acc), do: {acc, <<>>}

  defp tempo_of(events, division, opts) do
    case Keyword.get(opts, :bpm) do
      nil -> events |> tempo_changes(division) |> starting_tempo()
      override -> {override * 1.0, []}
    end
  end

  defp tempo_changes(events, division) do
    for {tick, {:tempo, microseconds}} <- events do
      {tick / division, 60_000_000.0 / microseconds}
    end
  end

  defp starting_tempo([]), do: {120.0, []}
  defp starting_tempo([{at, bpm} | rest]) when at == 0.0, do: {bpm, rest}
  defp starting_tempo(changes), do: {120.0, changes}

  defp paired(events, division) do
    {done, open, _programs} =
      Enum.reduce(events, {[], %{}, %{}}, fn {tick, event}, {done, open, programs} ->
        case event do
          {:program, channel, program} ->
            {done, open, Map.put(programs, channel, program)}

          {:note_on, channel, note, velocity} ->
            key = {channel, note}
            done = close(open, key, tick, division, done)

            started = %{
              tick: tick,
              velocity: velocity,
              channel: channel,
              program: Map.get(programs, channel, 0)
            }

            {done, Map.put(open, key, started), programs}

          {:note_off, channel, note, _velocity} ->
            {close(open, {channel, note}, tick, division, done),
             Map.delete(open, {channel, note}), programs}

          _other ->
            {done, open, programs}
        end
      end)

    unclosed =
      for {{channel, note}, started} <- open do
        finish(started, channel, note, started.tick + division, division)
      end

    (done ++ unclosed) |> Enum.sort_by(& &1.beat)
  end

  defp close(open, {channel, note} = key, tick, division, done) do
    case Map.fetch(open, key) do
      {:ok, started} -> [finish(started, channel, note, tick, division) | done]
      :error -> done
    end
  end

  defp finish(started, channel, note, tick, division) do
    %{
      beat: started.tick / division,
      beats: max(tick - started.tick, 1) / division,
      note: note,
      velocity: started.velocity,
      channel: channel,
      program: started.program
    }
  end

  defp length_of([]), do: 0.0

  defp length_of(notes) do
    notes |> Enum.map(&(&1.beat + &1.beats)) |> Enum.max() |> Float.ceil()
  end

  defp bend_curves(events, division, opts) do
    range = Keyword.get(opts, :bend_range, 2)

    for {tick, {:pitch_bend, channel, value}} <- events do
      {channel, {tick / division, :math.pow(2.0, value * range / 12.0)}}
    end
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp voice_for(note, seconds, bends, opts) do
    synth = synth_for(note, opts)
    drum? = drum?(note, opts)

    synth
    |> pitch(drum?, note)
    |> level(note, synth)
    |> lengthen(drum?, quantise(seconds, opts))
    |> bend(note, bends, opts)
  end

  defp synth_for(note, opts) do
    if drum?(note, opts) do
      opts |> Keyword.get(:drums, %{}) |> Map.get(note.note) || default_synth(opts)
    else
      opts |> Keyword.get(:synths, %{}) |> Map.get(note.channel) || default_synth(opts)
    end
  end

  defp drum?(%{channel: channel}, opts) do
    channel in Keyword.get(opts, :drum_channels, [@drum_channel])
  end

  defp default_synth(opts), do: Keyword.get(opts, :default) || Voice.new()

  defp pitch(synth, true, _note), do: synth

  defp pitch(synth, false, %{note: note}) do
    %{synth | freq: 440.0 * :math.pow(2.0, (note - 69) / 12.0)}
  end

  defp level(voice, %{velocity: velocity}, synth) do
    %{voice | gain: synth.gain * velocity / 127.0}
  end

  defp lengthen(voice, true, _seconds), do: voice

  defp lengthen(voice, false, seconds) do
    %{voice | envelope: Envelope.spanning(voice.envelope || Envelope.new(), seconds)}
  end

  defp bend(voice, note, bends, opts) do
    from = note.beat
    to = note.beat + note.beats
    channel = Map.get(bends, note.channel, [])

    start = held_at(channel, from)
    voice = if start == 1.0, do: voice, else: %{voice | freq: voice.freq * start}

    case Enum.filter(channel, fn {beat, _value} -> beat > from and beat < to end) do
      [] ->
        voice

      moving ->
        curve =
          [
            {0.0, 1.0}
            | Enum.map(moving, &{(elem(&1, 0) - from) / note.beats, elem(&1, 1) / start})
          ]
          |> Curve.new()
          |> Curve.simplify(Keyword.get(opts, :bend_points, 8))

        if Curve.flat?(curve), do: voice, else: %{voice | curves: %{freq: curve}}
    end
  end

  defp held_at(bends, beat) do
    bends
    |> Enum.filter(fn {at, _value} -> at <= beat end)
    |> List.last()
    |> case do
      nil -> 1.0
      {_at, value} -> value
    end
  end

  defp quantise(seconds, opts) do
    case Keyword.get(opts, :quantize, 0.01) do
      nil ->
        seconds

      grid when is_number(grid) and grid > 0 ->
        max(Float.round(seconds / grid) * grid, grid)

      other ->
        raise ArgumentError, ":quantize must be a number above zero or nil, not #{inspect(other)}"
    end
  end
end

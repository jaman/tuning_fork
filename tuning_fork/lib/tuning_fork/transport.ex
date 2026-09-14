defmodule TuningFork.Transport do
  @moduledoc """
  Walks a score in time, a block at a time, handing out the notes that have come due.

      transport = Transport.new(score, 44_100)
      {pcm, transport} = Transport.advance(transport, 512, 2)
  """

  alias TuningFork.{Fx, Mixer, Score}
  alias TuningFork.Voice.Live

  @tail_seconds 8

  @type t :: %__MODULE__{
          score: Score.t(),
          rate: pos_integer(),
          frame: non_neg_integer(),
          loop: boolean(),
          playing: boolean(),
          sounding: [{non_neg_integer(), Live.t(), keyword()}],
          chains: %{keyword() => {Fx.Live.t(), non_neg_integer()}},
          next: Score.t() | nil,
          rounds: non_neg_integer()
        }

  defstruct [
    :score,
    :rate,
    frame: 0,
    loop: false,
    playing: true,
    sounding: [],
    chains: %{},
    next: nil,
    rounds: 0
  ]

  @doc """
  A transport at the start of a score, running at `rate` samples per second.

  ## Options

    * `:loop` — go back to the start on reaching the end, default false
    * `:playing` — whether it is running, default true
  """
  @spec new(Score.t(), pos_integer(), keyword()) :: t()
  def new(%Score{} = score, rate, opts \\ []) do
    %__MODULE__{
      score: score,
      rate: rate,
      loop: Keyword.get(opts, :loop, false),
      playing: Keyword.get(opts, :playing, true)
    }
  end

  @doc """
  The next `frames` frames of the piece, and the transport advanced past them.

  The result is always exactly `frames` frames for `channels` channels. Notes falling inside
  the block start sounding at their own sample, notes already sounding carry on, and what has
  finished is dropped. A paused transport returns silence and does not move.
  """
  @spec advance(t(), pos_integer(), pos_integer()) :: {binary(), t()}
  def advance(transport, frames, channels \\ 2)

  def advance(%__MODULE__{playing: false} = transport, frames, channels) do
    {Mixer.silence(frames, channels), transport}
  end

  def advance(%__MODULE__{} = transport, frames, channels) do
    sounding = transport.sounding ++ start_due(transport, frames)
    {grouped, sounding} = advance_all(sounding, frames, channels)
    {blocks, chains} = effected(grouped, transport.chains, frames, channels, transport.rate)

    over = transport.frame + frames
    total = total_frames(transport)
    round_ended? = transport.loop and total > 0 and over >= total

    frame = if round_ended?, do: rem(over, total), else: over

    mixed =
      case blocks do
        [] -> Mixer.silence(frames, channels)
        several -> Mixer.mix([Mixer.silence(frames, channels) | several])
      end

    moved = %{transport | frame: frame, sounding: sounding, chains: chains}

    {mixed, if(round_ended?, do: came_round(moved), else: moved)}
  end

  defp came_round(%__MODULE__{next: nil} = transport) do
    %{transport | rounds: transport.rounds + 1}
  end

  defp came_round(%__MODULE__{next: score} = transport) do
    %{transport | score: score, next: nil, rounds: transport.rounds + 1}
  end

  @doc """
  How many times the transport has been round its loop.

  Zero until the first time it reaches the end. A loop that is not looping never counts past
  zero. This is what `sync`-style waiting watches.
  """
  @spec rounds(t()) :: non_neg_integer()
  def rounds(%__MODULE__{rounds: rounds}), do: rounds

  @doc "Whether a score is waiting for the loop to come round before it takes over."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{next: nil}), do: false
  def pending?(%__MODULE__{}), do: true

  @doc """
  Frames left before the transport reaches the end of its score.

      iex> score = TuningFork.Score.new(bpm: 120, beats: 4)
      iex> TuningFork.Transport.remaining(TuningFork.Transport.new(score, 44_100))
      88200

  Zero once it is past the end. What a caller adds to the clock to get the frame the next
  round begins on.
  """
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{} = transport) do
    max(total_frames(transport) - transport.frame, 0)
  end

  @overhang 2.0
  @longest 60

  @doc """
  Render `scores` looping together for `seconds`, without a sound device.

      pcm = Transport.render_loops([bass, drums], 44_100, 8.0)

  Each score keeps its own length and its own place in it, exactly as `TuningFork.Stage`'s
  named loops do — a four-beat loop and a three-beat one drift against each other rather than
  being stretched to match. What comes back is signed 16-bit little-endian PCM, ready for
  `TuningFork.Wav.encode/2`.

  The result is exactly `seconds` long and closes without a seam: whatever is still sounding at
  the end is folded back over the beginning, so a note held across the loop point is heard at
  the start of the next time round.

  Pass `loop_seconds/2` as `seconds` to get a span that holds every score a whole number of
  times. A span ending mid-loop starts that loop again from the top halfway through a bar.
  """
  @spec render_loops([Score.t()], pos_integer(), number(), pos_integer()) :: binary()
  def render_loops(scores, rate, seconds, channels \\ 2)

  def render_loops([], rate, seconds, channels) do
    Mixer.silence(trunc(seconds * rate), channels)
  end

  def render_loops(scores, rate, seconds, channels) do
    render_rounds(Enum.map(scores, &{nil, &1, nil}), rate, seconds, channels)
  end

  @doc """
  Render looping scores that are worked out again each time they come round.

      pcm = Transport.render_rounds([{:bass, first, body}], 44_100, 12.0)

  Each loop is `{name, score, body}`. A `body` is what `TuningFork.Part.Source.compile/1`
  gives: called for each round with that round's own frame, under `name`, so
  `TuningFork.Tick` counters step and `TuningFork.State` values are read as they stand — the
  same thing a `TuningFork.Stage` does with a running loop, done ahead of time instead.

  A `nil` body plays its score every time round. A body that will not run leaves the round
  before it playing again.

  Otherwise this is `render_loops/4`: the same span, the same fold over the loop point.
  """
  @spec render_rounds(
          [{term(), Score.t(), (-> term()) | nil}],
          pos_integer(),
          number(),
          pos_integer()
        ) ::
          binary()
  def render_rounds(loops, rate, seconds, channels \\ 2)

  def render_rounds([], rate, seconds, channels) do
    Mixer.silence(trunc(seconds * rate), channels)
  end

  def render_rounds(loops, rate, seconds, channels) do
    frames = trunc(seconds * rate)
    over = trunc(@overhang * rate)
    block = 2_048

    running =
      Enum.map(loops, fn {name, score, body} -> {name, new(score, rate, loop: true), body} end)

    {body, running} = blocks(running, frames, 0, block, channels)
    quiet = Enum.map(running, fn {name, transport, _body} -> {name, hushed(transport), nil} end)
    {ring, _done} = blocks(quiet, over, frames, block, channels)

    Mixer.fold(body <> ring, frames, channels)
  end

  defp hushed(%__MODULE__{} = transport) do
    %{transport | score: %{transport.score | notes: [], layers: []}, next: nil}
  end

  defp blocks(loops, frames, played, block, channels, acc \\ <<>>)

  defp blocks(loops, frames, _played, _block, _channels, acc) when frames <= 0, do: {acc, loops}

  defp blocks(loops, frames, played, block, channels, acc) do
    size = min(block, frames)

    {chunks, running} =
      Enum.map_reduce(loops, [], fn {name, transport, body}, done ->
        {chunk, moved} = advance(transport, size, channels)

        moved =
          if rounds(moved) > rounds(transport),
            do: next_round(name, moved, body, played + size),
            else: moved

        {chunk, [{name, moved, body} | done]}
      end)

    mixed = Mixer.mix([Mixer.silence(size, channels) | chunks])

    blocks(Enum.reverse(running), frames - size, played + size, block, channels, acc <> mixed)
  end

  defp next_round(_name, transport, nil, _at), do: transport

  defp next_round(name, transport, body, at) do
    case TuningFork.Store.as(name, at + remaining(transport), body) do
      {:ok, %Score{} = score} -> update(transport, score, at: :round)
      _otherwise -> transport
    end
  end

  @doc """
  Where a looping score has got to `seconds` in: which time round, and which beat of it.

      iex> score = TuningFork.Score.new(bpm: 120, beats: 4)
      iex> TuningFork.Transport.at(score, 3.0)
      %{beat: 2.0, rounds: 1}

  `seconds` is time played in total, so `rounds` counts up without limit. A score of no length
  is always at the start.

  What a front end asks to show a loop's position when the sound is not coming from a
  `TuningFork.Stage`.
  """
  @spec at(Score.t(), number()) :: %{beat: float(), rounds: non_neg_integer()}
  def at(%Score{} = score, seconds) do
    span = Score.duration(score)

    if span <= 0 or seconds < 0 do
      %{beat: 0.0, rounds: 0}
    else
      %{
        beat: Score.seconds_to_beat(score, seconds - span * trunc(seconds / span)),
        rounds: trunc(seconds / span)
      }
    end
  end

  @doc """
  A span holding a whole number of every score in `scores`, at least `at_least` seconds long.

      iex> two = TuningFork.Score.new(bpm: 120, beats: 4)
      iex> three = TuningFork.Score.new(bpm: 120, beats: 3)
      iex> TuningFork.Transport.loop_seconds([two, three], 4)
      6.0

  Four beats at 120 bpm is two seconds and three beats is one and a half, so they come back
  together at six. Asking for eight seconds of that pair gives twelve.

  Lengths are matched to the millisecond. Where they have no common multiple under a minute the
  longest is used instead. An empty list is `at_least`.
  """
  @spec loop_seconds([Score.t()], number()) :: float()
  def loop_seconds(scores, at_least \\ 8)

  def loop_seconds([], at_least), do: at_least * 1.0

  def loop_seconds(scores, at_least) do
    period = period(scores)
    rounds = max(1, ceil(round(at_least * 1_000) / period))

    period * rounds / 1_000
  end

  defp period(scores) do
    lengths = Enum.map(scores, &max(1, round(Score.duration(&1) * 1_000)))
    together = Enum.reduce(lengths, &lcm/2)

    if together <= @longest * 1_000, do: together, else: Enum.max(lengths)
  end

  defp lcm(a, b), do: div(a * b, Integer.gcd(a, b))

  @doc """
  Whether the transport has run past the end of its score and nothing is still sounding.

  Always false when looping.
  """
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{loop: true}), do: false

  def finished?(%__MODULE__{} = transport) do
    transport.frame >= total_frames(transport) and transport.sounding == []
  end

  @doc "Stop advancing. Notes already sounding stop with it rather than ringing on."
  @spec pause(t()) :: t()
  def pause(%__MODULE__{} = transport), do: %{transport | playing: false}

  @doc "Carry on from where it stopped."
  @spec play(t()) :: t()
  def play(%__MODULE__{} = transport), do: %{transport | playing: true}

  @doc """
  Jump to `beat`, read through the score's tempo map.

  Whatever was sounding is dropped.
  """
  @spec seek(t(), number()) :: t()
  def seek(%__MODULE__{} = transport, beat) do
    seconds = Score.beat_to_seconds(transport.score, beat)

    %{transport | frame: trunc(seconds * transport.rate), sounding: []}
  end

  @doc """
  Swap the score without stopping.

  The position is kept, so the new score is heard from the next block rather than from the
  top. Notes already sounding finish as the score read when they started.

  ## When it takes over

    * `at: :now`, the default, is the next block
    * `at: :round` holds it until the loop comes round, so it starts on the downbeat

  A transport that is not looping has no round to wait for, so `at: :round` is `at: :now`
  there. Only one score can be waiting; a second replaces the first.
  """
  @spec update(t(), Score.t(), keyword()) :: t()
  def update(transport, score, opts \\ [])

  def update(%__MODULE__{loop: true} = transport, %Score{} = score, opts) do
    case Keyword.get(opts, :at, :now) do
      :round -> %{transport | next: score}
      :now -> %{transport | score: score, next: nil}
    end
  end

  def update(%__MODULE__{} = transport, %Score{} = score, _opts) do
    %{transport | score: score, next: nil}
  end

  @doc "Which beat the transport is on, read through the score's tempo map."
  @spec beat(t()) :: float()
  def beat(%__MODULE__{} = transport) do
    Score.seconds_to_beat(transport.score, transport.frame / transport.rate)
  end

  @doc "How many voices are sounding right now."
  @spec sounding(t()) :: non_neg_integer()
  def sounding(%__MODULE__{sounding: sounding}), do: length(sounding)

  defp total_frames(%__MODULE__{} = transport) do
    trunc(Score.duration(transport.score) * transport.rate)
  end

  defp start_due(%__MODULE__{} = transport, frames) do
    from = transport.frame
    to = from + frames
    total = total_frames(transport)

    windows =
      if transport.loop and total > 0 and to > total do
        [{from, total, 0}, {0, to - total, total - from}]
      else
        [{from, to, 0}]
      end

    Enum.flat_map(windows, fn {window_from, window_to, shift} ->
      transport
      |> notes_between(window_from, window_to)
      |> Enum.map(fn {offset, voice, fx} ->
        {offset - window_from + shift, Live.start(voice, transport.rate), fx}
      end)
    end)
  end

  defp notes_between(%__MODULE__{} = transport, from, to) do
    score = transport.score

    from_beat = Score.seconds_to_beat(score, from / transport.rate)
    to_beat = Score.seconds_to_beat(score, to / transport.rate)

    score
    |> all_notes()
    |> Enum.filter(fn {beat, _voice, _fx} -> beat >= from_beat and beat < to_beat end)
    |> Enum.map(fn {beat, voice, fx} ->
      {trunc(Score.beat_to_seconds(score, beat) * transport.rate), voice, fx}
    end)
  end

  defp all_notes(%Score{} = score) do
    plain = Enum.map(score.notes, fn {beat, voice} -> {beat, voice, []} end)

    Enum.reduce(score.layers, plain, fn layer, acc ->
      acc ++ Enum.map(layer.notes, fn {beat, voice} -> {beat, voice, layer.fx} end)
    end)
  end

  defp advance_all(sounding, frames, channels) do
    {grouped, kept} =
      Enum.reduce(sounding, {%{}, []}, fn {offset, live, fx}, {grouped, kept} ->
        {pcm, live} = Live.advance(live, frames - offset, channels)

        grouped =
          if pcm == <<>>,
            do: grouped,
            else:
              Map.update(
                grouped,
                fx,
                [place(pcm, offset, channels)],
                &[place(pcm, offset, channels) | &1]
              )

        kept = if Live.done?(live), do: kept, else: [{0, live, fx} | kept]

        {grouped, kept}
      end)

    {grouped, Enum.reverse(kept)}
  end

  defp effected(grouped, chains, frames, channels, rate) do
    {dry, wet} = Map.pop(grouped, [], [])
    silence = Mixer.silence(frames, channels)
    idle = @tail_seconds * rate

    {blocks, chains} =
      chains
      |> Map.merge(Map.new(wet, fn {fx, _blocks} -> {fx, nil} end), fn _fx, kept, _new -> kept end)
      |> Enum.flat_map_reduce(%{}, fn {fx, chain}, acc ->
        {live, quiet} = chain || {Fx.Live.new(fx, rate, channels), 0}
        blocks = Map.get(wet, fx, [])
        quiet = if blocks == [], do: quiet + frames, else: 0
        {out, live} = Fx.Live.advance(live, Mixer.mix([silence | blocks]))

        if quiet > idle, do: {[], acc}, else: {[out], Map.put(acc, fx, {live, quiet})}
      end)

    {dry ++ blocks, chains}
  end

  defp place(pcm, 0, _channels), do: pcm
  defp place(pcm, offset, channels), do: Mixer.silence(offset, channels) <> pcm
end

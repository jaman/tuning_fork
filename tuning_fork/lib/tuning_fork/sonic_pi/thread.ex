defmodule TuningFork.SonicPi.Thread do
  @moduledoc """
  What one Sonic Pi thread carries while its code runs, and the score it played.
  """

  alias TuningFork.{Curve, Rand, Score, Voice}
  alias TuningFork.SonicPi.{Effects, Names}

  @type event :: %{
          at: float(),
          voice: Voice.t(),
          ref: reference(),
          midi: number() | nil,
          amp: float(),
          segments: [reference()],
          controls: [{float(), keyword()}]
        }

  @type t :: %__MODULE__{
          now: float(),
          bpm: float(),
          synth: atom() | Voice.t(),
          synth_defaults: keyword(),
          sample_defaults: keyword(),
          transpose: integer(),
          rand: Rand.t(),
          events: [event()],
          fx_stack: [reference()],
          fx: %{reference() => %{name: atom(), opts: keyword(), segment: reference()}},
          segments: %{reference() => keyword()},
          capture: boolean(),
          ambient: boolean(),
          loops: [{atom(), (-> term()), map(), float()}]
        }

  defstruct now: 0.0,
            bpm: 60.0,
            synth: :beep,
            synth_defaults: [],
            sample_defaults: [],
            transpose: 0,
            rand: nil,
            events: [],
            fx_stack: [],
            fx: %{},
            segments: %{},
            capture: false,
            ambient: false,
            loops: []

  @doc "A thread at time zero, seeded from `seed`. `capture: true` collects loops; `ambient: true` marks a thread nobody started a round or a buffer for."
  @spec new(term(), keyword()) :: t()
  def new(seed, opts \\ []) do
    %__MODULE__{
      rand: Rand.new(seed),
      capture: Keyword.get(opts, :capture, false),
      ambient: Keyword.get(opts, :ambient, false)
    }
  end

  @doc "Seconds for `beats` at the thread's tempo."
  @spec seconds(t(), number()) :: float()
  def seconds(%__MODULE__{bpm: bpm}, beats), do: beats * 60.0 / bpm

  @doc "Move the thread on by `beats`."
  @spec sleep(t(), number()) :: t()
  def sleep(%__MODULE__{} = thread, beats),
    do: %{thread | now: thread.now + seconds(thread, beats)}

  @doc "Draw from the thread's generator with `fun`, keeping the generator that comes back."
  @spec draw(t(), (Rand.t() -> {value, Rand.t()})) :: {value, t()} when value: term()
  def draw(%__MODULE__{} = thread, fun) do
    {value, rand} = fun.(thread.rand)
    {value, %{thread | rand: rand}}
  end

  @doc "Put a voice, or several, at the thread's time under one node reference."
  @spec add(t(), Voice.t() | [Voice.t()], reference(), keyword()) :: t()
  def add(%__MODULE__{} = thread, voices, ref, opts) do
    events =
      voices
      |> List.wrap()
      |> Enum.map(fn voice ->
        %{
          at: max(thread.now, 0.0),
          voice: voice,
          ref: ref,
          midi: Keyword.get(opts, :midi),
          amp: Keyword.get(opts, :amp, 1.0) / 1.0,
          segments: Enum.map(thread.fx_stack, &thread.fx[&1].segment),
          controls: []
        }
      end)

    %{thread | events: events ++ thread.events}
  end

  @doc "Open an effect around what is played until `close_fx/2`."
  @spec open_fx(t(), atom(), keyword()) :: {reference(), t()}
  def open_fx(%__MODULE__{} = thread, name, opts) do
    id = make_ref()
    segment = make_ref()
    fx = Map.put(thread.fx, id, %{name: name, opts: opts, segment: segment})
    segments = Map.put(thread.segments, segment, Effects.to_fx(name, opts))

    {id, %{thread | fx: fx, segments: segments, fx_stack: [id | thread.fx_stack]}}
  end

  @doc "Close the innermost effect."
  @spec close_fx(t(), reference()) :: t()
  def close_fx(%__MODULE__{fx_stack: [id | rest]} = thread, id), do: %{thread | fx_stack: rest}

  @doc "Change an open effect's options for everything played after this moment."
  @spec control_fx(t(), reference(), keyword()) :: t()
  def control_fx(%__MODULE__{} = thread, id, opts) do
    case Map.fetch(thread.fx, id) do
      {:ok, fx} ->
        merged = Keyword.merge(fx.opts, opts)
        segment = make_ref()

        %{
          thread
          | fx: Map.put(thread.fx, id, %{fx | opts: merged, segment: segment}),
            segments: Map.put(thread.segments, segment, Effects.to_fx(fx.name, merged))
        }

      :error ->
        thread
    end
  end

  @doc "Record a change to every note under `ref`, taking effect at the thread's time."
  @spec control_note(t(), reference(), keyword()) :: t()
  def control_note(%__MODULE__{} = thread, ref, opts) do
    events =
      Enum.map(thread.events, fn
        %{ref: ^ref} = event -> %{event | controls: [{thread.now, opts} | event.controls]}
        event -> event
      end)

    %{thread | events: events}
  end

  @doc """
  What the thread played, as a score.

  As a `:loop`, the default, the score is as long as the thread slept, and
  `{:error, message}` comes back when it never slept. Played `:once`, the score runs to the
  end of the last note if that is later, and only a thread that played nothing is an error.
  """
  @spec score(t(), :loop | :once) :: {:ok, Score.t()} | {:error, String.t()}
  def score(thread, mode \\ :loop)

  def score(%__MODULE__{now: now}, :loop) when now <= 0.0,
    do: {:error, "a loop must sleep, or it has no length"}

  def score(%__MODULE__{events: [], now: now}, :once) when now <= 0.0,
    do: {:error, "nothing was played"}

  def score(%__MODULE__{} = thread, :once) do
    ends = Enum.map(thread.events, fn event -> event.at + Voice.duration(event.voice) end)
    score(%{thread | now: Enum.max([thread.now | ends])}, :loop)
  end

  def score(%__MODULE__{} = thread, :loop) do
    {plain, effected} =
      thread.events
      |> Enum.map(&{&1.at, shaped(&1), &1.segments})
      |> Enum.split_with(fn {_at, _voice, segments} -> segments == [] end)

    layers =
      effected
      |> Enum.group_by(fn {_at, _voice, segments} -> segments end)
      |> Enum.map(fn {segments, notes} ->
        %{
          fx: Enum.flat_map(segments, &Map.fetch!(thread.segments, &1)),
          notes: notes |> Enum.map(fn {at, voice, _} -> {at, voice} end) |> Enum.reverse()
        }
      end)

    {:ok,
     %Score{
       Score.new(bpm: 60, beats: thread.now)
       | notes: plain |> Enum.map(fn {at, voice, _} -> {at, voice} end) |> Enum.reverse(),
         layers: layers
     }}
  end

  defp shaped(%{controls: []} = event), do: event.voice

  defp shaped(%{voice: voice} = event) do
    duration = Voice.duration(voice)
    controls = Enum.sort_by(event.controls, &elem(&1, 0))

    curves =
      [:freq, :gain]
      |> Enum.map(&{&1, curve(&1, event, controls, duration)})
      |> Enum.reject(fn {_field, curve} -> is_nil(curve) end)
      |> Map.new()

    %{
      voice
      | curves: Map.merge(voice.curves, curves),
        filter: filtered(voice.filter, event, controls)
    }
  end

  defp filtered(nil, _event, _controls), do: nil

  defp filtered(filter, event, controls) do
    case curve(:cutoff, event, controls, 1.0) do
      nil -> filter
      curve -> %{filter | curve: curve}
    end
  end

  defp curve(field, event, controls, duration) do
    points = Enum.flat_map(controls, &points(field, event, &1, duration))

    if points == [], do: nil, else: settle(points)
  end

  defp points(field, event, {at, opts}, duration) do
    case ratio(field, event, opts) do
      nil ->
        []

      ratio ->
        progress = (at - event.at) / duration
        slide = Keyword.get(opts, slide_key(field), 0) / duration

        if slide > 0.0,
          do: [{progress, :hold}, {progress + slide, ratio}],
          else: [{progress - 1.0e-6, :hold}, {progress, ratio}]
    end
  end

  defp settle(points) do
    {settled, _last} =
      Enum.map_reduce(points, 1.0, fn
        {at, :hold}, last -> {{at, last}, last}
        {at, ratio}, _last -> {{at, ratio}, ratio}
      end)

    Curve.new([{0.0, 1.0} | settled])
  end

  defp ratio(:freq, %{midi: midi}, opts) when not is_nil(midi) do
    case Keyword.get(opts, :note) do
      nil -> nil
      note -> Names.midi_to_hz(Names.midi(note)) / Names.midi_to_hz(midi)
    end
  end

  defp ratio(:gain, %{amp: amp}, opts) do
    case Keyword.get(opts, :amp) do
      nil -> nil
      new -> new / max(amp, 1.0e-6)
    end
  end

  defp ratio(:cutoff, %{voice: %Voice{filter: %{hz: hz}}}, opts) do
    case Keyword.get(opts, :cutoff) do
      nil -> nil
      cutoff -> Names.midi_to_hz(cutoff) / hz
    end
  end

  defp ratio(_field, _event, _opts), do: nil

  defp slide_key(:freq), do: :note_slide
  defp slide_key(:gain), do: :amp_slide
  defp slide_key(:cutoff), do: :cutoff_slide
end

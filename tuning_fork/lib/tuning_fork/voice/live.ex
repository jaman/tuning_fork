defmodule TuningFork.Voice.Live do
  @moduledoc """
  A voice rendered block by block, changeable between blocks.

      live = Live.start(voice, 44_100)
      {pcm, live} = Live.advance(live, 512)
      live = Live.control(live, freq: 660.0)
      {more, live} = Live.advance(live, 512)
  """

  alias TuningFork.{Curve, Envelope, Mixer, Voice}

  @type t :: %__MODULE__{
          voice: Voice.t(),
          rate: pos_integer(),
          frames: pos_integer(),
          index: non_neg_integer(),
          mod: map(),
          state: tuple()
        }

  defstruct [:voice, :rate, :frames, :index, :mod, :state]

  @doc """
  Begin sounding a voice at `rate` samples per second.

  The note's length is fixed here from the voice's envelope; only `release/2` changes it
  afterwards.
  """
  @spec start(Voice.t(), pos_integer()) :: t()
  def start(%Voice{} = voice, rate) do
    %__MODULE__{
      voice: voice,
      rate: rate,
      frames: max(1, trunc(Voice.duration(voice) * rate)),
      index: 0,
      mod: Voice.modulation(voice),
      state: {<<>>, 0.0, voice.seed, 0.0, 0.0, TuningFork.Filter.start(voice.filter), nil, %{}}
    }
  end

  @doc """
  The next `frames` frames of mono PCM, and the voice advanced past them.

  Short at the end: a voice with 100 frames left asked for 512 gives 100. A voice already
  finished gives an empty binary.
  """
  @spec advance(t(), pos_integer()) :: {binary(), t()}
  def advance(%__MODULE__{} = live, frames) do
    take = min(frames, live.frames - live.index)

    if take <= 0 do
      {<<>>, live}
    else
      last = live.index + take - 1

      {_spent, phase, seed, low, high, tone, mouth, extra} = live.state

      start = {<<>>, phase, seed, low, high, tone, mouth, extra}

      state =
        Enum.reduce(live.index..last, start, fn index, acc ->
          Voice.step(live.voice, live.mod, live.rate, live.frames, index, acc)
        end)

      {elem(state, 0), %{live | index: live.index + take, state: put_elem(state, 0, <<>>)}}
    end
  end

  @doc """
  The next `frames` frames panned for `channels` channels, and the voice advanced past them.
  The pan is read once per block.
  """
  @spec advance(t(), pos_integer(), pos_integer()) :: {binary(), t()}
  def advance(%__MODULE__{} = live, frames, channels) do
    {pcm, live} = advance(live, frames)

    {Mixer.pan(pcm, live.voice.pan, channels), live}
  end

  @doc """
  Change the voice from the next block on.

  `changes` are `TuningFork.Voice`'s fields, as a keyword list or a map; an unknown key
  raises `KeyError`. Phase, filter state, noise seed and the note's length are untouched.
  """
  @spec control(t(), keyword() | map()) :: t()
  def control(%__MODULE__{} = live, changes) do
    voice = struct!(live.voice, changes)

    %{live | voice: voice, mod: Voice.modulation(voice)}
  end

  @doc "Whether the voice has finished sounding."
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{index: index, frames: frames}), do: index >= frames

  @doc "How many frames are left before it finishes."
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{index: index, frames: frames}), do: max(frames - index, 0)

  @doc """
  Stop a voice early, falling to silence over `seconds` from the level it has reached.

  The returned voice has a length of `seconds` and starts at frame zero; its curves are held
  at the values they had reached and `:sweep` is 1.0.
  """
  @spec release(t(), float()) :: t()
  def release(%__MODULE__{} = live, seconds \\ 0.02) do
    level = Envelope.level(live.voice.envelope, live.index / live.rate)

    envelope = %Envelope{
      attack: 0.0,
      decay: 0.0,
      sustain: level,
      hold: 0.0,
      release: seconds
    }

    voice = %{live.voice | envelope: envelope, curves: frozen(live), sweep: 1.0}

    %{
      live
      | voice: voice,
        mod: Voice.modulation(voice),
        frames: max(1, trunc(seconds * live.rate)),
        index: 0
    }
  end

  defp frozen(%__MODULE__{} = live) do
    progress = live.index / live.frames

    live.mod
    |> Enum.reject(fn {_field, curve} -> is_nil(curve) end)
    |> Map.new(fn {field, curve} -> {field, Curve.hold(Curve.at(curve, progress))} end)
  end
end

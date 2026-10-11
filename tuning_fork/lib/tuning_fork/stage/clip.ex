defmodule TuningFork.Stage.Clip do
  @moduledoc """
  Mono PCM a stage sounds under a key: read a chunk at a time, and faded to silence when
  let go.

      clip = Clip.new(mono)
      {chunk, clip} = Clip.take(clip, 512)
      clip = Clip.release(clip, 441)
  """

  @type t :: %__MODULE__{pcm: binary(), fade: nil | {float(), pos_integer(), non_neg_integer()}}

  defstruct pcm: <<>>, fade: nil

  @doc "A clip of signed 16-bit little-endian mono `pcm`."
  @spec new(binary()) :: t()
  def new(pcm) when is_binary(pcm), do: %__MODULE__{pcm: pcm}

  @doc """
  The next `frames` frames and the clip after them, or `:done` in place of the clip once
  its PCM or its fade has run out. Short at the end.

      iex> {chunk, :done} = TuningFork.Stage.Clip.take(TuningFork.Stage.Clip.new(<<1, 0, 2, 0>>), 8)
      iex> chunk
      <<1, 0, 2, 0>>
  """
  @spec take(t(), pos_integer()) :: {binary(), t() | :done}
  def take(%__MODULE__{pcm: pcm, fade: nil}, frames) do
    {chunk, rest} = split(pcm, frames)
    {chunk, if(rest == <<>>, do: :done, else: %__MODULE__{pcm: rest})}
  end

  def take(%__MODULE__{pcm: pcm, fade: {level, total, gone}}, frames) do
    {chunk, rest} = split(pcm, min(frames, total - gone))
    faded = fade(chunk, level, total, gone)
    gone = gone + div(byte_size(chunk), 2)

    {faded, fading(rest, {level, total, gone})}
  end

  @doc """
  Let the clip fall silent over `frames` frames from the level it has reached; a clip
  already falling starts the new fall from where it is.
  """
  @spec release(t(), pos_integer()) :: t()
  def release(%__MODULE__{} = clip, frames) when frames > 0,
    do: %{clip | fade: {level(clip), frames, 0}}

  defp fading(<<>>, _fade), do: :done
  defp fading(_rest, {_level, total, gone}) when gone >= total, do: :done
  defp fading(rest, fade), do: %__MODULE__{pcm: rest, fade: fade}

  defp level(%__MODULE__{fade: nil}), do: 1.0
  defp level(%__MODULE__{fade: {level, total, gone}}), do: level * (1.0 - gone / total)

  defp split(pcm, frames) do
    bytes = min(byte_size(pcm), max(frames, 0) * 2)
    <<chunk::binary-size(^bytes), rest::binary>> = pcm
    {chunk, rest}
  end

  defp fade(chunk, level, total, gone) do
    {faded, _index} =
      for <<sample::16-signed-little <- chunk>>, reduce: {<<>>, gone} do
        {acc, index} ->
          scaled = trunc(sample * level * (1.0 - index / total))
          {<<acc::binary, scaled::16-signed-little>>, index + 1}
      end

    faded
  end
end

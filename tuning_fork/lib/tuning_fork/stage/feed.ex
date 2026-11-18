defmodule TuningFork.Stage.Feed do
  @moduledoc """
  A continuous mono PCM source for a stage: blocks of signed 16-bit little-endian samples at
  their own rate are appended as they arrive and read out a chunk at a time at the stage's
  rate, joined without gaps or overlaps however irregularly the blocks arrive.

      feed = Feed.new(55_555, 44_100)
      feed = Feed.append(feed, block)
      {chunk, feed} = Feed.take(feed, 256)

  Reading starts once 40 ms of samples are queued. If the queue runs dry the stream goes quiet
  and starts again when 40 ms are queued. While it plays, the reading speed follows the queue's
  depth by up to 2% so that a source running a little fast or slow neither runs dry nor falls
  behind; a queue deeper than 150 ms is cut back to 40 ms. A stream that has received nothing
  for two seconds is `:done`. `release/2` fades it out over a number of frames.
  """

  @prime_seconds 0.04
  @longest_seconds 0.15
  @idle_seconds 2.0
  @speed_range 0.02

  defstruct [
    :rate,
    :stage_rate,
    queue: <<>>,
    position: 0.0,
    playing?: false,
    idle: 0.0,
    fade: nil
  ]

  @type t :: %__MODULE__{}

  @doc "A stream of samples at `rate`, to be read at `stage_rate`."
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(rate, stage_rate), do: %__MODULE__{rate: rate, stage_rate: stage_rate}

  @doc "Queue a block of signed 16-bit little-endian mono samples."
  @spec append(t(), binary()) :: t()
  def append(%__MODULE__{queue: queue} = stream, pcm) when is_binary(pcm) do
    cut(%{stream | queue: <<queue::binary, pcm::binary>>, idle: 0.0})
  end

  @doc "Fade the stream out over `frames` stage frames from the level it has reached."
  @spec release(t(), pos_integer()) :: t()
  def release(%__MODULE__{} = stream, frames) when frames > 0, do: %{stream | fade: {level(stream), frames, 0}}

  @doc """
  The next `frames` stage frames and the stream after them, or `:done` in place of the stream
  once it has been idle for two seconds or its fade has run out.
  """
  @spec take(t(), pos_integer()) :: {binary(), t() | :done}
  def take(%__MODULE__{} = stream, frames) do
    {chunk, stream} = read(stream, frames)
    finish(faded(chunk, stream), frames)
  end

  defp read(%__MODULE__{playing?: false} = stream, frames) do
    if queued_seconds(stream) >= @prime_seconds,
      do: read(%{stream | playing?: true}, frames),
      else: {silence(frames), idle(stream, frames)}
  end

  defp read(%__MODULE__{} = stream, frames) do
    step = speed(stream)
    needed = trunc(frames * step) + 2

    if available(stream) < needed do
      {chunk, stream} = interpolate(stream, frames, step)
      {chunk, %{stream | playing?: false}}
    else
      interpolate(stream, frames, step)
    end
  end

  defp interpolate(%__MODULE__{queue: queue, position: position} = stream, frames, step) do
    reach = min(byte_size(queue), (trunc(position + frames * step) + 3) * 2)
    window = for(<<sample::16-signed-little <- binary_part(queue, 0, reach)>>, do: sample) |> List.to_tuple()
    count = byte_size(queue) |> div(2)

    chunk =
      for index <- 0..(frames - 1)//1, into: <<>> do
        place = position + index * step
        base = trunc(place)

        if base + 1 < tuple_size(window) do
          fraction = place - base
          first = elem(window, base)
          value = round(first + (elem(window, base + 1) - first) * fraction)
          <<value::16-signed-little>>
        else
          <<0::16>>
        end
      end

    advanced = position + frames * step |> min(count - 1.0) |> max(0.0)
    whole = trunc(advanced)
    rest = binary_part(queue, whole * 2, byte_size(queue) - whole * 2)
    {chunk, %{stream | queue: rest, position: advanced - whole}}
  end

  defp speed(%__MODULE__{} = stream) do
    offset = (queued_seconds(stream) - @prime_seconds) / @prime_seconds * @speed_range
    stream.rate / stream.stage_rate * (1.0 + min(max(offset, -@speed_range), @speed_range))
  end

  defp cut(%__MODULE__{} = stream) do
    if queued_seconds(stream) > @longest_seconds do
      keep = trunc(@prime_seconds * stream.rate)
      drop = max(trunc(available(stream)) - keep, 0)
      %{stream | queue: binary_part(stream.queue, drop * 2, byte_size(stream.queue) - drop * 2)}
    else
      stream
    end
  end

  defp available(%__MODULE__{queue: queue, position: position}), do: byte_size(queue) / 2 - position

  defp queued_seconds(%__MODULE__{rate: rate} = stream), do: available(stream) / rate

  defp idle(%__MODULE__{idle: idle} = stream, frames), do: %{stream | idle: idle + frames / stream.stage_rate}

  defp silence(frames), do: :binary.copy(<<0, 0>>, frames)

  defp faded(chunk, %__MODULE__{fade: nil} = stream), do: {chunk, stream}

  defp faded(chunk, %__MODULE__{fade: {level, total, gone}} = stream) do
    {faded, used} =
      for <<sample::16-signed-little <- chunk>>, reduce: {<<>>, gone} do
        {acc, index} ->
          scaled = trunc(sample * level * max(1.0 - index / total, 0.0))
          {<<acc::binary, scaled::16-signed-little>>, index + 1}
      end

    {faded, %{stream | fade: {level, total, used}}}
  end

  defp finish({chunk, %__MODULE__{fade: {_level, total, gone}}}, _frames) when gone >= total, do: {chunk, :done}
  defp finish({chunk, %__MODULE__{idle: idle}}, _frames) when idle >= @idle_seconds, do: {chunk, :done}
  defp finish({chunk, stream}, _frames), do: {chunk, stream}

  defp level(%__MODULE__{fade: nil}), do: 1.0
  defp level(%__MODULE__{fade: {level, total, gone}}), do: level * max(1.0 - gone / total, 0.0)
end

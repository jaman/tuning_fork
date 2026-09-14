defmodule TuningFork.Mixer do
  @moduledoc """
  Sums signed 16-bit little-endian PCM buffers, clipping at full scale, and pans mono sound.
  """

  @peak 32_767
  @floor -32_768

  @doc "Sum a list of buffers. An empty list gives an empty buffer."
  @spec mix([binary()]) :: binary()
  def mix([]), do: <<>>
  def mix([only]), do: only
  def mix([first | rest]), do: Enum.reduce(rest, first, &mix(&2, &1))

  @doc """
  Sum two buffers, sample by sample, clipping at full scale. The result is as long as the
  longer buffer.
  """
  @spec mix(binary(), binary()) :: binary()
  def mix(a, b), do: sum(a, b, <<>>)

  @doc """
  Mix `buffer` into `base` starting `offset` frames in; a frame is one sample per `channels`.

  Returns `{result, overflow}`. `result` is always exactly as long as `base`; `overflow` is
  whatever ran off the end, ready to be mixed in somewhere else. An `offset` at or past the
  end of `base` returns `base` unchanged with the whole of `buffer` as overflow.
  """
  @spec mix_at(binary(), binary(), non_neg_integer(), pos_integer()) :: {binary(), binary()}
  def mix_at(base, buffer, offset, channels \\ 2) do
    at = offset * bytes_per_frame(channels)
    space = byte_size(base) - at

    cond do
      space <= 0 ->
        {base, buffer}

      byte_size(buffer) <= space ->
        <<before::binary-size(at), rest::binary>> = base
        {before <> mix(rest, buffer), <<>>}

      true ->
        <<fits::binary-size(space), over::binary>> = buffer
        <<before::binary-size(at), rest::binary>> = base
        {before <> mix(rest, fits), over}
    end
  end

  @doc """
  Take `frames` frames from the front of a buffer.

  Returns `{chunk, rest}`. `chunk` is always exactly `frames` frames, padded with silence if
  the buffer is shorter, in which case `rest` is empty.
  """
  @spec take(binary(), pos_integer(), pos_integer()) :: {binary(), binary()}
  def take(buffer, frames, channels \\ 2) do
    wanted = frames * bytes_per_frame(channels)

    case buffer do
      <<chunk::binary-size(wanted), rest::binary>> ->
        {chunk, rest}

      short ->
        {short <> :binary.copy(<<0, 0>>, div(wanted - byte_size(short), 2)), <<>>}
    end
  end

  @doc """
  Cut `pcm` to `frames` frames, mixing whatever ran past the end back over the start.

      iex> pcm = <<1, 0, 1, 0>> <> <<2, 0, 2, 0>>
      iex> TuningFork.Mixer.fold(pcm, 1, 2)
      <<3, 0, 3, 0>>

  A buffer already `frames` long or shorter comes back as it is.
  """
  @spec fold(binary(), non_neg_integer(), pos_integer()) :: binary()
  def fold(pcm, frames, channels \\ 2) do
    keep = frames * bytes_per_frame(channels)

    case pcm do
      <<head::binary-size(keep), tail::binary>> when tail != <<>> ->
        over = binary_part(tail, 0, min(byte_size(tail), keep))
        {mixed, _over} = mix_at(head, over, 0, channels)

        mixed

      shorter ->
        shorter
    end
  end

  @doc "A buffer of silence, `frames` frames long. A negative `frames` gives an empty buffer."
  @spec silence(non_neg_integer(), pos_integer()) :: binary()
  def silence(frames, channels \\ 2), do: :binary.copy(<<0, 0>>, max(frames, 0) * channels)

  @doc """
  Place a mono buffer in the stereo field, from `-1.0` hard left to `1.0` hard right.

  `pan` outside that range is clamped to it. Panning is constant power, so a centred sound
  sits about 3 dB below its mono render. A `channels` of 1 returns the buffer unchanged.
  """
  @spec pan(binary(), float(), pos_integer()) :: binary()
  def pan(mono, _pan, 1), do: mono
  def pan(mono, pan, _channels) when pan == 0.0, do: centre(mono)

  def pan(mono, pan, _channels) do
    angle = (min(max(pan, -1.0), 1.0) + 1.0) * :math.pi() / 4.0
    {left, right} = {:math.cos(angle), :math.sin(angle)}

    for <<sample::16-signed-little <- mono>>, into: <<>> do
      <<clamp(trunc(sample * left))::16-signed-little,
        clamp(trunc(sample * right))::16-signed-little>>
    end
  end

  @doc "Copy a mono buffer to both channels, at the same constant-power level as `pan/3`."
  @spec centre(binary()) :: binary()
  def centre(mono) do
    level = :math.sqrt(0.5)

    for <<sample::16-signed-little <- mono>>, into: <<>> do
      value = clamp(trunc(sample * level))
      <<value::16-signed-little, value::16-signed-little>>
    end
  end

  @doc "Fold a stereo buffer down to mono by averaging each frame's two samples."
  @spec to_mono(binary()) :: binary()
  def to_mono(stereo) do
    for <<left::16-signed-little, right::16-signed-little <- stereo>>, into: <<>> do
      <<div(left + right, 2)::16-signed-little>>
    end
  end

  @doc "How loud a buffer is overall, as RMS in sample units. An empty buffer is 0.0."
  @spec loudness(binary()) :: float()
  def loudness(<<>>), do: 0.0

  def loudness(pcm) do
    {sum, count} =
      for <<sample::16-signed-little <- pcm>>, reduce: {0, 0} do
        {sum, count} -> {sum + sample * sample, count + 1}
      end

    :math.sqrt(sum / count)
  end

  @doc """
  Scale a buffer so its `loudness/1` is `target`.

  The scaling is limited so that the loudest sample lands no higher than `:ceiling` of full
  scale, default 0.85, which means a very quiet buffer may come back below `target`. A silent
  buffer is returned unchanged.
  """
  @spec normalise(binary(), number(), keyword()) :: binary()
  def normalise(pcm, target, opts \\ []) do
    ceiling = Keyword.get(opts, :ceiling, 0.85) * @peak

    case loudness(pcm) do
      silent when silent == 0.0 ->
        pcm

      current ->
        peak = peak(pcm)
        wanted = target / current
        allowed = if peak > 0, do: ceiling / peak, else: wanted

        scale(pcm, min(wanted, allowed))
    end
  end

  @doc "The largest absolute sample value in a buffer."
  @spec peak(binary()) :: non_neg_integer()
  def peak(pcm) do
    for <<sample::16-signed-little <- pcm>>, reduce: 0 do
      loudest -> max(loudest, abs(sample))
    end
  end

  @doc """
  How many samples sit at full scale.
  """
  @spec clipped(binary()) :: non_neg_integer()
  def clipped(pcm) do
    for <<sample::16-signed-little <- pcm>>, reduce: 0 do
      count -> if sample >= @peak or sample <= @floor, do: count + 1, else: count
    end
  end

  @doc """
  Scale a buffer's amplitude by `gain`, clipping at full scale.

  A gain of 1.0 returns the buffer unchanged; a gain at or below 0.0 gives silence of the
  same length.
  """
  @spec scale(binary(), float()) :: binary()
  def scale(pcm, gain) when gain == 1.0, do: pcm
  def scale(pcm, gain) when gain <= 0.0, do: :binary.copy(<<0, 0>>, div(byte_size(pcm), 2))

  def scale(pcm, gain) do
    for <<sample::16-signed-little <- pcm>>, into: <<>> do
      <<clamp(trunc(sample * gain))::16-signed-little>>
    end
  end

  @doc """
  Round off a buffer's peaks instead of flattening them.

  Samples quieter than `threshold` of full scale pass through untouched; louder ones are bent
  smoothly towards full scale and never reach it, so `clipped/1` on the result is zero.
  `threshold` runs 0.0 to 1.0 and defaults to 0.7; at 1.0 the buffer is returned unchanged.

      iex> loud = for _ <- 1..4, into: <<>>, do: <<32_767::16-signed-little>>
      iex> TuningFork.Mixer.clipped(TuningFork.Mixer.soft_clip(loud))
      0
  """
  @spec soft_clip(binary(), float()) :: binary()
  def soft_clip(pcm, threshold \\ 0.7)

  def soft_clip(pcm, threshold) when threshold >= 1.0, do: pcm

  def soft_clip(pcm, threshold) do
    knee = threshold |> max(0.0) |> min(0.999)
    room = 1.0 - knee

    for <<sample::16-signed-little <- pcm>>, into: <<>> do
      <<bend(sample, knee, room)::16-signed-little>>
    end
  end

  defp bend(sample, knee, room) do
    level = abs(sample) / @peak

    if level <= knee do
      sample
    else
      over = (level - knee) / room
      folded = knee + room * :math.tanh(over)
      sign = if sample < 0, do: -1, else: 1

      clamp(trunc(sign * folded * @peak))
    end
  end

  @doc "Bytes one frame occupies: two per channel."
  @spec bytes_per_frame(pos_integer()) :: pos_integer()
  def bytes_per_frame(channels), do: channels * 2

  defp sum(<<x::16-signed-little, ra::binary>>, <<y::16-signed-little, rb::binary>>, acc) do
    sum(ra, rb, <<acc::binary, clamp(x + y)::16-signed-little>>)
  end

  defp sum(rest, <<>>, acc), do: <<acc::binary, rest::binary>>
  defp sum(<<>>, rest, acc), do: <<acc::binary, rest::binary>>

  defp clamp(value) when value > @peak, do: @peak
  defp clamp(value) when value < @floor, do: @floor
  defp clamp(value), do: value
end

defmodule TuningFork.Mixer do
  @moduledoc """
  Sums signed 16-bit little-endian PCM buffers, clipping at full scale, and pans mono sound.
  """

  @peak 32_767
  @floor -32_768

  @doc "Sum a list of buffers, passing over the silent ones. An empty list gives an empty buffer."
  @spec mix([binary()]) :: binary()
  def mix([]), do: <<>>
  def mix([only]), do: only

  def mix([first | _] = buffers) do
    longest = buffers |> Enum.map(&byte_size/1) |> Enum.max()

    case Enum.reject(buffers, &silent?/1) do
      [] -> Enum.max_by(buffers, &byte_size/1, fn -> first end)
      [only] -> padded(only, longest)
      [sounding | rest] -> rest |> Enum.reduce(sounding, &mix(&2, &1)) |> padded(longest)
    end
  end

  defp padded(pcm, length) when byte_size(pcm) >= length, do: pcm
  defp padded(pcm, length), do: pcm <> :binary.copy(<<0>>, length - byte_size(pcm))

  @zeros :binary.copy(<<0>>, 65_536)

  @doc "Whether every sample of `pcm` is zero."
  @spec silent?(binary()) :: boolean()
  def silent?(pcm) when byte_size(pcm) <= byte_size(@zeros),
    do: pcm == binary_part(@zeros, 0, byte_size(pcm))

  def silent?(pcm), do: pcm == :binary.copy(<<0>>, byte_size(pcm))

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
        <<before::binary-size(^at), rest::binary>> = base
        {before <> mix(rest, buffer), <<>>}

      true ->
        <<fits::binary-size(^space), over::binary>> = buffer
        <<before::binary-size(^at), rest::binary>> = base
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
      <<chunk::binary-size(^wanted), rest::binary>> ->
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
      <<head::binary-size(^keep), tail::binary>> when tail != <<>> ->
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

  @doc """
  Place a mono buffer in the field while its gain and pan move from `from` to `to`, each a
  `{gain, pan}` pair with `pan` as in `pan/3`.

  Each channel's constant-power level moves in a straight line from the first frame to the
  last, so a placement changed between buffers has no step in it. With `channels` 1 only the
  gain moves. Equal `from` and `to` place the buffer as `pan/3` and `scale/2` would.

      Mixer.place(mono, {1.0, 0.0}, {0.5, -1.0}, 2)
  """
  @spec place(binary(), {float(), float()}, {float(), float()}, pos_integer()) :: binary()
  def place(<<>>, _from, _to, _channels), do: <<>>

  def place(mono, from, to, channels) do
    {first, last} = {levels(from, channels), levels(to, channels)}
    steps = max(div(byte_size(mono), 2) - 1, 1)
    glide(mono, 0, steps, first, last, channels, <<>>)
  end

  defp levels({gain, _pan}, 1), do: {max(gain, 0.0), 0.0}

  defp levels({gain, pan}, _channels) do
    angle = (min(max(pan, -1.0), 1.0) + 1.0) * :math.pi() / 4.0
    {max(gain, 0.0) * :math.cos(angle), max(gain, 0.0) * :math.sin(angle)}
  end

  defp glide(<<>>, _index, _steps, _first, _last, _channels, acc), do: acc

  defp glide(<<sample::16-signed-little, rest::binary>>, index, steps, first, last, 1, acc) do
    level = between(elem(first, 0), elem(last, 0), index / steps)
    acc = <<acc::binary, clamp(trunc(sample * level))::16-signed-little>>
    glide(rest, index + 1, steps, first, last, 1, acc)
  end

  defp glide(<<sample::16-signed-little, rest::binary>>, index, steps, first, last, channels, acc) do
    progress = index / steps
    left = between(elem(first, 0), elem(last, 0), progress)
    right = between(elem(first, 1), elem(last, 1), progress)

    acc =
      <<acc::binary, clamp(trunc(sample * left))::16-signed-little,
        clamp(trunc(sample * right))::16-signed-little>>

    glide(rest, index + 1, steps, first, last, channels, acc)
  end

  defp between(from, to, progress), do: from + (to - from) * progress

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
    if silent?(pcm) do
      0
    else
      for <<sample::16-signed-little <- pcm>>, reduce: 0 do
        loudest -> max(loudest, abs(sample))
      end
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
    if silent?(pcm), do: pcm, else: bent(pcm, threshold)
  end

  defp bent(pcm, threshold) do
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

  @doc """
  `pcm`, signed 16-bit little-endian at `from_rate` with `from_channels` channels, as
  `to_rate` with `to_channels`: one channel doubled to two, two folded to one
  (`to_mono/1`), the first two kept of more; a different rate read between frames by
  straight lines. The same rate and channels give `pcm` back as it is.
  """
  @spec fit(binary(), pos_integer(), pos_integer(), pos_integer(), pos_integer()) :: binary()
  def fit(pcm, rate, channels, rate, channels), do: pcm

  def fit(pcm, from_rate, from_channels, to_rate, to_channels) do
    pcm
    |> rechannel(from_channels, to_channels)
    |> resample(from_rate, to_rate, to_channels)
  end

  defp rechannel(pcm, same, same), do: pcm
  defp rechannel(pcm, 1, 2), do: for(<<s::binary-2 <- pcm>>, into: <<>>, do: s <> s)
  defp rechannel(pcm, 2, 1), do: to_mono(pcm)

  defp rechannel(pcm, from, to) when from > 2 do
    skip = (from - to) * 2
    for <<kept::binary-size(^to * 2), _rest::binary-size(^skip) <- pcm>>, into: <<>>, do: kept
  end

  defp resample(pcm, same, same, _channels), do: pcm

  defp resample(pcm, from_rate, to_rate, channels) do
    width = channels * 2
    frames = div(byte_size(pcm), width)
    out = div(frames * to_rate, from_rate)

    for index <- 0..(out - 1)//1, into: <<>> do
      at = index * from_rate / to_rate
      first = min(trunc(at), frames - 1)
      second = min(first + 1, frames - 1)

      interpolated(
        binary_part(pcm, first * width, width),
        binary_part(pcm, second * width, width),
        at - trunc(at)
      )
    end
  end

  defp interpolated(first, second, weight) do
    for {<<a::little-signed-16>>, <<b::little-signed-16>>} <-
          Enum.zip(for(<<s::binary-2 <- first>>, do: s), for(<<s::binary-2 <- second>>, do: s)),
        into: <<>>,
        do: <<round(a + (b - a) * weight)::little-signed-16>>
  end

  defp sum(<<x::16-signed-little, ra::binary>>, <<y::16-signed-little, rb::binary>>, acc) do
    sum(ra, rb, <<acc::binary, clamp(x + y)::16-signed-little>>)
  end

  defp sum(rest, <<>>, acc), do: <<acc::binary, rest::binary>>
  defp sum(<<>>, rest, acc), do: <<acc::binary, rest::binary>>

  defp clamp(value) when value > @peak, do: @peak
  defp clamp(value) when value < @floor, do: @floor
  defp clamp(value), do: value
end

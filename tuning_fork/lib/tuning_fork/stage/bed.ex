defmodule TuningFork.Stage.Bed do
  @moduledoc """
  The looping layers under a `TuningFork.Stage`: named PCM buffers read from one
  playhead, each at its own gain, replaceable at a bar boundary with a cross-fade.

  A bed is `nil` when nothing loops. `chunk/3` produces the next chunk of the mix and the
  bed to carry forward; `replace/3` and `gains/2` change what plays.
  """

  alias TuningFork.Mixer

  @type layer :: %{pcm: binary(), gain: float()}
  @type fade :: %{
          layers: %{term() => layer()},
          position: non_neg_integer(),
          left: non_neg_integer(),
          total: pos_integer()
        }
  @type t :: %__MODULE__{
          layers: %{term() => layer()},
          position: non_neg_integer(),
          pending: nil | {%{term() => layer()}, pos_integer(), non_neg_integer()},
          fade: nil | fade()
        }

  defstruct layers: %{}, position: 0, pending: nil, fade: nil

  @doc """
  Replace, or with `keep: true` extend, the playing set with `pcms`, a map of name to PCM.

  `opts` are those of `TuningFork.Stage.layers/3` plus `:rate`, needed to turn `:fade_ms`
  into frames.
  """
  @spec replace(t() | nil, %{term() => binary()}, keyword()) :: t()
  def replace(bed, pcms, opts) do
    gains = Keyword.get(opts, :gains, %{})

    incoming =
      Map.new(pcms, fn {name, pcm} -> {name, %{pcm: pcm, gain: Map.get(gains, name, 1.0) / 1}} end)

    fade_frames = div(Keyword.get(opts, :fade_ms, 0) * Keyword.get(opts, :rate, 44_100), 1000)

    case {bed, Keyword.get(opts, :at)} do
      {nil, _at} ->
        %__MODULE__{layers: incoming}

      {%__MODULE__{} = bed, {:bar, bar}} when bar > 0 ->
        %{bed | pending: {merged(bed, incoming, opts), bar, fade_frames}}

      {%__MODULE__{} = bed, _now} ->
        switch(bed, merged(bed, incoming, opts), fade_frames)
    end
  end

  defp merged(bed, incoming, opts) do
    if Keyword.get(opts, :keep, false), do: Map.merge(bed.layers, incoming), else: incoming
  end

  defp switch(bed, layers, 0), do: %{bed | layers: layers, pending: nil}

  defp switch(bed, layers, fade_frames) do
    %{
      bed
      | layers: layers,
        pending: nil,
        fade: %{layers: bed.layers, position: bed.position, left: fade_frames, total: fade_frames}
    }
  end

  @doc "Set the gain of the named layers; names not playing are ignored."
  @spec gains(t() | nil, %{term() => number()}) :: t() | nil
  def gains(nil, _gains), do: nil

  def gains(%__MODULE__{} = bed, gains) do
    layers =
      Enum.reduce(gains, bed.layers, fn {name, gain}, acc ->
        case Map.fetch(acc, name) do
          {:ok, layer} -> Map.put(acc, name, %{layer | gain: clamp(gain / 1)})
          :error -> acc
        end
      end)

    %{bed | layers: layers}
  end

  @doc "The playhead in frames, or `nil` for no bed."
  @spec position(t() | nil) :: non_neg_integer() | nil
  def position(nil), do: nil
  def position(%__MODULE__{position: position}), do: position

  @doc "The next `frames` frames of the mix, and the bed to carry forward."
  @spec chunk(t() | nil, pos_integer(), pos_integer()) :: {binary(), t() | nil}
  def chunk(nil, frames, channels), do: {Mixer.silence(frames, channels), nil}

  def chunk(%__MODULE__{} = bed, frames, channels) do
    bed = due(bed, frames)
    current = read(bed.layers, bed.position, frames, channels)
    {mixed, fade} = crossfade(bed.fade, current, frames, channels)

    {mixed, %{bed | position: bed.position + frames, fade: fade}}
  end

  defp due(%__MODULE__{pending: nil} = bed, _frames), do: bed

  defp due(%__MODULE__{pending: {layers, bar, fade_frames}} = bed, frames) do
    if bed.position == 0 or div(bed.position - 1, bar) != div(bed.position + frames - 1, bar) do
      switch(bed, layers, fade_frames)
    else
      bed
    end
  end

  defp read(layers, position, frames, channels) do
    bytes_per_frame = Mixer.bytes_per_frame(channels)
    wanted = frames * bytes_per_frame

    layers
    |> Enum.map(fn {_name, %{pcm: pcm, gain: gain}} ->
      pcm |> read_around(position * bytes_per_frame, wanted, bytes_per_frame) |> Mixer.scale(gain)
    end)
    |> Mixer.mix()
    |> pad(wanted)
  end

  defp pad(<<>>, wanted), do: :binary.copy(<<0>>, wanted)
  defp pad(pcm, _wanted), do: pcm

  defp read_around(pcm, _position, wanted, _bpf) when byte_size(pcm) < 2,
    do: :binary.copy(<<0>>, wanted)

  defp read_around(pcm, position, wanted, bytes_per_frame) do
    size = byte_size(pcm) - rem(byte_size(pcm), bytes_per_frame)
    read_around(pcm, size, rem(position, size), wanted, [])
  end

  defp read_around(_pcm, _size, _position, 0, acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp read_around(pcm, size, position, wanted, acc) do
    position = rem(position, size)
    take = min(wanted, size - position)

    read_around(pcm, size, position + take, wanted - take, [
      binary_part(pcm, position, take) | acc
    ])
  end

  defp crossfade(nil, current, _frames, _channels), do: {current, nil}

  defp crossfade(%{left: 0}, current, _frames, _channels), do: {current, nil}

  defp crossfade(fade, current, frames, channels) do
    outgoing = read(fade.layers, fade.position, frames, channels)
    done = fade.total - fade.left
    from = done / fade.total
    to = min(1.0, (done + frames) / fade.total)

    mixed =
      Mixer.mix([ramp(current, from, to, channels), ramp(outgoing, 1 - from, 1 - to, channels)])

    left = max(0, fade.left - frames)
    {mixed, %{fade | position: fade.position + frames, left: left}}
  end

  defp ramp(pcm, from, to, channels) do
    frames = div(byte_size(pcm), Mixer.bytes_per_frame(channels))

    for <<frame::binary-size(channels * 2) <- pcm>>, reduce: {0, <<>>} do
      {index, acc} ->
        gain = from + (to - from) * index / max(frames - 1, 1)
        {index + 1, acc <> Mixer.scale(frame, gain)}
    end
    |> elem(1)
  end

  defp clamp(gain), do: gain |> max(0.0) |> min(1.0)
end

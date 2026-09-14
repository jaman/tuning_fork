defmodule TuningFork.Fx do
  @moduledoc """
  Effects applied to a whole buffer of rendered audio.

      pcm
      |> Fx.echo(44_100, delay: 0.25, feedback: 0.45, mix: 0.3)
      |> Fx.reverb(44_100, room: 0.8, mix: 0.25)
  """

  import Kernel, except: [apply: 3]

  alias TuningFork.Fx.Live

  @peak 32_767
  @floor -32_768

  @combs [1_557, 1_617, 1_491, 1_422]
  @allpasses [225, 556]

  @doc """
  Repeats, each quieter than the last.

  The result is longer than `pcm` by however long the repeats take to fall below a hundredth
  of full scale, up to 40 of them.

  ## Options

    * `:delay` — seconds between repeats, default 0.25
    * `:feedback` — how much of each repeat feeds the next, clamped to 0.0 to 0.95,
      default 0.4
    * `:mix` — how much of the result is echo, default 0.3
    * `:channels` — samples per frame, default 2
  """
  @spec echo(binary(), pos_integer(), keyword()) :: binary()
  def echo(pcm, rate, opts \\ []) do
    delay = Keyword.get(opts, :delay, 0.25)
    feedback = opts |> Keyword.get(:feedback, 0.4) |> min(0.95) |> max(0.0)
    mix = Keyword.get(opts, :mix, 0.3)
    channels = Keyword.get(opts, :channels, 2)
    step = max(1, trunc(delay * rate)) * channels

    padded = pcm <> zeros(tail_for(feedback, step))
    wet = comb(samples(padded), step, feedback)

    blend(samples(padded), wet, mix)
  end

  @doc """
  A room around the sound.

  Four comb filters at unrelated delays summed, then two allpass filters over the result —
  the Schroeder arrangement. The result is longer than `pcm` by `0.5 + room * 2.0` seconds.

  ## Options

    * `:room` — how long it rings, clamped to 0.0 to 1.0, default 0.6
    * `:damp` — how much the repeats lose their top, clamped to 0.0 to 1.0, default 0.4
    * `:mix` — how much of the result is reverb, default 0.25
    * `:channels` — samples per frame, default 2
  """
  @spec reverb(binary(), pos_integer(), keyword()) :: binary()
  def reverb(pcm, rate, opts \\ []) do
    room = opts |> Keyword.get(:room, 0.6) |> min(1.0) |> max(0.0)
    damp = opts |> Keyword.get(:damp, 0.4) |> min(1.0) |> max(0.0)
    mix = Keyword.get(opts, :mix, 0.25)
    channels = Keyword.get(opts, :channels, 2)
    scaled = &(max(trunc(&1 * rate / 44_100), 1) * channels)

    feedback = 0.7 + room * 0.28
    padded = pcm <> zeros(trunc(rate * (0.5 + room * 2.0)) * channels)
    dry = samples(padded)

    wet =
      @combs
      |> Enum.map(&comb(dry, scaled.(&1), feedback, damp))
      |> average()
      |> then(fn summed -> Enum.reduce(@allpasses, summed, &allpass(&2, scaled.(&1))) end)

    blend(dry, wet, mix)
  end

  @doc """
  Soft clipping through `tanh`, for weight rather than for distortion.

  The result is the same length as `pcm`.

  ## Options

    * `:amount` — clamped to 0.0 to 1.0, default 0.3. Past about 0.5 it is audible as an
      effect rather than as the sound being louder
  """
  @spec drive(binary(), keyword()) :: binary()
  def drive(pcm, opts \\ []) do
    amount = opts |> Keyword.get(:amount, 0.3) |> min(1.0) |> max(0.0)
    gain = 1.0 + amount * 8.0

    for <<sample::16-signed-little <- pcm>>, into: <<>> do
      driven = :math.tanh(sample / @peak * gain) * @peak / (1.0 + amount * 2.0)
      <<clamp(trunc(driven))::16-signed-little>>
    end
  end

  @doc """
  Apply a list of effects in order.

  `effects` is a keyword list of `{name, opts}`, where `name` is `:echo`, `:reverb` or
  `:drive`, or any name `TuningFork.Fx.Live` runs — `:lowpass`, `:slicer`, `:compressor` and
  the rest, with the options listed there; anything else raises `ArgumentError`. `channels`
  is put into each effect's options where it did not name its own.

      Fx.apply(pcm, 44_100, [echo: [delay: 0.3], reverb: [room: 0.9]], 2)
  """
  @spec apply(binary(), pos_integer(), keyword(), pos_integer()) :: binary()
  def apply(pcm, rate, effects, channels \\ 2) do
    Enum.reduce(effects, pcm, fn {name, opts}, acc ->
      opts = Keyword.put_new(opts, :channels, channels)

      case name do
        :echo -> echo(acc, rate, opts)
        :reverb -> reverb(acc, rate, opts)
        :drive -> drive(acc, opts)
        streamed -> streamed(acc, rate, streamed, opts, channels)
      end
    end)
  end

  defp streamed(pcm, rate, name, opts, channels) do
    {out, _state} = [{name, opts}] |> Live.new(rate, channels) |> Live.advance(pcm)
    out
  end

  defp comb(samples, delay, feedback, damp \\ 0.0) do
    delay = max(delay, 1)

    samples
    |> Enum.chunk_every(delay)
    |> Enum.map_reduce({List.duplicate(0.0, delay), 0.0}, fn block, {previous, store} ->
      {out, store} =
        block
        |> Enum.zip(previous)
        |> Enum.map_reduce(store, fn {sample, delayed}, held ->
          held = held * damp + delayed * (1.0 - damp)
          {sample + held * feedback, held}
        end)

      {out, {out, store}}
    end)
    |> elem(0)
    |> Enum.concat()
  end

  defp allpass(samples, delay) do
    delay = max(delay, 1)
    gain = 0.5

    samples
    |> Enum.chunk_every(delay)
    |> Enum.map_reduce(List.duplicate(0.0, delay), fn block, previous ->
      pairs = Enum.zip(block, previous)

      {Enum.map(pairs, fn {sample, delayed} -> delayed - sample * gain end),
       Enum.map(pairs, fn {sample, delayed} -> sample + delayed * gain end)}
    end)
    |> elem(0)
    |> Enum.concat()
  end

  defp average([first | _rest] = lists) do
    count = length(lists)

    lists
    |> Enum.reduce(List.duplicate(0.0, length(first)), fn list, acc ->
      Enum.zip_with(acc, list, &+/2)
    end)
    |> Enum.map(&(&1 / count))
  end

  defp tail_for(feedback, step) when feedback <= 0.0, do: step

  defp tail_for(feedback, step) do
    repeats = :math.log(0.01) / :math.log(feedback)
    trunc(step * min(repeats, 40))
  end

  defp blend(dry, wet, mix) do
    dry
    |> Enum.zip_with(wet, fn d, w ->
      <<clamp(trunc(d * (1.0 - mix) + w * mix))::16-signed-little>>
    end)
    |> IO.iodata_to_binary()
  end

  defp samples(pcm), do: for(<<s::16-signed-little <- pcm>>, do: s * 1.0)

  defp zeros(samples), do: :binary.copy(<<0, 0>>, max(samples, 0))

  defp clamp(value) when value > @peak, do: @peak
  defp clamp(value) when value < @floor, do: @floor
  defp clamp(value), do: value
end

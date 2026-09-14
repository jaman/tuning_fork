defmodule TuningFork.Reverb do
  @moduledoc """
  A reverb whose state carries between calls: Freeverb, eight comb filters into four
  allpasses on each channel.

      reverb = TuningFork.Reverb.new(44_100)
      {wet, reverb} = TuningFork.Reverb.run(reverb, pcm, 2, 0.3, 0.6)
  """

  @combs [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
  @allpasses [556, 441, 341, 225]
  @spread 23
  @reference 44_100
  @peak 32_767
  @damp 0.4 * 0.4
  @allpass_feedback 0.5
  @input_gain 0.015
  @wet_scale 0.5
  @comb_seconds 0.03

  @type channel :: %{
          combs: [{:queue.queue(float()), float()}],
          allpasses: [:queue.queue(float())]
        }

  @type t :: %__MODULE__{rate: pos_integer(), left: channel(), right: channel()}

  defstruct [:rate, :left, :right]

  @doc "A silent room at `rate` samples per second."
  @spec new(pos_integer()) :: t()
  def new(rate) do
    %__MODULE__{rate: rate, left: channel(rate, 0), right: channel(rate, @spread)}
  end

  defp channel(rate, spread) do
    %{
      combs: Enum.map(@combs, &{line(&1 + spread, rate), 0.0}),
      allpasses: Enum.map(@allpasses, &line(&1 + spread, rate))
    }
  end

  defp line(length, rate) do
    size = max(round(length * rate / @reference), 1)

    :queue.from_list(List.duplicate(0.0, size))
  end

  @doc """
  Run `pcm` through the room and return the wet signal and the state to carry to the next
  call.

  `mix` is how much of the room comes back, 0.0 to 1.0, and `size` how long the room rings,
  in seconds to silence, 0.1 to 10.
  `channels` is how the PCM is interleaved: stereo goes through a left and a right room that
  differ slightly, mono through the left. A `mix` at or below zero returns the input
  untouched and leaves the state as it was.
  """
  @spec run(t(), binary(), pos_integer(), number(), number()) :: {binary(), t()}
  def run(%__MODULE__{} = reverb, pcm, _channels, mix, _size) when mix <= 0, do: {pcm, reverb}

  def run(%__MODULE__{} = reverb, pcm, channels, mix, size) do
    wet = mix |> max(0.0) |> min(1.0)
    through(reverb, pcm, channels, size, fn dry, value -> mixed(dry, value, wet) end)
  end

  @doc """
  The room's own sound for `pcm` and nothing of `pcm` itself, for a caller mixing the two in
  its own proportions. `channels` and `size` are as `run/5` takes them.
  """
  @spec wet(t(), binary(), pos_integer(), number()) :: {binary(), t()}
  def wet(%__MODULE__{} = reverb, pcm, channels, size) do
    through(reverb, pcm, channels, size, fn _dry, value ->
      clamp(trunc(value * @wet_scale * @peak))
    end)
  end

  defp through(reverb, pcm, 2, size, out) do
    feedback = room(size)

    {samples, left, right} =
      for <<l::16-signed-little, r::16-signed-little <- pcm>>,
        reduce: {[], reverb.left, reverb.right} do
        {acc, left, right} ->
          {wl, left} = one(left, l / @peak, feedback)
          {wr, right} = one(right, r / @peak, feedback)

          {[out.(r, wr), out.(l, wl) | acc], left, right}
      end

    {samples |> Enum.reverse() |> encode(), %{reverb | left: left, right: right}}
  end

  defp through(reverb, pcm, _mono, size, out) do
    feedback = room(size)

    {samples, left} =
      for <<sample::16-signed-little <- pcm>>, reduce: {[], reverb.left} do
        {acc, left} ->
          {value, left} = one(left, sample / @peak, feedback)

          {[out.(sample, value) | acc], left}
      end

    {samples |> Enum.reverse() |> encode(), %{reverb | left: left}}
  end

  defp room(seconds),
    do: :math.exp(-6.9 * @comb_seconds / (seconds |> max(0.1) |> min(10.0)))

  defp mixed(dry, wet_value, wet) do
    clamp(trunc((dry / @peak * (1.0 - wet * 0.5) + wet_value * wet * @wet_scale) * @peak))
  end

  defp encode(samples) do
    for sample <- samples, into: <<>>, do: <<sample::16-signed-little>>
  end

  defp one(channel, input, feedback) do
    {summed, combs} =
      Enum.map_reduce(channel.combs, [], fn {line, damp}, done ->
        {{:value, stored}, line} = :queue.out(line)
        damped = stored * (1.0 - @damp) + damp * @damp
        written = input * @input_gain + damped * feedback

        {stored, [{:queue.in(written, line), damped} | done]}
      end)

    {value, allpasses} =
      Enum.reduce(channel.allpasses, {Enum.sum(summed), []}, fn line, {carried, done} ->
        {{:value, stored}, line} = :queue.out(line)
        out = stored - carried
        written = carried + stored * @allpass_feedback

        {out, [:queue.in(written, line) | done]}
      end)

    {value, %{combs: Enum.reverse(combs), allpasses: Enum.reverse(allpasses)}}
  end

  defp clamp(value) when value > @peak, do: @peak
  defp clamp(value) when value < -@peak - 1, do: -@peak - 1
  defp clamp(value), do: value
end

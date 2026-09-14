defmodule TuningFork.Fx.Live do
  @moduledoc """
  Effects on a stream, a block at a time, carrying their state between blocks.

      state = Live.new([reverb: [room: 0.8, mix: 0.3]], 44_100, 2)
      {pcm, state} = Live.advance(state, chunk)
  """

  alias TuningFork.Filter

  @type t :: %__MODULE__{stages: [map()], channels: pos_integer()}

  defstruct stages: [], channels: 2

  @streamed [
    :level,
    :lowpass,
    :highpass,
    :bandpass,
    :slicer,
    :tremolo,
    :wobble,
    :crush,
    :compressor,
    :pan,
    :panslicer,
    :flanger
  ]

  @doc "The effect names this runs that `TuningFork.Fx` has no whole-buffer version of."
  @spec streamed() :: [atom()]
  def streamed, do: @streamed

  @peak 32_767
  @floor -32_768

  @combs [1_557, 1_617, 1_491, 1_422]
  @allpasses [225, 556]

  @doc """
  Build the state for a list of effects.

  `effects` is what `TuningFork.Fx.apply/4` takes — `[reverb: [...], echo: [...]]` — with the
  same option keys and defaults. `rate` is samples per second and `channels` samples per
  frame, default 2. An unknown effect name raises `ArgumentError`.
  """
  @spec new(keyword(), pos_integer(), pos_integer()) :: t()
  def new(effects, rate, channels \\ 2) do
    %__MODULE__{stages: Enum.map(effects, &build(&1, rate, channels)), channels: channels}
  end

  @doc """
  Run a block of PCM through, returning it and the state to use for the next block.

  The result is the same length as `pcm`. State with no effects returns the block unchanged.
  """
  @spec advance(t(), binary()) :: {binary(), t()}
  def advance(%__MODULE__{stages: []} = state, pcm), do: {pcm, state}

  def advance(%__MODULE__{} = state, pcm) do
    samples = for <<sample::16-signed-little <- pcm>>, do: sample * 1.0

    {stages, audio} = Enum.map_reduce(state.stages, samples, &through/2)

    {encode(audio), %{state | stages: stages}}
  end

  defp through(stage, audio) do
    {out, updated} = step(stage, audio)
    {updated, out}
  end

  defp build({:echo, opts}, rate, channels) do
    delay = max(1, trunc(Keyword.get(opts, :delay, 0.25) * rate)) * channels

    %{
      kind: :echo,
      mix: Keyword.get(opts, :mix, 0.3),
      feedback: opts |> Keyword.get(:feedback, 0.4) |> min(0.95) |> max(0.0),
      line: line(delay)
    }
  end

  defp build({:reverb, opts}, rate, channels) do
    room = opts |> Keyword.get(:room, 0.6) |> min(1.0) |> max(0.0)
    scaled = &(max(trunc(&1 * rate / 44_100), 1) * channels)

    %{
      kind: :reverb,
      mix: Keyword.get(opts, :mix, 0.25),
      damp: opts |> Keyword.get(:damp, 0.4) |> min(1.0) |> max(0.0),
      feedback: 0.7 + room * 0.28,
      combs: Enum.map(@combs, &{line(scaled.(&1)), 0.0}),
      allpasses: Enum.map(@allpasses, &line(scaled.(&1)))
    }
  end

  defp build({:drive, opts}, _rate, _channels) do
    amount = opts |> Keyword.get(:amount, 0.3) |> min(1.0) |> max(0.0)

    %{kind: :drive, amount: amount, gain: 1.0 + amount * 8.0}
  end

  defp build({:level, opts}, _rate, _channels) do
    %{kind: :level, amp: Keyword.get(opts, :amp, 1.0) * 1.0}
  end

  defp build({kind, opts}, rate, channels) when kind in [:lowpass, :highpass, :bandpass] do
    filter =
      Filter.new(
        hz: Keyword.get(opts, :hz, 1_000),
        q: Keyword.get(opts, :q, 0.7),
        kind: kind,
        model: :svf
      )

    %{
      kind: :filter,
      filter: filter,
      states: List.duplicate(Filter.start(filter), channels),
      rate: rate,
      channels: channels
    }
  end

  defp build({:slicer, opts}, rate, channels) do
    %{
      kind: :slicer,
      lfo: lfo(opts, 0.25, :square),
      amp_min: Keyword.get(opts, :amp_min, 0.0) * 1.0,
      amp_max: Keyword.get(opts, :amp_max, 1.0) * 1.0,
      frame: 0,
      rate: rate,
      channels: channels
    }
  end

  defp build({:tremolo, opts}, rate, channels) do
    depth = opts |> Keyword.get(:depth, 0.5) |> min(1.0) |> max(0.0)

    %{
      kind: :slicer,
      lfo: lfo(opts, 4.0, :sine),
      amp_min: 1.0 - depth,
      amp_max: 1.0,
      frame: 0,
      rate: rate,
      channels: channels
    }
  end

  defp build({:wobble, opts}, rate, channels) do
    low = Keyword.get(opts, :cutoff_min, 260) * 1.0
    filter = Filter.new(hz: low, q: Keyword.get(opts, :q, 2.0), kind: :lowpass, model: :svf)

    %{
      kind: :wobble,
      lfo: lfo(opts, 0.5, :saw),
      filter: filter,
      low: low,
      high: Keyword.get(opts, :cutoff_max, 8_000) * 1.0,
      states: List.duplicate(Filter.start(filter), channels),
      frame: 0,
      rate: rate,
      channels: channels
    }
  end

  defp build({:crush, opts}, rate, channels) do
    bits = opts |> Keyword.get(:bits, 8) |> min(16) |> max(1)

    hold =
      case Keyword.get(opts, :sample_rate) do
        nil -> Keyword.get(opts, :hold, 1)
        sample_rate -> round(rate / max(sample_rate, 1))
      end

    %{
      kind: :crush,
      step: :math.pow(2, 16 - bits),
      hold: hold |> max(1) |> trunc(),
      held: List.duplicate({0, 0.0}, channels),
      channels: channels
    }
  end

  defp build({:compressor, opts}, rate, _channels) do
    %{
      kind: :compressor,
      threshold: Keyword.get(opts, :threshold, 0.2) * 1.0,
      above: Keyword.get(opts, :slope_above, 0.5) * 1.0,
      below: Keyword.get(opts, :slope_below, 1.0) * 1.0,
      attack: coefficient(Keyword.get(opts, :clamp_time, 0.01), rate),
      release: coefficient(Keyword.get(opts, :relax_time, 0.01), rate),
      envelope: 0.0
    }
  end

  defp build({:pan, opts}, _rate, channels) do
    %{
      kind: :pan,
      pan: opts |> Keyword.get(:pan, 0.0) |> min(1.0) |> max(-1.0),
      channels: channels
    }
  end

  defp build({:panslicer, opts}, rate, channels) do
    %{
      kind: :panslicer,
      lfo: lfo(opts, 0.25, :square),
      pan_min: Keyword.get(opts, :pan_min, -1.0) * 1.0,
      pan_max: Keyword.get(opts, :pan_max, 1.0) * 1.0,
      frame: 0,
      rate: rate,
      channels: channels
    }
  end

  defp build({:flanger, opts}, rate, channels) do
    delay = Keyword.get(opts, :delay, 5.0) * rate / 1_000
    depth = Keyword.get(opts, :depth, 5.0) * rate / 1_000

    %{
      kind: :flanger,
      lfo: lfo(opts, 4.0, :sine),
      delay: delay,
      depth: depth,
      size: trunc(delay + depth) + 2,
      feedback: opts |> Keyword.get(:feedback, 0.0) |> min(0.95) |> max(0.0),
      mix: Keyword.get(opts, :mix, 0.5) * 1.0,
      lines: List.duplicate(%{}, channels),
      frame: 0,
      rate: rate,
      channels: channels
    }
  end

  defp build({unknown, _opts}, _rate, _channels) do
    raise ArgumentError, "no such effect: #{inspect(unknown)}"
  end

  defp line(length), do: :queue.from_list(List.duplicate(0.0, max(length, 1)))

  defp step(%{kind: :level} = stage, samples) do
    {Enum.map(samples, &(&1 * stage.amp)), stage}
  end

  defp step(%{kind: :filter} = stage, samples) do
    {out, states} =
      each_channel(samples, stage.states, stage.channels, fn sample, state ->
        Filter.step(stage.filter, sample, state, 0.0, stage.rate)
      end)

    {out, %{stage | states: states}}
  end

  defp step(%{kind: :slicer} = stage, samples) do
    {out, frame} =
      each_frame(samples, stage.frame, stage.channels, fn frame_samples, frame ->
        amp =
          stage.amp_min + (stage.amp_max - stage.amp_min) * lfo_at(stage.lfo, frame, stage.rate)

        Enum.map(frame_samples, &(&1 * amp))
      end)

    {out, %{stage | frame: frame}}
  end

  defp step(%{kind: :wobble} = stage, samples) do
    {out, {states, frame}} =
      Enum.map_reduce(
        Enum.chunk_every(samples, stage.channels),
        {stage.states, stage.frame},
        fn frame_samples, {states, frame} ->
          hz = stage.low * :math.pow(stage.high / stage.low, lfo_at(stage.lfo, frame, stage.rate))
          filter = %{stage.filter | hz: hz}

          {out, states} =
            frame_samples
            |> Enum.zip(states)
            |> Enum.map(fn {sample, state} ->
              Filter.step(filter, sample, state, 0.0, stage.rate)
            end)
            |> Enum.unzip()

          {out, {states, frame + 1}}
        end
      )

    {List.flatten(out), %{stage | states: states, frame: frame}}
  end

  defp step(%{kind: :crush} = stage, samples) do
    {out, held} =
      each_channel(samples, stage.held, stage.channels, fn sample, {count, value} ->
        if count == 0 do
          crushed = trunc(sample / stage.step) * stage.step
          {crushed, {stage.hold - 1, crushed}}
        else
          {value, {count - 1, value}}
        end
      end)

    {out, %{stage | held: held}}
  end

  defp step(%{kind: :compressor} = stage, samples) do
    {out, envelope} =
      Enum.map_reduce(samples, stage.envelope, fn sample, envelope ->
        level = abs(sample) / @peak
        coefficient = if level > envelope, do: stage.attack, else: stage.release
        envelope = envelope + (level - envelope) * (1.0 - coefficient)

        {sample * compression(envelope, stage), envelope}
      end)

    {out, %{stage | envelope: envelope}}
  end

  defp step(%{kind: :pan, channels: 2} = stage, samples) do
    {left, right} = pan_gains(stage.pan)
    {out, _frame} = each_frame(samples, 0, 2, fn [l, r], _frame -> [l * left, r * right] end)

    {out, stage}
  end

  defp step(%{kind: :pan} = stage, samples), do: {samples, stage}

  defp step(%{kind: :panslicer, channels: 2} = stage, samples) do
    {out, frame} =
      each_frame(samples, stage.frame, 2, fn [l, r], frame ->
        pan =
          stage.pan_min + (stage.pan_max - stage.pan_min) * lfo_at(stage.lfo, frame, stage.rate)

        {left, right} = pan_gains(pan)
        [l * left, r * right]
      end)

    {out, %{stage | frame: frame}}
  end

  defp step(%{kind: :panslicer} = stage, samples), do: {samples, stage}

  defp step(%{kind: :flanger} = stage, samples) do
    {out, {lines, frame}} =
      Enum.map_reduce(
        Enum.chunk_every(samples, stage.channels),
        {stage.lines, stage.frame},
        fn frame_samples, {lines, frame} ->
          back = stage.delay + stage.depth * lfo_at(stage.lfo, frame, stage.rate)

          {out, lines} =
            frame_samples
            |> Enum.zip(lines)
            |> Enum.map(fn {sample, line} ->
              delayed = read_back(line, frame, back, stage.size)
              fed = sample + delayed * stage.feedback

              {blend(sample, sample + delayed, stage.mix),
               Map.put(line, rem(frame, stage.size), fed)}
            end)
            |> Enum.unzip()

          {out, {lines, frame + 1}}
        end
      )

    {List.flatten(out), %{stage | lines: lines, frame: frame}}
  end

  defp step(%{kind: :drive} = stage, samples) do
    driven =
      Enum.map(samples, fn sample ->
        :math.tanh(sample / @peak * stage.gain) * @peak / (1.0 + stage.amount * 2.0)
      end)

    {driven, stage}
  end

  defp step(%{kind: :echo} = stage, samples) do
    {out, line} =
      Enum.map_reduce(samples, stage.line, fn sample, line ->
        {{:value, delayed}, line} = :queue.out(line)
        fed = sample + delayed * stage.feedback

        {blend(sample, fed, stage.mix), :queue.in(fed, line)}
      end)

    {out, %{stage | line: line}}
  end

  defp step(%{kind: :reverb} = stage, samples) do
    {wets, combs} = Enum.map_reduce(stage.combs, [], &comb_block(&1, &2, samples, stage))

    {lines, smeared} = Enum.map_reduce(stage.allpasses, average(wets), &allpass_block/2)
    out = Enum.zip_with(samples, smeared, &blend(&1, &2, stage.mix))

    {out, %{stage | combs: Enum.reverse(combs), allpasses: lines}}
  end

  defp comb_block({line, store}, done, samples, stage) do
    {out, {line, store}} =
      Enum.map_reduce(samples, {line, store}, fn sample, {line, held} ->
        {{:value, delayed}, line} = :queue.out(line)
        held = held * stage.damp + delayed * (1.0 - stage.damp)
        fed = sample + held * stage.feedback

        {fed, {:queue.in(fed, line), held}}
      end)

    {out, [{line, store} | done]}
  end

  defp allpass_block(line, samples) do
    gain = 0.5

    {out, line} =
      Enum.map_reduce(samples, line, fn sample, line ->
        {{:value, delayed}, line} = :queue.out(line)
        fed = sample + delayed * gain

        {delayed - sample * gain, :queue.in(fed, line)}
      end)

    {line, out}
  end

  defp lfo(opts, phase, wave) do
    %{
      phase: max(Keyword.get(opts, :phase, phase) * 1.0, 0.001),
      wave: Keyword.get(opts, :wave, wave),
      pulse_width: opts |> Keyword.get(:pulse_width, 0.5) |> min(1.0) |> max(0.0)
    }
  end

  defp lfo_at(%{phase: phase, wave: wave, pulse_width: width}, frame, rate) do
    turns = frame / rate / phase
    position = turns - Float.floor(turns)

    case wave do
      :saw -> 1.0 - position
      :square -> if position < width, do: 1.0, else: 0.0
      :triangle -> 1.0 - abs(2.0 * position - 1.0)
      :sine -> 0.5 + 0.5 * :math.cos(2 * :math.pi() * position)
    end
  end

  defp each_channel(samples, states, channels, fun) do
    {out, {states, _index}} =
      Enum.map_reduce(samples, {states, 0}, fn sample, {states, index} ->
        state = Enum.at(states, index)
        {out, state} = fun.(sample, state)

        {out, {List.replace_at(states, index, state), rem(index + 1, channels)}}
      end)

    {out, states}
  end

  defp each_frame(samples, frame, channels, fun) do
    {out, frame} =
      samples
      |> Enum.chunk_every(channels)
      |> Enum.map_reduce(frame, fn frame_samples, frame ->
        {fun.(frame_samples, frame), frame + 1}
      end)

    {List.flatten(out), frame}
  end

  defp coefficient(seconds, rate), do: :math.exp(-1.0 / max(seconds * rate, 1.0))

  defp compression(envelope, %{threshold: threshold} = stage) when envelope > threshold do
    (threshold + (envelope - threshold) * stage.above) / envelope
  end

  defp compression(envelope, %{threshold: threshold} = stage)
       when envelope > 0.0 and stage.below != 1.0 do
    (threshold - (threshold - envelope) * stage.below) / envelope
  end

  defp compression(_envelope, _stage), do: 1.0

  defp pan_gains(pan) do
    angle = (pan + 1.0) * :math.pi() / 4
    {:math.cos(angle), :math.sin(angle)}
  end

  defp read_back(line, frame, back, size) do
    position = frame - back
    earlier = Float.floor(position)
    fraction = position - earlier
    index = trunc(earlier)

    first = Map.get(line, rem(rem(index, size) + size, size), 0.0)
    second = Map.get(line, rem(rem(index + 1, size) + size, size), 0.0)

    first * (1.0 - fraction) + second * fraction
  end

  defp blend(dry, wet, mix), do: dry * (1.0 - mix) + wet * mix

  defp average([first | _rest] = lists) do
    count = length(lists)

    lists
    |> Enum.reduce(
      List.duplicate(0.0, length(first)),
      &Enum.zip_with(&2, &1, fn a, b -> a + b end)
    )
    |> Enum.map(&(&1 / count))
  end

  defp encode(samples) do
    for sample <- samples, into: <<>>, do: <<clamp(trunc(sample))::16-signed-little>>
  end

  defp clamp(value) when value > @peak, do: @peak
  defp clamp(value) when value < @floor, do: @floor
  defp clamp(value), do: value
end

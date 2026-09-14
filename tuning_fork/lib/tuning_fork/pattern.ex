defmodule TuningFork.Pattern do
  @moduledoc """
  Patterns of events over cycles, queried by span.

      iex> pattern = TuningFork.Pattern.fastcat([:bd, :sn])
      iex> TuningFork.Pattern.first_cycle(pattern)
      [{0.0, 0.5, :bd}, {0.5, 1.0, :sn}]
  """

  alias TuningFork.Pattern.Mini

  @typedoc "A stretch of time, in cycles. The end is exclusive."
  @type span :: {float(), float()}

  @typedoc """
  One event: `whole` is where it sits as written, `nil` for a continuous value; `part` is the
  portion of it a query covers and is never `nil`; `value` is what it is.
  """
  @type event :: %{whole: span() | nil, part: span(), value: term()}

  @type t :: %__MODULE__{query: (span() -> [event()]), steps: number()}

  defstruct query: nil, steps: 1

  @epsilon 1.0e-9

  @doc """
  A pattern from a query function.

  `query` takes a `t:span/0` and returns the events in it. `steps` is how many steps the
  pattern is counted as having — see `steps/1`.
  """
  @spec new((span() -> [event()]), number()) :: t()
  def new(query, steps \\ 1) when is_function(query, 1) do
    %__MODULE__{query: query, steps: steps}
  end

  @doc """
  How many steps this pattern is counted as having. Read by `stepcat/1`, `pace/2` and the
  other stepwise functions; it does not change what the pattern plays.

      iex> TuningFork.Pattern.steps(TuningFork.Pattern.fastcat([:a, :b, :c]))
      3
      iex> TuningFork.Pattern.steps(TuningFork.Pattern.pure(:a))
      1
  """
  @spec steps(t()) :: number()
  def steps(%__MODULE__{steps: steps}), do: steps

  @doc "The same pattern, counted as having `steps` steps. What it plays does not change."
  @spec with_steps(t(), number()) :: t()
  def with_steps(%__MODULE__{} = pattern, steps), do: %{pattern | steps: steps}

  @doc """
  The events of `pattern` between the two cycle positions.

  The span end is exclusive. A zero-width span samples continuous patterns and reports nothing
  discrete. An event the span cuts across is returned with its `whole` intact and its `part`
  shortened to the span.
  """
  @spec query(t(), span()) :: [event()]
  def query(%__MODULE__{query: query}, {from, to}) when to >= from do
    query.({from * 1.0, to * 1.0})
  end

  @doc """
  The onsets of cycle `cycle` as `{from, to, value}` tuples, relative to the cycle start,
  rounded to six places and sorted.
  """
  @spec first_cycle(t(), non_neg_integer()) :: [{float(), float(), term()}]
  def first_cycle(%__MODULE__{} = pattern, cycle \\ 0) do
    pattern
    |> query({cycle * 1.0, cycle + 1.0})
    |> Enum.filter(&onset?/1)
    |> Enum.map(fn %{whole: {from, to}, value: value} ->
      {round_to(from - cycle), round_to(to - cycle), value}
    end)
    |> Enum.sort()
  end

  defp round_to(value), do: Float.round(value, 6)

  @doc """
  Whether this event begins here rather than continuing one already sounding: true when `part`
  starts where `whole` starts, false when `whole` is `nil`.
  """
  @spec onset?(event()) :: boolean()
  def onset?(%{whole: nil}), do: false

  def onset?(%{whole: {whole_from, _}, part: {part_from, _}}),
    do: whole_from >= part_from - @epsilon

  @doc "A pattern with nothing in it."
  @spec silence() :: t()
  def silence, do: new(fn _span -> [] end)

  @doc """
  `value`, once per cycle, filling the cycle.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.pure(:bd))
      [{0.0, 1.0, :bd}]
  """
  @spec pure(term()) :: t()
  def pure(value) do
    new(fn span ->
      for {from, _to} = part <- cycles(span) do
        %{whole: {floor_cycle(from), floor_cycle(from) + 1.0}, part: part, value: value}
      end
    end)
  end

  @doc """
  Everything at once.

      iex> TuningFork.Pattern.first_cycle(
      ...>   TuningFork.Pattern.stack([TuningFork.Pattern.pure(:bd), TuningFork.Pattern.pure(:hh)])
      ...> )
      [{0.0, 1.0, :bd}, {0.0, 1.0, :hh}]
  """
  @spec stack([t()]) :: t()
  def stack([]), do: silence()

  def stack([first | _rest] = patterns) do
    new(fn span -> Enum.flat_map(patterns, &query(&1, span)) end, first.steps)
  end

  @doc """
  One pattern per cycle, in turn: the first on cycle 0, the second on cycle 1, and so on,
  wrapping round. Each keeps its own speed.
  """
  @spec slowcat([t()]) :: t()
  def slowcat([]), do: silence()
  def slowcat([only]), do: only

  def slowcat(patterns) do
    count = length(patterns)

    new(fn span ->
      Enum.flat_map(cycles(span), fn {from, _to} = part ->
        cycle = trunc(floor_cycle(from))
        index = Integer.mod(cycle, count)
        offset = (cycle - div(cycle - index, count)) * 1.0

        patterns
        |> Enum.at(index)
        |> shift_query(part, offset)
      end)
    end)
  end

  defp shift_query(pattern, {from, to}, offset) do
    pattern
    |> query({from - offset, to - offset})
    |> Enum.map(&shift_event(&1, offset))
  end

  @doc """
  All of them inside one cycle, in order.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.fastcat([:bd, :sn, :hh]))
      [{0.0, 0.333333, :bd}, {0.333333, 0.666667, :sn}, {0.666667, 1.0, :hh}]

  A bare value in `items` is taken as `pure/1` of it. The result is counted as
  `length(items)` steps.
  """
  @spec fastcat([t() | term()]) :: t()
  def fastcat([]), do: silence()

  def fastcat(items) do
    patterns = Enum.map(items, &as_pattern/1)

    patterns |> slowcat() |> fast(length(patterns)) |> with_steps(length(patterns))
  end

  defp as_pattern(%__MODULE__{} = pattern), do: pattern
  defp as_pattern(value), do: pure(value)

  @doc """
  Squeeze `pattern` into `1 / factor` of the time, so it repeats `factor` times a cycle.

  A factor of zero or less gives `silence/0`. The step count is carried through unchanged.
  """
  @spec fast(t(), number()) :: t()
  def fast(%__MODULE__{} = pattern, %__MODULE__{} = factors),
    do: patterned(pattern, factors, &fast/2)

  def fast(%__MODULE__{} = pattern, factors) when is_binary(factors),
    do: fast(pattern, Mini.parse(factors))

  def fast(_pattern, factor) when factor <= 0, do: silence()

  def fast(%__MODULE__{} = pattern, factor) do
    pattern |> with_time(&(&1 * factor), &(&1 / factor)) |> with_steps(pattern.steps)
  end

  @doc "Stretch `pattern` over `factor` cycles. The inverse of `fast/2`. `factor` may be a pattern or mini-notation."
  @spec slow(t(), number() | t() | String.t()) :: t()
  def slow(%__MODULE__{} = pattern, %__MODULE__{} = factors),
    do: patterned(pattern, factors, &slow/2)

  def slow(%__MODULE__{} = pattern, factors) when is_binary(factors),
    do: slow(pattern, Mini.parse(factors))

  def slow(_pattern, factor) when factor <= 0, do: silence()
  def slow(%__MODULE__{} = pattern, factor), do: fast(pattern, 1 / factor)

  @doc """
  Apply `fun` with each value of `amounts` over the span that value holds.

      patterned(pattern, mini("<1 2>"), &fast/2)

  `fun` takes the pattern and one value; `fast/2`, `slow/2`, `ply/2` and `clip/2` go through
  this when given a pattern instead of a number.
  """
  @spec patterned(t(), t(), (t(), term() -> t())) :: t()
  def patterned(%__MODULE__{} = pattern, %__MODULE__{} = amounts, fun) do
    new(
      fn span ->
        amounts
        |> query(span)
        |> Enum.flat_map(fn %{part: part, value: amount} ->
          pattern |> fun.(amount) |> query(part)
        end)
      end,
      pattern.steps
    )
  end

  @doc """
  Squeeze one cycle of `pattern` into the first `1 / factor` of every cycle, leaving the rest
  silent. A factor of zero or less gives `silence/0`; a factor of 1 or less leaves the pattern
  as it is.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.fast_gap(TuningFork.Pattern.pure(:x), 4))
      [{0.0, 0.25, :x}]
  """
  @spec fast_gap(t(), number()) :: t()
  def fast_gap(_pattern, factor) when factor <= 0, do: silence()
  def fast_gap(%__MODULE__{} = pattern, factor) when factor <= 1, do: pattern

  def fast_gap(%__MODULE__{} = pattern, factor) do
    new(fn span ->
      Enum.flat_map(cycles(span), &gap_cycle(pattern, factor, &1))
    end)
  end

  defp gap_cycle(pattern, factor, {from, to}) do
    cycle = floor_cycle(from)
    into = fn at -> cycle + min((at - cycle) * factor, 1.0) end
    out_of = fn at -> cycle + (at - cycle) / factor end
    {inner_from, inner_to} = {into.(from), into.(to)}

    if inner_to <= inner_from and to > from do
      []
    else
      pattern
      |> query({inner_from, inner_to})
      |> Enum.map(&%{&1 | whole: map_span(&1.whole, out_of), part: map_span(&1.part, out_of)})
    end
  end

  @doc """
  Squeeze one cycle of `pattern` into the `from`..`to` portion of every cycle. `from` and `to`
  are within 0.0 to 1.0; anything else gives `silence/0`.

      iex> TuningFork.Pattern.first_cycle(
      ...>   TuningFork.Pattern.compress(TuningFork.Pattern.pure(:x), 0.25, 0.75)
      ...> )
      [{0.25, 0.75, :x}]
  """
  @spec compress(t(), number(), number()) :: t()
  def compress(%__MODULE__{} = pattern, from, to) do
    if to <= from or from < 0.0 or to > 1.0 do
      silence()
    else
      pattern |> fast_gap(1 / (to - from)) |> shift(from)
    end
  end

  @doc """
  A cycle divided between `{weight, pattern}` pairs in proportion to their weights. A total
  weight of zero or less gives `silence/0`.

      iex> TuningFork.Pattern.first_cycle(
      ...>   TuningFork.Pattern.timecat([{3, TuningFork.Pattern.pure(:a)}, {1, TuningFork.Pattern.pure(:b)}])
      ...> )
      [{0.0, 0.75, :a}, {0.75, 1.0, :b}]
  """
  @spec timecat([{number(), t()}]) :: t()
  def timecat([]), do: silence()

  def timecat(pairs) do
    total = Enum.sum_by(pairs, fn {weight, _pattern} -> weight end)

    if total <= 0 do
      silence()
    else
      {patterns, _at} =
        Enum.map_reduce(pairs, 0, fn {weight, pattern}, at ->
          {compress(pattern, at / total, (at + weight) / total), at + weight}
        end)

      stack(patterns)
    end
  end

  @doc """
  Shift the pattern on by `1 / n` of a cycle more each cycle, coming back round after `n`.

      iex> pattern = TuningFork.Pattern.iter(TuningFork.Pattern.fastcat([:a, :b, :c, :d]), 4)
      iex> TuningFork.Pattern.first_cycle(pattern, 1)
      [{0.0, 0.25, :b}, {0.25, 0.5, :c}, {0.5, 0.75, :d}, {0.75, 1.0, :a}]
  """
  @spec iter(t(), pos_integer()) :: t()
  def iter(%__MODULE__{} = pattern, n) when n > 0 do
    slowcat(for step <- 0..(n - 1), do: shift(pattern, -step / n))
  end

  @doc """
  Apply `fun` to about `amount` of the events. The same event in the same cycle is chosen the
  same way every run; `seed` chooses a different set.

      sometimes_by(pattern, 0.3, &fast(&1, 2))
  """
  @spec sometimes_by(t(), number(), (t() -> t()), integer()) :: t()
  def sometimes_by(%__MODULE__{} = pattern, amount, fun, seed \\ 0) do
    stack([
      filter_events(pattern, fn event -> roll(event, seed) >= amount end),
      fun.(filter_events(pattern, fn event -> roll(event, seed) < amount end))
    ])
  end

  @doc """
  Repeat each event `n` times inside its own span.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.ply(TuningFork.Pattern.fastcat([:a, :b]), 2))
      [{0.0, 0.25, :a}, {0.25, 0.5, :a}, {0.5, 0.75, :b}, {0.75, 1.0, :b}]
  """
  @spec ply(t(), pos_integer()) :: t()
  def ply(%__MODULE__{} = pattern, %__MODULE__{} = counts), do: patterned(pattern, counts, &ply/2)

  def ply(%__MODULE__{} = pattern, counts) when is_binary(counts),
    do: ply(pattern, Mini.parse(counts))

  def ply(%__MODULE__{} = pattern, n) when n > 0 do
    new(fn span ->
      pattern
      |> query(span)
      |> Enum.filter(&onset?/1)
      |> Enum.flat_map(&pieces(&1, n, span))
      |> Enum.reject(fn %{part: {from, to}} -> to < from end)
    end)
  end

  defp pieces(%{whole: {from, to}, value: value}, n, span) do
    step = (to - from) / n

    for index <- 0..(n - 1) do
      piece = {from + index * step, from + (index + 1) * step}

      %{whole: piece, part: clamp_span(piece, span), value: value}
    end
  end

  defp clamp_span({from, to}, {span_from, span_to}) do
    {max(from, span_from), min(to, span_to)}
  end

  @doc """
  Move the whole of `pattern` later by `amount` cycles. A negative amount moves it earlier.
  """
  @spec shift(t(), number()) :: t()
  def shift(%__MODULE__{} = pattern, amount) do
    with_time(pattern, &(&1 - amount), &(&1 + amount))
  end

  @doc """
  Play each cycle backwards.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.rev(TuningFork.Pattern.fastcat([:a, :b])))
      [{0.0, 0.5, :b}, {0.5, 1.0, :a}]
  """
  @spec rev(t()) :: t()
  def rev(%__MODULE__{} = pattern) do
    new(fn span -> Enum.flat_map(cycles(span), &reflected(pattern, &1)) end)
  end

  defp reflected(pattern, {from, to}) do
    cycle = floor_cycle(from)
    reflect = fn at -> cycle + (cycle + 1.0 - at) end

    pattern
    |> query({reflect.(to), reflect.(from)})
    |> Enum.map(
      &%{&1 | whole: reflect_span(&1.whole, reflect), part: reflect_span(&1.part, reflect)}
    )
  end

  defp reflect_span(nil, _reflect), do: nil
  defp reflect_span({from, to}, reflect), do: {reflect.(to), reflect.(from)}

  @doc """
  Apply `fun` to `pattern` on every `n`th cycle, counting from cycle zero. `fun` takes a
  pattern and returns one; on other cycles the pattern plays as written.

      every(4, &rev/1, pattern)
  """
  @spec every(pos_integer(), (t() -> t()), t()) :: t()
  def every(n, fun, %__MODULE__{} = pattern) when n > 0 do
    when_cycle(&(Integer.mod(&1, n) == 0), fun, pattern)
  end

  @doc """
  Apply `fun` on the cycles `test` returns true for. `test` is given the cycle number, an
  integer counting up from zero.
  """
  @spec when_cycle((integer() -> boolean()), (t() -> t()), t()) :: t()
  def when_cycle(test, fun, %__MODULE__{} = pattern) do
    changed = fun.(pattern)

    new(fn span ->
      Enum.flat_map(cycles(span), &query(chosen(test, &1, changed, pattern), &1))
    end)
  end

  defp chosen(test, {from, _to}, changed, pattern) do
    if test.(trunc(floor_cycle(from))), do: changed, else: pattern
  end

  @doc """
  Lay a changed copy over the original, `amount` cycles later.

      off(pattern, 0.125, &with_value(&1, fn note -> %{note | gain: 0.4} end))
  """
  @spec off(t(), number(), (t() -> t())) :: t()
  def off(%__MODULE__{} = pattern, amount, fun) do
    stack([pattern, fun.(shift(pattern, amount))])
  end

  @doc "Lay `fun` of the pattern over the original, in place."
  @spec superimpose(t(), (t() -> t())) :: t()
  def superimpose(%__MODULE__{} = pattern, fun), do: stack([pattern, fun.(pattern)])

  @doc """
  Drop events at random, keeping about `1 - amount` of them. The same event in the same cycle
  is dropped or kept the same way every run; `seed` chooses a different set of drops.
  """
  @spec degrade(t(), number(), integer()) :: t()
  def degrade(%__MODULE__{} = pattern, amount, seed \\ 0) do
    filter_events(pattern, fn event -> roll(event, seed) >= amount end)
  end

  @doc "Keep only the events `test` returns true for."
  @spec filter_events(t(), (event() -> boolean())) :: t()
  def filter_events(%__MODULE__{} = pattern, test) do
    new(fn span -> pattern |> query(span) |> Enum.filter(test) end, pattern.steps)
  end

  @doc "Replace every value with `fun` of it, leaving the timing alone."
  @spec with_value(t(), (term() -> term())) :: t()
  def with_value(%__MODULE__{} = pattern, fun) do
    new(
      fn span -> pattern |> query(span) |> Enum.map(&%{&1 | value: fun.(&1.value)}) end,
      pattern.steps
    )
  end

  @doc """
  `hits` beats spread as evenly as possible over `steps`, each carrying `pattern`. Rests are
  `silence/0`. A negative `hits` sounds on the rests instead.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.euclid(TuningFork.Pattern.pure(:bd), 3, 8))
      [{0.0, 0.125, :bd}, {0.375, 0.5, :bd}, {0.75, 0.875, :bd}]
  """
  @spec euclid(t(), integer(), pos_integer()) :: t()
  def euclid(%__MODULE__{} = pattern, hits, steps), do: euclid(pattern, hits, steps, 0)

  @doc """
  `euclid/3` with the hits rotated `rotation` steps to the left.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.euclid(TuningFork.Pattern.pure(:bd), 3, 8, 2))
      [{0.125, 0.25, :bd}, {0.5, 0.625, :bd}, {0.75, 0.875, :bd}]
  """
  @spec euclid(t(), integer(), pos_integer(), integer()) :: t()
  def euclid(%__MODULE__{} = pattern, hits, steps, rotation) when steps > 0 do
    booleans =
      if hits >= 0 do
        bjorklund(hits, steps)
      else
        Enum.map(bjorklund(-hits, steps), &(not &1))
      end

    booleans
    |> rotate(rotation)
    |> Enum.map(fn hit -> if hit, do: pattern, else: silence() end)
    |> fastcat()
  end

  @doc """
  `euclid/4` with each argument a pattern, read once a cycle.

      euclid_with(pure(:bd), mini("<3 5>"), pure(8), pure(0))
  """
  @spec euclid_with(t(), t(), t(), t()) :: t()
  def euclid_with(
        %__MODULE__{} = pattern,
        %__MODULE__{} = hits,
        %__MODULE__{} = steps,
        %__MODULE__{} = rotation
      ) do
    new(fn span ->
      Enum.flat_map(cycles(span), &euclid_cycle(pattern, hits, steps, rotation, &1))
    end)
  end

  defp euclid_cycle(pattern, hits, steps, rotation, {from, to}) do
    cycle = floor_cycle(from)

    with h when is_number(h) <- value_at(hits, cycle),
         s when is_number(s) <- value_at(steps, cycle),
         r when is_number(r) <- value_at(rotation, cycle) do
      pattern |> euclid(trunc(h), max(trunc(s), 1), trunc(r)) |> query({from, to})
    else
      _none -> []
    end
  end

  @doc "The value `pattern` holds at `position`, or `nil` where it holds none."
  @spec value_at(t(), number()) :: term()
  def value_at(%__MODULE__{} = pattern, position) do
    at = position * 1.0

    case query(pattern, {at, at}) do
      [%{whole: nil, value: value} | _rest] -> value
      _discrete -> discrete_at(pattern, at)
    end
  end

  defp discrete_at(pattern, at) do
    pattern
    |> query({at, at + @epsilon * 10})
    |> Enum.find_value(fn
      %{whole: {from, to}, value: value} when from <= at + @epsilon and at < to -> value
      _other -> nil
    end)
  end

  defp rotate(list, 0), do: list

  defp rotate(list, by) do
    at = Integer.mod(by, length(list))
    {front, back} = Enum.split(list, at)

    back ++ front
  end

  @doc """
  The on-off pattern `euclid/3` is built from, as a list of booleans.

      iex> TuningFork.Pattern.bjorklund(3, 8)
      [true, false, false, true, false, false, true, false]
  """
  @spec bjorklund(non_neg_integer(), pos_integer()) :: [boolean()]
  def bjorklund(hits, steps) when hits <= 0 or steps <= 0,
    do: List.duplicate(false, max(steps, 0))

  def bjorklund(hits, steps) when hits >= steps, do: List.duplicate(true, steps)

  def bjorklund(hits, steps) do
    front = List.duplicate([true], hits)
    back = List.duplicate([false], steps - hits)

    front |> spread(back) |> List.flatten()
  end

  defp spread(front, back) when length(back) <= 1, do: front ++ back

  defp spread(front, back) when length(front) <= 1, do: front ++ back

  defp spread(front, back) do
    pairs = min(length(front), length(back))

    {paired, front_rest} = Enum.split(front, pairs)
    {tails, back_rest} = Enum.split(back, pairs)

    merged = Enum.zip_with(paired, tails, &(&1 ++ &2))

    spread(merged, front_rest ++ back_rest)
  end

  @doc """
  Chop `pattern` into `n` equal events a cycle, each holding the value sounding at its start,
  discrete or continuous. Where `pattern` has no value at a start, that event is left out.

      segment(sine(), 8)
  """
  @spec segment(t(), pos_integer()) :: t()
  def segment(%__MODULE__{} = pattern, n) when n > 0 do
    shape = fast(pure(:step), n)

    new(fn span -> shape |> query(span) |> Enum.flat_map(&step_of(pattern, &1)) end)
  end

  defp step_of(pattern, %{whole: {from, _to} = whole, part: part}) do
    case value_at(pattern, from) do
      nil -> []
      value -> [%{whole: whole, part: part, value: value}]
    end
  end

  @doc """
  Combine `pattern` with `other`, keeping `pattern`'s wholes: each event of `pattern` is cut into
  parts wherever `other`'s events fall inside it, and `fun` joins the two values. A continuous
  `other` is read once per event, at its start. An event `other` has nothing for is left out.

      iex> left = TuningFork.Pattern.fastcat([:a, :b])
      iex> right = TuningFork.Pattern.fastcat([1, 2, 3])
      iex> TuningFork.Pattern.app_left(left, right, fn a, b -> {a, b} end) |> TuningFork.Pattern.first_cycle()
      [{0.0, 0.5, {:a, 1}}, {0.5, 1.0, {:b, 2}}]
  """
  @spec app_left(t(), t(), (term(), term() -> term())) :: t()
  def app_left(%__MODULE__{} = pattern, %__MODULE__{} = other, fun) do
    new(
      fn span ->
        pattern
        |> query(span)
        |> Enum.flat_map(fn event ->
          other
          |> within(event.whole || event.part, event.part)
          |> Enum.flat_map(&cut(event, &1, fun))
        end)
      end,
      pattern.steps
    )
  end

  defp within(pattern, {from, _to} = whole, part) do
    case query(pattern, part) do
      [%{whole: nil} | _rest] -> pattern |> query({from, from}) |> Enum.map(&%{&1 | part: whole})
      events -> events
    end
  end

  defp cut(event, inner, fun) do
    case intersection(event.part, inner.part) do
      nil -> []
      part -> [%{whole: event.whole, part: part, value: fun.(event.value, inner.value)}]
    end
  end

  defp intersection({a_from, a_to}, {b_from, b_to}) do
    from = max(a_from, b_from)
    to = min(a_to, b_to)

    cond do
      from > to -> nil
      from < to -> {from, to}
      to == a_to and a_from < a_to -> nil
      to == b_to and b_from < b_to -> nil
      true -> {from, to}
    end
  end

  defp sample(pattern, at) do
    case query(pattern, {at, at}) do
      [%{value: value} | _rest] -> {:ok, value}
      [] -> :none
    end
  end

  @doc """
  A continuous pattern: `fun` is given a cycle position and returns the value there. A query
  gets one event with `whole: nil`, sampled at the middle of the span.
  """
  @spec signal((float() -> term())) :: t()
  def signal(fun) when is_function(fun, 1) do
    new(fn {from, to} = span -> [%{whole: nil, part: span, value: fun.((from + to) / 2)}] end)
  end

  @doc "A sine from 0.0 to 1.0 and back, once a cycle."
  @spec sine() :: t()
  def sine, do: signal(fn at -> (:math.sin(2 * :math.pi() * at) + 1) / 2 end)

  @doc "A ramp from 0.0 to 1.0 across each cycle."
  @spec saw() :: t()
  def saw, do: signal(fn at -> at - Float.floor(at) end)

  @doc "A triangle from 0.0 up to 1.0 and back down, once a cycle."
  @spec tri() :: t()
  def tri do
    signal(fn at ->
      phase = at - Float.floor(at)
      if phase < 0.5, do: phase * 2, else: (1.0 - phase) * 2
    end)
  end

  @doc """
  A continuous value from 0.0 to 1.0, hashed from the position and `seed`. The same position
  always gives the same value.
  """
  @spec rand(integer()) :: t()
  def rand(seed \\ 0), do: signal(fn at -> hash(at, seed) end)

  @doc """
  Stretch a 0.0-to-1.0 pattern onto `low`..`high`.

      range(sine(), 200, 2_000)
  """
  @spec range(t(), number(), number()) :: t()
  def range(%__MODULE__{} = pattern, low, high) do
    with_value(pattern, fn value -> low + value * (high - low) end)
  end

  @doc """
  Lay patterns end to end in one cycle, each given room in proportion to its `steps/1`. The
  result is counted as the sum of their steps.

      iex> a = TuningFork.Pattern.fastcat([:a, :b, :c])
      iex> b = TuningFork.Pattern.fastcat([:d, :e])
      iex> TuningFork.Pattern.stepcat([a, b]) |> TuningFork.Pattern.first_cycle()
      [{0.0, 0.2, :a}, {0.2, 0.4, :b}, {0.4, 0.6, :c}, {0.6, 0.8, :d}, {0.8, 1.0, :e}]
  """
  @spec stepcat([t()]) :: t()
  def stepcat([]), do: silence()

  def stepcat(patterns) do
    total = Enum.reduce(patterns, 0, &(&2 + &1.steps))

    patterns
    |> Enum.map(&{&1.steps, &1})
    |> timecat()
    |> with_steps(total)
  end

  @doc """
  One pattern from each group in turn, `stepcat/1`ed into one pattern.

  `groups` are lists of patterns. On the first pass the first of each group is taken, on the
  next the second, and so on, until every group has come back round to its first.

      iex> a = [TuningFork.Pattern.pure(:a), TuningFork.Pattern.pure(:b)]
      iex> TuningFork.Pattern.stepalt([a, [TuningFork.Pattern.pure(:x)]])
      ...> |> TuningFork.Pattern.first_cycle()
      ...> |> Enum.map(&elem(&1, 2))
      [:a, :x, :b, :x]
  """
  @spec stepalt([[t()]]) :: t()
  def stepalt([]), do: silence()

  def stepalt(groups) do
    rounds = groups |> Enum.map(&length/1) |> Enum.reject(&(&1 == 0)) |> lcm()

    for round <- 0..(rounds - 1), group <- groups, group != [] do
      Enum.at(group, Integer.mod(round, length(group)))
    end
    |> Enum.reject(&(&1.steps <= 0))
    |> stepcat()
  end

  defp lcm([]), do: 1
  defp lcm(counts), do: Enum.reduce(counts, 1, &div(&1 * &2, Integer.gcd(&1, &2)))

  @doc """
  Play the pattern at `target` steps a cycle, whatever it was written as. A pattern of zero
  steps gives `silence/0`.

      iex> pattern = TuningFork.Pattern.pace(TuningFork.Pattern.fastcat([:a, :b, :c, :d]), 2)
      iex> TuningFork.Pattern.first_cycle(pattern)
      [{0.0, 0.5, :a}, {0.5, 1.0, :b}]
  """
  @spec pace(t(), number()) :: t()
  def pace(%__MODULE__{steps: steps}, _target) when steps <= 0, do: silence()

  def pace(%__MODULE__{} = pattern, target) when target > 0 do
    pattern |> fast(target / pattern.steps) |> with_steps(target)
  end

  @doc "Count the pattern as `factor` times as many steps, without changing what it plays."
  @spec expand(t(), number()) :: t()
  def expand(%__MODULE__{} = pattern, factor), do: with_steps(pattern, pattern.steps * factor)

  @doc "Count the pattern as `factor` times fewer steps. The other way from `expand/2`."
  @spec contract(t(), number()) :: t()
  def contract(%__MODULE__{} = pattern, factor) when factor != 0 do
    with_steps(pattern, pattern.steps / factor)
  end

  @doc """
  Play the pattern `factor` times over, counted as `factor` times as many steps: `fast/2` and
  `expand/2` together.
  """
  @spec extend(t(), number()) :: t()
  def extend(%__MODULE__{} = pattern, factor) do
    pattern |> fast(factor) |> expand(factor)
  end

  @doc """
  The first `count` steps of the pattern, stretched to fill the cycle.

  A negative `count` takes from the end instead.

      iex> pattern = TuningFork.Pattern.take(TuningFork.Pattern.fastcat([:a, :b, :c, :d]), 2)
      iex> TuningFork.Pattern.first_cycle(pattern)
      [{0.0, 0.5, :a}, {0.5, 1.0, :b}]
  """
  @spec take(t(), number()) :: t()
  def take(%__MODULE__{steps: steps}, _count) when steps <= 0, do: silence()
  def take(_pattern, 0), do: silence()

  def take(%__MODULE__{} = pattern, count) do
    portion = abs(count) / pattern.steps

    cond do
      portion >= 1.0 -> pattern
      count < 0 -> pattern |> zoom(1.0 - portion, 1.0) |> with_steps(abs(count))
      true -> pattern |> zoom(0.0, portion) |> with_steps(count)
    end
  end

  @doc """
  Everything but the first `count` steps, stretched to fill the cycle.

  A negative `count` drops from the end instead.

      iex> pattern = TuningFork.Pattern.drop(TuningFork.Pattern.fastcat([:a, :b, :c, :d]), 2)
      iex> TuningFork.Pattern.first_cycle(pattern)
      [{0.0, 0.5, :c}, {0.5, 1.0, :d}]
  """
  @spec drop(t(), number()) :: t()
  def drop(%__MODULE__{steps: steps}, _count) when steps <= 0, do: silence()
  def drop(%__MODULE__{} = pattern, 0), do: pattern

  def drop(%__MODULE__{} = pattern, count) do
    left = pattern.steps - abs(count)

    if left <= 0, do: silence(), else: take(pattern, if(count < 0, do: left, else: -left))
  end

  @doc """
  Take `by` steps fewer each time round, until there is nothing left, the takes laid end to end
  with `stepcat/1`.
  """
  @spec shrink(t(), pos_integer()) :: t()
  def shrink(%__MODULE__{} = pattern, by \\ 1) when by > 0 do
    counts = wearing_down(pattern.steps, by)

    stepcat(for count <- counts, do: take(pattern, count))
  end

  @doc "Take `by` steps more each time round, up to the whole pattern. `shrink/2` reversed."
  @spec grow(t(), pos_integer()) :: t()
  def grow(%__MODULE__{} = pattern, by \\ 1) when by > 0 do
    counts = pattern.steps |> wearing_down(by) |> Enum.reverse()

    stepcat(for count <- counts, do: take(pattern, count))
  end

  defp wearing_down(steps, by) do
    steps
    |> trunc()
    |> Stream.iterate(&(&1 - by))
    |> Enum.take_while(&(&1 > 0))
  end

  @doc """
  Each pattern in `many` in turn `stepcat/1`ed after `pattern`, one per cycle. `many` must not
  be empty.
  """
  @spec tour(t(), [t()]) :: t()
  def tour(%__MODULE__{} = pattern, many) when many != [] do
    slowcat(for other <- many, do: stepcat([pattern, other]))
  end

  @doc """
  Take one step from each pattern in turn, round and round.

      iex> a = TuningFork.Pattern.fastcat([:a, :b])
      iex> b = TuningFork.Pattern.fastcat([1, 2])
      iex> TuningFork.Pattern.zip([a, b]) |> TuningFork.Pattern.first_cycle()
      [{0.0, 0.25, :a}, {0.25, 0.5, 1}, {0.5, 0.75, :b}, {0.75, 1.0, 2}]
  """
  @spec zip([t()]) :: t()
  def zip([]), do: silence()

  def zip(patterns) do
    steps = patterns |> Enum.map(& &1.steps) |> Enum.max() |> trunc()

    taken =
      for step <- 0..(steps - 1), pattern <- patterns do
        pattern |> drop(step) |> take(1)
      end

    stepcat(taken)
  end

  @doc """
  One pattern per cycle from `patterns`, chosen by `which`: a pattern of whole numbers counting
  from zero, sampled at the start of each cycle and wrapped round the length of the list. A
  cycle where `which` has no number is silent. `patterns` must not be empty.
  """
  @spec pick(t(), [t()]) :: t()
  def pick(%__MODULE__{} = which, patterns) when patterns != [] do
    count = length(patterns)

    new(fn span -> Enum.flat_map(cycles(span), &picked(which, patterns, count, &1)) end)
  end

  defp picked(which, patterns, count, {from, _to} = part) do
    case sample(which, floor_cycle(from)) do
      {:ok, index} when is_number(index) ->
        patterns |> Enum.at(Integer.mod(trunc(index), count)) |> query(part)

      _nothing ->
        []
    end
  end

  @doc """
  Swap `true` and `false` in every value, leaving any other value alone.

      iex> TuningFork.Pattern.invert(TuningFork.Pattern.binary(5))
      ...> |> TuningFork.Pattern.first_cycle()
      ...> |> Enum.map(&elem(&1, 2))
      [true, false, true, false]
  """
  @spec invert(t()) :: t()
  def invert(%__MODULE__{} = pattern) do
    with_value(pattern, fn
      true -> false
      false -> true
      other -> other
    end)
  end

  @doc """
  Smooth continuous noise from 0.0 to 1.0, interpolated between one whole cycle's value and
  the next. `seed` chooses a different sequence.
  """
  @spec perlin(integer()) :: t()
  def perlin(seed \\ 0) do
    signal(fn at ->
      whole = Float.floor(at)
      phase = at - whole
      smooth = phase * phase * (3.0 - 2.0 * phase)

      hash(whole, seed) * (1.0 - smooth) + hash(whole + 1.0, seed) * smooth
    end)
  end

  @doc """
  One of `choices`, given as `{weight, value}` pairs, per cycle, held for the whole of it.
  `choices` must not be empty.
  """
  @spec wchoose_cycles([{number(), term()}], integer()) :: t()
  def wchoose_cycles(choices, seed \\ 0) when choices != [] do
    total = Enum.reduce(choices, 0.0, fn {weight, _value}, acc -> acc + weight end)

    new(fn span ->
      Enum.flat_map(cycles(span), fn {from, _to} = part ->
        cycle = floor_cycle(from)
        value = weighted(choices, hash(cycle, seed) * total)

        [%{whole: {cycle, cycle + 1.0}, part: part, value: value}]
      end)
    end)
  end

  @doc """
  Add `other` to every value, keeping this pattern's timing.

  `other` is a number, a map, or another pattern sampled at each event's start; where a pattern
  has no value there the event is left alone. Two maps are added key by key where they share a
  key and the rest kept; a map and a number add the number to every numeric value.

      iex> pattern = TuningFork.Pattern.add(TuningFork.Pattern.fastcat([0, 2]), 12)
      iex> TuningFork.Pattern.first_cycle(pattern)
      [{0.0, 0.5, 12}, {0.5, 1.0, 14}]
  """
  @spec add(t(), t() | number() | map()) :: t()
  def add(%__MODULE__{} = pattern, other), do: combine(pattern, other, &plus/2)

  @doc "Take `other` away from every value. See `add/2`."
  @spec sub(t(), t() | number() | map()) :: t()
  def sub(%__MODULE__{} = pattern, other), do: combine(pattern, other, &minus/2)

  @doc "Multiply every value by `other`. See `add/2`."
  @spec mul(t(), t() | number() | map()) :: t()
  def mul(%__MODULE__{} = pattern, other), do: combine(pattern, other, &times/2)

  @doc "Divide every value by `other`. Division by zero leaves the value as it was. See `add/2`."
  @spec divide(t(), t() | number() | map()) :: t()
  def divide(%__MODULE__{} = pattern, other), do: combine(pattern, other, &over/2)

  defp combine(pattern, %__MODULE__{} = other, fun) do
    new(fn span -> pattern |> query(span) |> Enum.map(&combined(&1, other, fun)) end)
  end

  defp combine(pattern, value, fun), do: with_value(pattern, &fun.(&1, value))

  defp combined(event, other, fun) do
    {at, _to} = event.whole || event.part

    case sample(other, at) do
      {:ok, value} -> %{event | value: fun.(event.value, value)}
      :none -> event
    end
  end

  defp plus(left, right) when is_number(left) and is_number(right), do: left + right
  defp plus(left, right), do: merge_with(left, right, &plus/2)

  defp minus(left, right) when is_number(left) and is_number(right), do: left - right
  defp minus(left, right), do: merge_with(left, right, &minus/2)

  defp times(left, right) when is_number(left) and is_number(right), do: left * right
  defp times(left, right), do: merge_with(left, right, &times/2)

  defp over(left, right) when is_number(left) and is_number(right) and right != 0,
    do: left / right

  defp over(left, right) when is_number(left) and is_number(right), do: left
  defp over(left, right), do: merge_with(left, right, &over/2)

  defp merge_with(left, right, fun) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, mine, theirs -> fun.(mine, theirs) end)
  end

  defp merge_with(left, right, fun) when is_map(left) and is_number(right) do
    Map.new(left, fn
      {key, value} when is_number(value) -> {key, fun.(value, right)}
      pair -> pair
    end)
  end

  defp merge_with(left, _right, _fun), do: left

  @doc """
  `hits` beats over `steps`, rotated by `rotation`. The same as `euclid/4`.
  """
  @spec euclid_rot(t(), pos_integer(), pos_integer(), integer()) :: t()
  def euclid_rot(%__MODULE__{} = pattern, hits, steps, rotation) do
    euclid(pattern, hits, steps, rotation)
  end

  @doc """
  `hits` beats over `steps`, each held until the next one rather than lasting one step.
  """
  @spec euclid_legato(t(), pos_integer(), pos_integer()) :: t()
  def euclid_legato(%__MODULE__{} = pattern, hits, steps) when steps > 0 do
    slots = bjorklund(hits, steps)
    lengths = run_lengths(slots)

    timecat(for {_on?, length} <- lengths, do: {length, pattern})
    |> filter_events(fn event ->
      {at, _to} = event.whole || event.part
      onset_at?(lengths, steps, at - Float.floor(at))
    end)
  end

  defp run_lengths(slots) do
    slots
    |> Enum.chunk_while(
      nil,
      fn on?, acc ->
        case {on?, acc} do
          {true, nil} -> {:cont, {true, 1}}
          {true, run} -> {:cont, run, {true, 1}}
          {false, nil} -> {:cont, {false, 1}}
          {false, {on, count}} -> {:cont, {on, count + 1}}
        end
      end,
      fn
        nil -> {:cont, []}
        run -> {:cont, run, []}
      end
    )
    |> Enum.reject(&(&1 == []))
  end

  defp onset_at?(lengths, steps, phase) do
    {_at, found} =
      Enum.reduce(lengths, {0.0, false}, fn {on?, length}, {at, found} ->
        width = length / steps
        hit? = on? and abs(phase - at) < @epsilon

        {at + width, found or hit?}
      end)

    found
  end

  @doc """
  Hold every event for `amount` of its own length: below 1.0 shorter, above 1.0 overlapping.
  Continuous events are left alone. A pattern of amounts applies each over its own span, as
  `patterned/3`.
  """
  @spec clip(t(), number() | t()) :: t()
  def clip(%__MODULE__{} = pattern, %__MODULE__{} = amounts),
    do: patterned(pattern, amounts, &clip/2)

  def clip(%__MODULE__{} = pattern, amount) when amount > 0 do
    new(fn span ->
      pattern
      |> query(span)
      |> Enum.map(fn
        %{whole: nil} = event -> event
        %{whole: {from, to}} = event -> %{event | whole: {from, from + (to - from) * amount}}
      end)
    end)
  end

  @doc """
  Spread the values sounding together in one `whole` out into a run of equal events, one after
  another. `mode` is `:up`, `:down`, `:updown` or `:downup`.
  """
  @spec arp(t(), :up | :down | :updown | :downup) :: t()
  def arp(%__MODULE__{} = pattern, mode \\ :up) do
    arp_with(pattern, fn values -> order(values, mode) end)
  end

  @doc "`arp/2` with `fun` ordering the values: it is given the list sounding at once and returns the run."
  @spec arp_with(t(), ([term()] -> [term()])) :: t()
  def arp_with(%__MODULE__{} = pattern, fun) do
    new(fn span ->
      Enum.flat_map(cycles(span), fn part ->
        pattern
        |> query(part)
        |> Enum.filter(&onset?/1)
        |> Enum.group_by(& &1.whole)
        |> Enum.flat_map(&run_of(&1, fun))
      end)
    end)
  end

  defp run_of({{from, to}, events}, fun) do
    values = fun.(Enum.map(events, & &1.value))
    width = (to - from) / max(length(values), 1)

    for {value, index} <- Enum.with_index(values) do
      whole = {from + index * width, from + (index + 1) * width}
      %{whole: whole, part: whole, value: value}
    end
  end

  defp order(values, :up), do: Enum.sort(values)
  defp order(values, :down), do: values |> Enum.sort() |> Enum.reverse()

  defp order(values, :updown) do
    sorted = Enum.sort(values)
    sorted ++ (sorted |> Enum.reverse() |> Enum.slice(1..-2//1))
  end

  defp order(values, :downup) do
    sorted = values |> Enum.sort() |> Enum.reverse()
    sorted ++ (sorted |> Enum.reverse() |> Enum.slice(1..-2//1))
  end

  @doc """
  Play the pattern forwards on even cycles and backwards on odd ones.

      iex> pattern = TuningFork.Pattern.palindrome(TuningFork.Pattern.fastcat([:a, :b]))
      iex> {TuningFork.Pattern.first_cycle(pattern), TuningFork.Pattern.first_cycle(pattern, 1)}
      {[{0.0, 0.5, :a}, {0.5, 1.0, :b}], [{0.0, 0.5, :b}, {0.5, 1.0, :a}]}
  """
  @spec palindrome(t()) :: t()
  def palindrome(%__MODULE__{} = pattern), do: slowcat([pattern, rev(pattern)])

  @doc "`iter/2` the other way round, shifting back rather than on."
  @spec iter_back(t(), pos_integer()) :: t()
  def iter_back(%__MODULE__{} = pattern, n) when n > 0 do
    slowcat(for step <- 0..(n - 1), do: shift(pattern, step / n))
  end

  @doc """
  Play only the first `amount` of each cycle, over and over to fill it.

      iex> pattern = TuningFork.Pattern.linger(TuningFork.Pattern.fastcat([:a, :b, :c, :d]), 0.5)
      iex> TuningFork.Pattern.first_cycle(pattern)
      [{0.0, 0.25, :a}, {0.25, 0.5, :b}, {0.5, 0.75, :a}, {0.75, 1.0, :b}]
  """
  @spec linger(t(), number()) :: t()
  def linger(%__MODULE__{} = pattern, amount) when amount > 0 do
    pattern |> zoom(0.0, amount) |> fast(1 / amount)
  end

  @doc """
  Play the slice of each cycle between `from` and `to`, stretched to fill it.

      iex> pattern = TuningFork.Pattern.zoom(TuningFork.Pattern.fastcat([:a, :b, :c, :d]), 0.25, 0.75)
      iex> TuningFork.Pattern.first_cycle(pattern)
      [{0.0, 0.5, :b}, {0.5, 1.0, :c}]
  """
  @spec zoom(t(), number(), number()) :: t()
  def zoom(%__MODULE__{} = pattern, from, to) when to > from do
    width = to - from

    new(fn span -> Enum.flat_map(cycles(span), &zoomed(pattern, from, width, &1)) end)
  end

  defp zoomed(pattern, from, width, {at, until} = part) do
    cycle = floor_cycle(at)
    into = fn point -> cycle + from + (point - cycle) * width end
    back = fn point -> cycle + (point - cycle - from) / width end

    pattern
    |> query({into.(at), into.(until)})
    |> Enum.map(&%{&1 | whole: map_span(&1.whole, back), part: map_span(&1.part, back)})
    |> Enum.map(&clip_to(&1, part))
  end

  defp clip_to(event, {from, to}) do
    {part_from, part_to} = event.part

    %{event | part: {max(part_from, from), min(part_to, to)}}
  end

  @doc """
  Slow the pattern down by `n`, apply `fun`, then speed it back up, so `fun` works on `1 / n`
  of a cycle at a time.

      inside(pattern, 2, &rev/1)
  """
  @spec inside(t(), number(), (t() -> t())) :: t()
  def inside(%__MODULE__{} = pattern, n, fun), do: pattern |> slow(n) |> fun.() |> fast(n)

  @doc "`inside/3` with `1 / n`: speed up by `n`, apply `fun`, slow back down."
  @spec outside(t(), number(), (t() -> t())) :: t()
  def outside(%__MODULE__{} = pattern, n, fun), do: inside(pattern, 1 / n, fun)

  @doc """
  Push the second half of each of `n` subdivisions of the cycle late by `amount` of a
  subdivision.

      swing_by(pattern, 1/3, 4)
  """
  @spec swing_by(t(), number(), pos_integer()) :: t()
  def swing_by(%__MODULE__{} = pattern, amount, n) when n > 0 do
    inside(pattern, n, fn inner ->
      stack([
        filter_cycle_half(inner, :first),
        inner |> filter_cycle_half(:second) |> shift(amount)
      ])
    end)
  end

  defp filter_cycle_half(pattern, which) do
    filter_events(pattern, fn event ->
      {from, _to} = event.whole || event.part
      late? = from - Float.floor(from) >= 0.5 - @epsilon

      if which == :second, do: late?, else: not late?
    end)
  end

  @doc "`swing_by/3` with an amount of a third."
  @spec swing(t(), pos_integer()) :: t()
  def swing(%__MODULE__{} = pattern, n), do: swing_by(pattern, 1 / 3, n)

  @doc "Play the stretch of `cycles` cycles starting at cycle `from`, over and over."
  @spec ribbon(t(), number(), pos_integer()) :: t()
  def ribbon(%__MODULE__{} = pattern, from, cycles) when cycles > 0 do
    new(fn span ->
      Enum.flat_map(cycles(span), fn {at, _to} = part ->
        cycle = floor_cycle(at)
        offset = from + :math.fmod(cycle, cycles) - cycle

        pattern |> shift(-offset) |> query(part)
      end)
    end)
  end

  @doc "Apply `fun` on the last cycle of each group of `n`, counting from cycle zero."
  @spec last_of(t(), pos_integer(), (t() -> t())) :: t()
  def last_of(%__MODULE__{} = pattern, n, fun) when n > 0 do
    when_cycle(fn cycle -> rem(cycle, n) == n - 1 end, fun, pattern)
  end

  @doc "Apply `fun` on the first cycle of each group of `n`. The same as `every/3`."
  @spec first_of(t(), pos_integer(), (t() -> t())) :: t()
  def first_of(%__MODULE__{} = pattern, n, fun) when n > 0, do: every(n, fun, pattern)

  @doc """
  Cut the cycle into `n` parts and apply `fun` to a different one each cycle, first to last.
  `fun` is applied to the whole pattern and the result narrowed to the part.

      chunk(pattern, 4, &fast(&1, 2))
  """
  @spec chunk(t(), pos_integer(), (t() -> t())) :: t()
  def chunk(%__MODULE__{} = pattern, n, fun) when n > 0 do
    slowcat(for step <- 0..(n - 1), do: chunk_at(pattern, n, step, fun))
  end

  @doc "`chunk/3` walking backwards through the parts."
  @spec chunk_back(t(), pos_integer(), (t() -> t())) :: t()
  def chunk_back(%__MODULE__{} = pattern, n, fun) when n > 0 do
    slowcat(for step <- 0..(n - 1), do: chunk_at(pattern, n, n - 1 - step, fun))
  end

  @doc "`chunk/3` fitting all `n` parts into one cycle rather than taking `n` cycles over them."
  @spec fast_chunk(t(), pos_integer(), (t() -> t())) :: t()
  def fast_chunk(%__MODULE__{} = pattern, n, fun) when n > 0 do
    fast(chunk(pattern, n, fun), n)
  end

  defp chunk_at(pattern, n, step, fun) do
    from = step / n
    to = (step + 1) / n

    stack([
      pattern |> fun.() |> filter_span(from, to),
      filter_outside(pattern, from, to)
    ])
  end

  defp filter_span(pattern, from, to) do
    filter_events(pattern, fn event -> within?(event, from, to) end)
  end

  defp filter_outside(pattern, from, to) do
    filter_events(pattern, fn event -> not within?(event, from, to) end)
  end

  defp within?(event, from, to) do
    {at, _to} = event.whole || event.part
    phase = at - Float.floor(at)

    phase >= from - @epsilon and phase < to - @epsilon
  end

  @doc """
  Lay every `fun` in the list over the pattern at once.

      layer(pattern, [&rev/1, &fast(&1, 2)])
  """
  @spec layer(t(), [(t() -> t())]) :: t()
  def layer(%__MODULE__{} = pattern, funs), do: stack(Enum.map(funs, & &1.(pattern)))

  @doc """
  `count` copies stacked, each `time` cycles later than the last. `fun` is given each shifted
  copy and its number, 0 upwards, and returns the pattern to stack.
  """
  @spec echo_with(t(), pos_integer(), number(), (t(), non_neg_integer() -> t())) :: t()
  def echo_with(%__MODULE__{} = pattern, count, time, fun) when count > 0 do
    stack(for step <- 0..(count - 1), do: pattern |> shift(step * time) |> fun.(step))
  end

  @doc "`count` copies of the pattern, each `time` later than the one before."
  @spec stut(t(), pos_integer(), number()) :: t()
  def stut(%__MODULE__{} = pattern, count, time) when count > 0 do
    echo_with(pattern, count, time, fn copy, _step -> copy end)
  end

  @doc """
  Replace every event with a pattern of its own, squeezed into the event's `whole`. `fun` is
  given the value and returns the pattern. Continuous events and events straddling a cycle
  line give nothing.
  """
  @spec squeeze_values(t(), (term() -> t())) :: t()
  def squeeze_values(%__MODULE__{} = pattern, fun) do
    new(
      fn span ->
        pattern
        |> query(span)
        |> Enum.flat_map(fn
          %{whole: nil} ->
            []

          %{whole: {from, to}, part: part, value: value} ->
            value |> fun.() |> fitted(from, to) |> query(part)
        end)
      end,
      pattern.steps
    )
  end

  @doc """
  Squeeze one cycle of `pattern` into each event of `structure`. Continuous events and events
  straddling a cycle line give nothing.
  """
  @spec squeeze(t(), t()) :: t()
  def squeeze(%__MODULE__{} = structure, %__MODULE__{} = pattern) do
    new(fn span ->
      structure
      |> query(span)
      |> Enum.flat_map(fn
        %{whole: nil} -> []
        %{whole: {from, to}, part: part} -> pattern |> fitted(from, to) |> query(part)
      end)
    end)
  end

  @doc """
  `{count, pattern}` pairs played in turn, each for `count` cycles. `parts` must not be empty.

      arrange([{2, a}, {1, b}])
  """
  @spec arrange([{pos_integer(), t()}]) :: t()
  def arrange(parts) when parts != [] do
    slowcat(Enum.flat_map(parts, fn {count, pattern} -> List.duplicate(pattern, count) end))
  end

  @doc """
  Play every pattern at once, each stretched so they all run at `steps` steps a cycle.

  `parts` are `{how many steps this pattern has, pattern}` pairs and must not be empty.

      iex> a = TuningFork.Pattern.fastcat([:a, :b, :c])
      iex> b = TuningFork.Pattern.fastcat([:x, :y, :z, :w])
      iex> TuningFork.Pattern.polymeter([{3, a}, {4, b}], 4)
      ...> |> TuningFork.Pattern.first_cycle()
      ...> |> length()
      8
  """
  @spec polymeter([{pos_integer(), t()}], pos_integer()) :: t()
  def polymeter(parts, steps) when parts != [] and steps > 0 do
    stack(Enum.map(parts, fn {length, pattern} -> fast(pattern, steps / length) end))
  end

  @doc """
  The numbers `0` to `n - 1`, one a cycle divided evenly.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.run(4))
      [{0.0, 0.25, 0}, {0.25, 0.5, 1}, {0.5, 0.75, 2}, {0.75, 1.0, 3}]
  """
  @spec run(pos_integer()) :: t()
  def run(n) when n > 0, do: fastcat(Enum.to_list(0..(n - 1)))

  @doc """
  The bits of `number`, most significant first, as a cycle of `true` and `false`.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.binary(5))
      [{0.0, 0.25, false}, {0.25, 0.5, true}, {0.5, 0.75, false}, {0.75, 1.0, true}]
  """
  @spec binary(non_neg_integer()) :: t()
  def binary(number) when number >= 0, do: binary(number, 4)

  @doc "`binary/1` padded to `width` bits."
  @spec binary(non_neg_integer(), pos_integer()) :: t()
  def binary(number, width) when number >= 0 and width > 0 do
    fastcat(for bit <- (width - 1)..0//-1, do: Bitwise.band(Bitwise.bsr(number, bit), 1) == 1)
  end

  @doc "A cosine from 1.0 to 0.0 and back, once a cycle."
  @spec cosine() :: t()
  def cosine, do: signal(fn at -> (:math.cos(2 * :math.pi() * at) + 1) / 2 end)

  @doc "A ramp from 1.0 down to 0.0 across each cycle."
  @spec isaw() :: t()
  def isaw, do: signal(fn at -> 1.0 - (at - Float.floor(at)) end)

  @doc "0.0 for the first half of each cycle and 1.0 for the second."
  @spec square() :: t()
  def square, do: signal(fn at -> if at - Float.floor(at) < 0.5, do: 0.0, else: 1.0 end)

  @doc """
  A continuous whole number from 0 to `n - 1`, from `rand/1`.

      iex> pattern = TuningFork.Pattern.segment(TuningFork.Pattern.irand(8), 4)
      iex> TuningFork.Pattern.first_cycle(pattern) |> Enum.all?(fn {_f, _t, v} -> v in 0..7 end)
      true
  """
  @spec irand(pos_integer(), integer()) :: t()
  def irand(n, seed \\ 0) when n > 0 do
    with_value(rand(seed), fn value -> min(trunc(value * n), n - 1) end)
  end

  @doc "A continuous `true` about `amount` of the time, `false` otherwise, from `rand/1`."
  @spec brand_by(number(), integer()) :: t()
  def brand_by(amount, seed \\ 0), do: with_value(rand(seed), &(&1 < amount))

  @doc "`true` or `false`, evenly."
  @spec brand(integer()) :: t()
  def brand(seed \\ 0), do: brand_by(0.5, seed)

  @doc """
  A continuous pattern of one of `choices`, chosen anew at every instant from `rand/1`.
  `choices` must not be empty.
  """
  @spec choose([term()], integer()) :: t()
  def choose(choices, seed \\ 0) when choices != [] do
    count = length(choices)

    with_value(rand(seed), fn value -> Enum.at(choices, min(trunc(value * count), count - 1)) end)
  end

  @doc "One of `choices` per cycle, held for the whole of it. `choices` must not be empty."
  @spec choose_cycles([term()], integer()) :: t()
  def choose_cycles(choices, seed \\ 0) when choices != [] do
    count = length(choices)

    new(fn span ->
      Enum.flat_map(cycles(span), fn {from, _to} = part ->
        cycle = floor_cycle(from)
        at = min(trunc(hash(cycle, seed) * count), count - 1)

        [%{whole: {cycle, cycle + 1.0}, part: part, value: Enum.at(choices, at)}]
      end)
    end)
  end

  @doc """
  A continuous pattern of one of `choices`, given as `{weight, value}` pairs, chosen anew at
  every instant in proportion to weight. `choices` must not be empty.
  """
  @spec wchoose([{number(), term()}], integer()) :: t()
  def wchoose(choices, seed \\ 0) when choices != [] do
    total = Enum.reduce(choices, 0.0, fn {weight, _value}, acc -> acc + weight end)

    with_value(rand(seed), fn value -> weighted(choices, value * total) end)
  end

  defp weighted([{_weight, value}], _at), do: value

  defp weighted([{weight, value} | rest], at) do
    if at < weight, do: value, else: weighted(rest, at - weight)
  end

  @doc "The same as `degrade/3`."
  @spec degrade_by(t(), number(), integer()) :: t()
  def degrade_by(%__MODULE__{} = pattern, amount, seed \\ 0), do: degrade(pattern, amount, seed)

  @doc "Keep only the events `degrade_by/3` with the same `amount` and `seed` drops."
  @spec undegrade_by(t(), number(), integer()) :: t()
  def undegrade_by(%__MODULE__{} = pattern, amount, seed \\ 0) do
    filter_events(pattern, fn event -> roll(event, seed) < amount end)
  end

  @doc "Keep only the events `degrade/3` with the same `seed` drops, about half."
  @spec undegrade(t(), integer()) :: t()
  def undegrade(%__MODULE__{} = pattern, seed \\ 0), do: undegrade_by(pattern, 0.5, seed)

  @doc "Apply `fun` to about half the events. `sometimes_by/4` with 0.5."
  @spec sometimes(t(), (t() -> t()), integer()) :: t()
  def sometimes(%__MODULE__{} = pattern, fun, seed \\ 0),
    do: sometimes_by(pattern, 0.5, fun, seed)

  @doc "Apply `fun` to about three quarters of the events."
  @spec often(t(), (t() -> t()), integer()) :: t()
  def often(%__MODULE__{} = pattern, fun, seed \\ 0), do: sometimes_by(pattern, 0.75, fun, seed)

  @doc "Apply `fun` to about a quarter of the events."
  @spec rarely(t(), (t() -> t()), integer()) :: t()
  def rarely(%__MODULE__{} = pattern, fun, seed \\ 0), do: sometimes_by(pattern, 0.25, fun, seed)

  @doc "Apply `fun` to about one event in ten."
  @spec almost_never(t(), (t() -> t()), integer()) :: t()
  def almost_never(%__MODULE__{} = pattern, fun, seed \\ 0),
    do: sometimes_by(pattern, 0.1, fun, seed)

  @doc "Apply `fun` to about nine events in ten."
  @spec almost_always(t(), (t() -> t()), integer()) :: t()
  def almost_always(%__MODULE__{} = pattern, fun, seed \\ 0),
    do: sometimes_by(pattern, 0.9, fun, seed)

  @doc "Apply `fun` to the whole pattern."
  @spec always(t(), (t() -> t())) :: t()
  def always(%__MODULE__{} = pattern, fun), do: fun.(pattern)

  @doc "The pattern unchanged; `fun` is ignored."
  @spec never(t(), (t() -> t())) :: t()
  def never(%__MODULE__{} = pattern, _fun), do: pattern

  @doc """
  Apply `fun` to about `amount` of the cycles, whole ones at a time. The same cycle is chosen
  the same way every run; `seed` chooses a different set.
  """
  @spec some_cycles_by(t(), number(), (t() -> t()), integer()) :: t()
  def some_cycles_by(%__MODULE__{} = pattern, amount, fun, seed \\ 0) do
    when_cycle(fn cycle -> hash(cycle * 1.0, seed) < amount end, fun, pattern)
  end

  @doc "Apply `fun` to about half the cycles, whole ones at a time."
  @spec some_cycles(t(), (t() -> t()), integer()) :: t()
  def some_cycles(%__MODULE__{} = pattern, fun, seed \\ 0),
    do: some_cycles_by(pattern, 0.5, fun, seed)

  defp with_time(pattern, on_query, on_event) do
    new(
      fn {from, to} ->
        pattern
        |> query({on_query.(from), on_query.(to)})
        |> Enum.map(fn event ->
          %{event | whole: map_span(event.whole, on_event), part: map_span(event.part, on_event)}
        end)
      end,
      pattern.steps
    )
  end

  defp fitted(pattern, from, to) do
    base = Float.floor(from + @epsilon)

    compress(pattern, from - base, to - base)
  end

  defp map_span(nil, _fun), do: nil
  defp map_span({from, to}, fun), do: {fun.(from), fun.(to)}

  defp shift_event(event, offset) do
    move = &(&1 + offset)

    %{event | whole: map_span(event.whole, move), part: map_span(event.part, move)}
  end

  defp cycles({from, to}) when to - from <= @epsilon, do: [{from, to}]

  defp cycles({from, to}) do
    next = floor_cycle(from) + 1.0

    if to <= next + @epsilon do
      [{from, to}]
    else
      [{from, next} | cycles({next, to})]
    end
  end

  defp floor_cycle(at), do: Float.floor(at + @epsilon)

  defp roll(%{whole: nil, part: {from, _to}}, seed), do: hash(from, seed)
  defp roll(%{whole: {from, _to}}, seed), do: hash(from, seed)

  defp hash(at, seed) do
    :erlang.phash2({Float.round(at * 1.0, 9), seed}, 1_000_000) / 1_000_000
  end
end

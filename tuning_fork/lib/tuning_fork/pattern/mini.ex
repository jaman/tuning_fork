defmodule TuningFork.Pattern.Mini do
  @moduledoc """
  Mini-notation strings parsed into a `TuningFork.Pattern`.

      iex> TuningFork.Pattern.first_cycle(TuningFork.Pattern.Mini.parse("bd sn"))
      [{0.0, 0.5, "bd"}, {0.5, 1.0, "sn"}]
  """

  alias TuningFork.Pattern, as: P

  @doc """
  A pattern from a mini-notation string.

  Accepted syntax: words and numbers in order (`bd sn hh`), `~` for a rest, `[ ]` to
  subdivide one step, `< >` for one per cycle in turn, `,` for layers at the same time, `*n`
  and `/n` for faster and slower, `!n` to repeat as separate steps, `@n` for a step's weight,
  `?` or `?0.3` to drop at random, `(hits,steps)` or `(hits,steps,rotation)` for a euclidean
  rhythm, and `word:n` for an indexed word. Modifiers stack left to right.

  Words come back as strings, bare numbers as numbers, and `bd:3` as the string `"bd:3"`. An
  empty string, or one holding only whitespace, gives `TuningFork.Pattern.silence/0`. A
  string that will not parse raises `ArgumentError` naming what was wrong.
  """
  @spec parse(String.t()) :: P.t()
  def parse(source) when is_binary(source) do
    source |> located() |> P.with_value(fn {value, _span} -> value end)
  end

  @doc """
  The same pattern with every value paired with where it was written, as `{value, {from, to}}`.

  `from` and `to` are character offsets into `source`. Raises `ArgumentError` on a string that
  will not parse.
  """
  @spec located(String.t()) :: P.t()
  def located(source) when is_binary(source) do
    tokens = tokens(source, source)

    {sequences, rest} = sequences(tokens, source)

    case rest do
      [] -> layers(sequences, :fast)
      [{token, _f, _t} | _more] -> raise ArgumentError, unexpected(token, source)
    end
  end

  @doc """
  Where in `source` the thing sounding at `cycle` was written, as `{from, to}`.

  `cycle` is an absolute cycle position: `4.25` is a quarter of the way through cycle four.
  `nil` when nothing is sounding then, or when the source will not parse. Timing applied to
  the parsed pattern outside the string is not seen here.

      iex> TuningFork.Pattern.Mini.locate("bd sn hh", 0.5)
      {3, 5}
      iex> TuningFork.Pattern.Mini.locate("<bd sn>", 1.0)
      {4, 6}
  """
  @spec locate(String.t(), number()) :: {non_neg_integer(), non_neg_integer()} | nil
  def locate(source, cycle) when is_binary(source) do
    at = cycle * 1.0

    source
    |> located()
    |> P.query({at, at + 1.0e-9})
    |> Enum.find_value(fn
      %{value: {_value, span}} -> span
      _other -> nil
    end)
  rescue
    ArgumentError -> nil
  end

  @doc """
  `parse/1` returning `{:ok, pattern}` or `{:error, message}` instead of raising.
  """
  @spec parse_safe(String.t()) :: {:ok, P.t()} | {:error, String.t()}
  def parse_safe(source) when is_binary(source) do
    {:ok, parse(source)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp tokens(source, whole), do: scan(String.to_charlist(source), whole, 0, [])

  defp scan([], _whole, _at, acc), do: Enum.reverse(acc)

  defp scan([char | rest], whole, at, acc) when char in ~c" \t\n\r" do
    scan(rest, whole, at + 1, acc)
  end

  defp scan([char | rest], whole, at, acc) when char in ~c"[]<>(),*/!@?:~" do
    scan(rest, whole, at + 1, [{mark(char), at, at + 1} | acc])
  end

  defp scan([char | _rest] = chars, whole, at, acc) when char in ?0..?9 do
    {number, rest, took} = number(chars)

    scan(rest, whole, at + took, [{{:number, number}, at, at + took} | acc])
  end

  defp scan([?., digit | _rest] = chars, whole, at, acc) when digit in ?0..?9 do
    {number, rest, took} = number([?0 | chars])

    scan(rest, whole, at + took - 1, [{{:number, number}, at, at + took - 1} | acc])
  end

  defp scan([?-, digit | _rest] = chars, whole, at, acc) when digit in ?0..?9 do
    [?- | positive] = chars
    {number, rest, took} = number(positive)

    scan(rest, whole, at + took + 1, [{{:number, -number}, at, at + took + 1} | acc])
  end

  defp scan([?-, ?., digit | _rest] = chars, whole, at, acc) when digit in ?0..?9 do
    [?- | positive] = chars
    {number, rest, took} = number([?0 | positive])

    scan(rest, whole, at + took, [{{:number, -number}, at, at + took} | acc])
  end

  defp scan([char | _rest] = chars, whole, at, acc)
       when char in ?a..?z or char in ?A..?Z or char == ?_ do
    {word, rest} = word(chars, [])
    took = String.length(word)

    scan(rest, whole, at + took, [{{:word, word}, at, at + took} | acc])
  end

  defp scan([char | _rest], whole, _at, _acc) do
    raise ArgumentError,
          "mini-notation: #{inspect(<<char::utf8>>)} means nothing here, in #{inspect(whole)}"
  end

  defp mark(?[), do: :open
  defp mark(?]), do: :close
  defp mark(?<), do: :open_angle
  defp mark(?>), do: :close_angle
  defp mark(?(), do: :open_paren
  defp mark(?)), do: :close_paren
  defp mark(?,), do: :comma
  defp mark(?*), do: :star
  defp mark(?/), do: :slash
  defp mark(?!), do: :bang
  defp mark(?@), do: :at
  defp mark(??), do: :question
  defp mark(?:), do: :colon
  defp mark(?~), do: :rest

  defp number(chars) do
    {digits, rest} = Enum.split_while(chars, &(&1 in ?0..?9 or &1 == ?.))
    text = List.to_string(digits)
    took = length(digits)

    if String.contains?(text, ".") do
      {String.to_float(text), rest, took}
    else
      {String.to_integer(text), rest, took}
    end
  end

  defp word(chars, acc) do
    case chars do
      [char | rest]
      when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in ~c"_-'#^+" ->
        word(rest, [char | acc])

      _done ->
        {acc |> Enum.reverse() |> List.to_string(), chars}
    end
  end

  defp sequences(tokens, source) do
    {steps, rest} = steps(tokens, source, [])

    case rest do
      [{:comma, _f, _t} | more] ->
        {others, rest} = sequences(more, source)
        {[steps | others], rest}

      _done ->
        {[steps], rest}
    end
  end

  defp steps([], _source, acc), do: {Enum.reverse(acc), []}

  defp steps([{token, _from, _to} | _rest] = tokens, _source, acc)
       when token in [:comma, :close, :close_angle] do
    {Enum.reverse(acc), tokens}
  end

  defp steps(tokens, source, acc) do
    {steps, rest} = step(tokens, source)

    steps(rest, source, Enum.reverse(steps) ++ acc)
  end

  defp step(tokens, source) do
    {pattern, rest} = term(tokens, source)

    modifiers(pattern, rest, source, 1, 1)
  end

  defp term([{:rest, _f, _t} | rest], _source), do: {P.silence(), rest}

  defp term(
         [{{:word, word}, from, _t}, {:colon, _cf, _ct}, {{:number, index}, _nf, to} | rest],
         _source
       ) do
    {leaf("#{word}:#{index}", from, to), rest}
  end

  defp term([{{:word, word}, from, _to}, {:colon, _cf, _ct} | rest], source) do
    {indexes, rest} = term(rest, source)

    indexed =
      P.with_value(indexes, fn {index, {_f, index_to}} ->
        {"#{word}:#{index}", {from, index_to}}
      end)

    {indexed, rest}
  end

  defp term([{{:word, word}, from, to} | rest], _source), do: {leaf(word, from, to), rest}

  defp term([{{:number, number}, from, to} | rest], _source) do
    {leaf(number, from, to), rest}
  end

  defp term([{:open, _f, _t} | rest], source) do
    {sequences, rest} = sequences(rest, source)

    {layers(sequences, :fast), expect(rest, :close, "[", source)}
  end

  defp term([{:open_angle, _f, _t} | rest], source) do
    {sequences, rest} = sequences(rest, source)

    {layers(sequences, :slow), expect(rest, :close_angle, "<", source)}
  end

  defp term([{token, _f, _t} | _rest], source),
    do: raise(ArgumentError, unexpected(token, source))

  defp term([], source) do
    raise ArgumentError, "mini-notation: ran out of input in #{inspect(source)}"
  end

  defp leaf(value, from, to), do: P.pure({value, {from, to}})

  defp modifiers(pattern, tokens, source, weight, repeats) do
    case modifier(pattern, tokens, source) do
      {:timed, pattern, rest} -> modifiers(pattern, rest, source, weight, repeats)
      {:weight, amount, rest} -> modifiers(pattern, rest, source, amount, repeats)
      {:repeats, count, rest} -> modifiers(pattern, rest, source, weight, count)
      {:again, rest} -> modifiers(pattern, rest, source, weight, repeats + 1)
      :done -> {List.duplicate({weight, pattern}, repeats), tokens}
    end
  end

  defp modifier(pattern, [{:star, _f, _t}, {{:number, factor}, _nf, _nt} | rest], _source),
    do: {:timed, P.fast(pattern, factor), rest}

  defp modifier(pattern, [{:slash, _f, _t}, {{:number, factor}, _nf, _nt} | rest], _source),
    do: {:timed, P.slow(pattern, factor), rest}

  defp modifier(pattern, [{speed, _f, _t}, {opener, _of, _ot} | _] = tokens, source)
       when speed in [:star, :slash] and opener in [:open, :open_angle] do
    {factors, rest} = term(tl(tokens), source)

    timed =
      if speed == :star,
        do: P.fast(pattern, plain(factors)),
        else: P.slow(pattern, plain(factors))

    {:timed, timed, rest}
  end

  defp modifier(_pattern, [{:at, _f, _t}, {{:number, amount}, _nf, _nt} | rest], _source),
    do: {:weight, amount, rest}

  defp modifier(_pattern, [{:bang, _f, _t}, {{:number, count}, _nf, _nt} | rest], _source),
    do: {:repeats, trunc(count), rest}

  defp modifier(_pattern, [{:bang, _f, _t} | rest], _source), do: {:again, rest}

  defp modifier(pattern, [{:question, _f, _t}, {{:number, amount}, _nf, _nt} | rest], _source),
    do: {:timed, P.degrade(pattern, amount), rest}

  defp modifier(pattern, [{:question, _f, _t} | rest], _source),
    do: {:timed, P.degrade(pattern, 0.5), rest}

  defp modifier(pattern, [{:open_paren, _f, _t} | rest], source) do
    {arguments, rest} = paren(rest, source, [])

    {:timed, euclid(pattern, arguments, source), rest}
  end

  defp modifier(_pattern, _tokens, _source), do: :done

  defp paren(tokens, source, acc) do
    {argument, rest} = term(tokens, source)

    case rest do
      [{:comma, _cf, _ct} | rest] ->
        paren(rest, source, [argument | acc])

      [{:close_paren, _cf, _ct} | rest] ->
        {Enum.reverse([argument | acc]), rest}

      other ->
        raise ArgumentError,
              "mini-notation: (hits,steps) takes numbers, got #{describe(other)} in " <>
                inspect(source)
    end
  end

  defp euclid(pattern, [hits, steps], _source),
    do: P.euclid_with(pattern, plain(hits), plain(steps), P.pure(0))

  defp euclid(pattern, [hits, steps, rotation], _source) do
    P.euclid_with(pattern, plain(hits), plain(steps), plain(rotation))
  end

  defp euclid(_pattern, [_only], source) do
    raise ArgumentError,
          "mini-notation: euclid takes (hits,steps) or (hits,steps,rotation), got one number " <>
            "in #{inspect(source)}"
  end

  defp euclid(_pattern, arguments, source) do
    raise ArgumentError,
          "mini-notation: euclid takes (hits,steps) or (hits,steps,rotation), got " <>
            "#{length(arguments)} numbers in #{inspect(source)}"
  end

  defp plain(pattern), do: P.with_value(pattern, fn {value, _span} -> value end)

  defp layers(sequences, mode) do
    sequences |> Enum.map(&layer(&1, mode)) |> P.stack()
  end

  defp layer([], _mode), do: P.silence()

  defp layer(steps, :fast) do
    steps
    |> P.timecat()
    |> P.with_steps(Enum.reduce(steps, 0, fn {weight, _p}, at -> at + weight end))
  end

  defp layer(steps, :slow) do
    steps |> Enum.map(&elem(&1, 1)) |> P.slowcat() |> P.with_steps(length(steps))
  end

  defp expect([{token, _f, _t} | rest], token, _opening, _source), do: rest

  defp expect(_tokens, _token, opening, source) do
    raise ArgumentError, "mini-notation: unclosed #{inspect(opening)} in #{inspect(source)}"
  end

  defp unexpected(token, source) do
    "mini-notation: unexpected #{describe([token])} in #{inspect(source)}"
  end

  defp describe([]), do: "end of input"
  defp describe([{:word, word} | _rest]), do: inspect(word)
  defp describe([{:number, number} | _rest]), do: to_string(number)
  defp describe([:close | _rest]), do: ~s("]")
  defp describe([:close_angle | _rest]), do: ~s(">")
  defp describe([:close_paren | _rest]), do: ~S[")"]
  defp describe([:open_paren | _rest]), do: ~S["("]
  defp describe([token | _rest]), do: inspect(token)
end

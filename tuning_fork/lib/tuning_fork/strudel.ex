defmodule TuningFork.Strudel do
  @moduledoc """
  Reads a Strudel piece — the JavaScript as written at strudel.cc — into the pattern chains
  this library plays.

      {:ok, chains, meta} = TuningFork.Strudel.chains(js)
      {:ok, pattern} = TuningFork.Strudel.pattern(js)
  """

  alias TuningFork.Pattern
  alias TuningFork.Pattern.Control
  alias TuningFork.Sample.Set
  alias TuningFork.Session

  @type chain :: {non_neg_integer(), non_neg_integer(), String.t()}
  @type meta :: %{cps: number() | nil, samples: [String.t()]}

  @constructors ~w(s sound n note chord voicing mini stack cat seq sequence fastcat slowcat arrange timecat stepcat polymeter silence run irand choose chooseCycles wchoose wchooseCycles pure)
  @lists ~w(stack cat seq sequence fastcat slowcat stepcat polymeter layer)
  @signals ~w(sine cosine saw isaw square tri rand perlin brand)
  @pattern_last ~w(every when_cycle)
  @statements ~w(samples setcps setcpm hush)

  @cdn "https://strudel.b-cdn.net"
  @dirt_names ~w(casio crow insect wind jazz metal east space numbers num)
  @default_sets [
    {"#{@cdn}/uzu-drumkit.json", []},
    {"#{@cdn}/tidal-drum-machines.json", [alias: "#{@cdn}/tidal-drum-machines-alias.json"]},
    {"#{@cdn}/piano.json", []},
    {"#{@cdn}/vcsl.json", []},
    {"#{@cdn}/mridangam.json", []},
    {"https://raw.githubusercontent.com/felixroos/dough-samples/main/Dirt-Samples.json",
     [only: @dirt_names]}
  ]

  @aliases %{
    "sound" => "s",
    "number" => "n",
    "sz" => "size",
    "legato" => "clip",
    "vel" => "velocity",
    "hcutoff" => "hpf",
    "hresonance" => "hpq",
    "ctf" => "lpf",
    "lp" => "lpf",
    "hp" => "hpf",
    "seq" => "fastcat",
    "sequence" => "fastcat",
    "cat" => "slowcat",
    "chooseCycles" => "choose_cycles",
    "wchooseCycles" => "wchoose_cycles",
    "timeCat" => "timecat",
    "euclidRot" => "euclid_rot",
    "euclidLegato" => "euclid_legato",
    "hurry" => "fast"
  }

  @doc """
  Whether `text` reads as Strudel rather than as this library's own rows: method chains after
  a call or a string, or `$:` lines, and no `|>` anywhere.
  """
  @spec strudel?(String.t()) :: boolean()
  def strudel?(text) when is_binary(text) do
    live =
      text
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "//"))
      |> Enum.join("\n")

    not String.contains?(live, "|>") and
      (Regex.match?(~r/^\s*_?\$\w*\s*:/m, live) or
         Regex.match?(~r/[)"'\]]\s*\.\s*[a-zA-Z_$]/, live) or
         Regex.match?(~r/\b(samples|setcps|setcpm)\s*\(/, live))
  end

  @doc """
  The chains a piece plays, as `{first_line, last_line, elixir_source}` with lines counted
  from zero, and what it asked for besides.

  Rows come from `$:` statements, or from the last expression when there are none; a
  `stack` at the top of a row is one chain per voice. `let` variables are written into every
  chain that uses them. `samples(...)` is loaded on the way through and `setcps` reported in
  the meta. `{:error, line, message}` for JavaScript this does not read.
  """
  @spec chains(String.t()) :: {:ok, [chain()], meta()} | {:error, non_neg_integer(), String.t()}
  def chains(text) when is_binary(text) do
    defaults()

    with {:ok, tokens} <- tokenize(text),
         {:ok, statements} <- parse(tokens) do
      translate(statements)
    end
  end

  @doc """
  Register the sample sets strudel.cc loads before any piece — its drum kit, the drum
  machines and their short names, the piano, the VCSL and mridangam sets, and the part of
  Dirt-Samples it keeps — in the background, once. Their files are fetched as they are
  played. `chains/1` calls this, and so does `TuningFork.Kit` when asked for a bank it does
  not have. `wait: true` returns once the sets are registered. Setting the application
  environment `:tuning_fork, :strudel_defaults` to `false` turns it off.
  """
  @spec defaults(keyword()) :: :ok
  def defaults(opts \\ []) do
    cond do
      :persistent_term.get({__MODULE__, :defaults}, false) -> :ok
      Application.get_env(:tuning_fork, :strudel_defaults, true) == false -> :ok
      Keyword.get(opts, :wait, false) -> Set.load_all(@default_sets, &loaded/0)
      true -> Set.background(@default_sets, &loaded/0)
    end
  end

  defp loaded, do: :persistent_term.put({__MODULE__, :defaults}, true)

  @doc "The piece as one pattern, every chain stacked."
  @spec pattern(String.t()) :: {:ok, Pattern.t()} | {:error, String.t()}
  def pattern(text) do
    case chains(text) do
      {:ok, chains, _meta} ->
        {:ok,
         chains |> Enum.map(fn {_f, _l, source} -> %{source: source} end) |> Session.combined()}

      {:error, line, message} ->
        {:error, "line #{line + 1}: #{message}"}
    end
  end

  @doc "The piece as rows of this library's source, one chain a row, for pasting into a buffer."
  @spec to_rows(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def to_rows(text) do
    case chains(text) do
      {:ok, chains, _meta} -> {:ok, Enum.map(chains, fn {_f, _l, source} -> source end)}
      {:error, line, message} -> {:error, "line #{line + 1}: #{message}"}
    end
  end

  @doc "Every word this reads: the pattern and control functions, in Strudel's spelling and this library's."
  @spec words() :: [String.t()]
  def words do
    ((known() |> MapSet.to_list()) ++ Map.keys(@aliases) ++ @signals)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp tokenize(text), do: tokenize(String.to_charlist(text), 0, [], nil)

  defp tokenize([], _line, acc, _prev), do: {:ok, Enum.reverse(acc)}

  defp tokenize([?\n | rest], line, acc, _prev),
    do: tokenize(rest, line + 1, [{:newline, line} | acc], :newline)

  defp tokenize([c | rest], line, acc, prev) when c in ~c" \t\r",
    do: tokenize(rest, line, acc, prev)

  defp tokenize([?/, ?/ | rest], line, acc, prev) do
    {_comment, rest} = Enum.split_while(rest, &(&1 != ?\n))
    tokenize(rest, line, acc, prev)
  end

  defp tokenize([?/, ?* | rest], line, acc, prev) do
    case :string.find(rest, ~c"*/") do
      :nomatch ->
        {:error, line, "unterminated /* comment"}

      found ->
        skipped = length(rest) - length(found)
        {inside, _} = Enum.split(rest, skipped)
        tokenize(Enum.drop(found, 2), line + Enum.count(inside, &(&1 == ?\n)), acc, prev)
    end
  end

  defp tokenize([?=, ?> | rest], line, acc, _prev),
    do: tokenize(rest, line, [{:arrow, line} | acc], :arrow)

  defp tokenize([quote | rest], line, acc, _prev) when quote in ~c"'\"`" do
    case string_literal(rest, quote, []) do
      {:ok, value, rest} -> tokenize(rest, line, [{{:string, value}, line} | acc], :value)
      :error -> {:error, line, "unterminated string"}
    end
  end

  defp tokenize([?., d | _] = chars, line, acc, prev)
       when d in ?0..?9 and prev not in [:value, :ident, :close] do
    {number, rest} = number_literal(chars)
    tokenize(rest, line, [{{:number, number}, line} | acc], :value)
  end

  defp tokenize([d | _] = chars, line, acc, _prev) when d in ?0..?9 do
    {number, rest} = number_literal(chars)
    tokenize(rest, line, [{{:number, number}, line} | acc], :value)
  end

  defp tokenize([c | _] = chars, line, acc, _prev)
       when c in ?a..?z or c in ?A..?Z or c in ~c"_$" do
    {word, rest} =
      Enum.split_while(chars, &(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 in ~c"_$"))

    tokenize(rest, line, [{{:ident, List.to_string(word)}, line} | acc], :ident)
  end

  defp tokenize([c | rest], line, acc, _prev) when c in ~c"()[]{},.:;=+-*/%!?<>&|" do
    kind = if c in ~c")]}", do: :close, else: :punct
    tokenize(rest, line, [{{:punct, <<c>>}, line} | acc], kind)
  end

  defp tokenize([c | _rest], line, _acc, _prev),
    do: {:error, line, "unexpected character #{inspect(<<c::utf8>>)}"}

  defp string_literal([], _quote, _acc), do: :error

  defp string_literal([q | rest], q, acc),
    do: {:ok, acc |> Enum.reverse() |> List.to_string(), rest}

  defp string_literal([?\\, c | rest], q, acc), do: string_literal(rest, q, [c | acc])
  defp string_literal([c | rest], q, acc), do: string_literal(rest, q, [c | acc])

  defp number_literal(chars) do
    {digits, rest} = Enum.split_while(chars, &(&1 in ?0..?9 or &1 in ~c".eE"))
    text = List.to_string(digits)
    text = if String.starts_with?(text, "."), do: "0" <> text, else: text
    text = if String.ends_with?(text, "."), do: text <> "0", else: text

    number =
      if String.contains?(text, [".", "e", "E"]) do
        String.to_float(text)
      else
        String.to_integer(text)
      end

    {number, rest}
  end

  defp parse(tokens) do
    tokens
    |> Enum.reject(fn
      {{:punct, ";"}, _line} -> true
      _other -> false
    end)
    |> statements([])
  end

  defp statements([], acc), do: {:ok, Enum.reverse(acc)}
  defp statements([{:newline, _line} | rest], acc), do: statements(rest, acc)

  defp statements(
         [{{:ident, kind}, _line}, {{:ident, name}, line}, {{:punct, "="}, _} | rest],
         acc
       )
       when kind in ~w(let const var) do
    with {:ok, value, rest} <- expression(rest) do
      statements(rest, [{:let, line, name, value} | acc])
    end
  end

  defp statements([{{:ident, "await"}, _line} | rest], acc), do: statements(rest, acc)

  defp statements([{{:ident, label}, line}, {{:punct, ":"}, _} | tokens], acc)
       when label in ["$", "_$"] or binary_part(label, 0, 1) == "$" or
              (byte_size(label) > 1 and binary_part(label, 0, 2) == "_$") do
    with {:ok, value, rest} <- expression(tokens) do
      silent = String.starts_with?(label, "_")
      statements(rest, [{:row, {line, ended(tokens, rest)}, value, silent} | acc])
    end
  end

  defp statements([{{:ident, name}, line}, {{:punct, "="}, _} | rest], acc) do
    with {:ok, value, rest} <- expression(rest) do
      statements(rest, [{:let, line, name, value} | acc])
    end
  end

  defp statements([{_token, line} | _] = tokens, acc) do
    with {:ok, value, rest} <- expression(tokens) do
      statements(rest, [{:expression, {line, ended(tokens, rest)}, value} | acc])
    end
  end

  defp ended(tokens, rest) do
    {_token, line} = tokens |> Enum.take(length(tokens) - length(rest)) |> List.last()

    line
  end

  defp expression(tokens), do: additive(tokens)

  defp additive(tokens) do
    with {:ok, left, rest} <- multiplicative(tokens) do
      additive_rest(left, rest)
    end
  end

  defp additive_rest(left, [{{:punct, op}, _line} | rest]) when op in ["+", "-"] do
    with {:ok, right, rest} <- multiplicative(rest) do
      additive_rest({:binop, op, left, right}, rest)
    end
  end

  defp additive_rest(left, rest), do: {:ok, left, rest}

  defp multiplicative(tokens) do
    with {:ok, left, rest} <- unary(tokens) do
      multiplicative_rest(left, rest)
    end
  end

  defp multiplicative_rest(left, [{{:punct, op}, _line} | rest]) when op in ["*", "/", "%"] do
    with {:ok, right, rest} <- unary(rest) do
      multiplicative_rest({:binop, op, left, right}, rest)
    end
  end

  defp multiplicative_rest(left, rest), do: {:ok, left, rest}

  defp unary([{{:punct, "-"}, _line} | rest]) do
    with {:ok, value, rest} <- unary(rest), do: {:ok, {:neg, value}, rest}
  end

  defp unary(tokens), do: postfix(tokens)

  defp postfix(tokens) do
    with {:ok, value, rest} <- primary(tokens) do
      postfix_rest(value, rest)
    end
  end

  defp postfix_rest(value, [{:newline, _}, {{:punct, "."}, _} | _] = tokens),
    do: postfix_rest(value, tl(tokens))

  defp postfix_rest(value, [
         {{:punct, "."}, _line},
         {{:ident, name}, _},
         {{:punct, "("}, _} | rest
       ]) do
    with {:ok, args, rest} <- arguments(rest, []) do
      postfix_rest({:mcall, value, name, args}, rest)
    end
  end

  defp postfix_rest(value, [{{:punct, "."}, _line}, {{:ident, name}, _} | rest]) do
    postfix_rest({:member, value, name}, rest)
  end

  defp postfix_rest(value, [{{:punct, "("}, _line} | rest]) do
    with {:ok, args, rest} <- arguments(rest, []) do
      postfix_rest({:call, value, args}, rest)
    end
  end

  defp postfix_rest(value, rest), do: {:ok, value, rest}

  defp arguments([{{:punct, ")"}, _line} | rest], acc), do: {:ok, Enum.reverse(acc), rest}
  defp arguments([{:newline, _} | rest], acc), do: arguments(rest, acc)
  defp arguments([{{:punct, ","}, _} | rest], acc), do: arguments(rest, acc)

  defp arguments(tokens, acc) do
    with {:ok, value, rest} <- expression(strip_newlines(tokens)) do
      arguments(strip_newlines(rest), [value | acc])
    end
  end

  defp strip_newlines([{:newline, _} | rest]), do: strip_newlines(rest)
  defp strip_newlines(tokens), do: tokens

  defp primary([{{:number, number}, _line} | rest]), do: {:ok, {:num, number}, rest}
  defp primary([{{:string, string}, _line} | rest]), do: {:ok, {:str, string}, rest}

  defp primary([
         {{:punct, "("}, _line},
         {{:ident, name}, _},
         {{:punct, ")"}, _},
         {:arrow, _} | rest
       ]) do
    with {:ok, body, rest} <- expression(strip_newlines(rest)),
         do: {:ok, {:arrow, [name], body}, rest}
  end

  defp primary([
         {{:punct, "("}, _line},
         {{:ident, a}, _},
         {{:punct, ","}, _},
         {{:ident, b}, _},
         {{:punct, ")"}, _},
         {:arrow, _} | rest
       ]) do
    with {:ok, body, rest} <- expression(strip_newlines(rest)),
         do: {:ok, {:arrow, [a, b], body}, rest}
  end

  defp primary([{{:punct, "("}, _line}, {{:punct, ")"}, _}, {:arrow, _} | rest]) do
    with {:ok, body, rest} <- expression(strip_newlines(rest)),
         do: {:ok, {:arrow, [], body}, rest}
  end

  defp primary([{{:ident, name}, _line}, {:arrow, _} | rest]) do
    with {:ok, body, rest} <- expression(strip_newlines(rest)),
         do: {:ok, {:arrow, [name], body}, rest}
  end

  defp primary([{{:punct, "("}, _line} | rest]) do
    with {:ok, value, rest} <- expression(strip_newlines(rest)) do
      case strip_newlines(rest) do
        [{{:punct, ")"}, _} | rest] -> {:ok, value, rest}
        [{_token, line} | _] -> {:error, line, "expected )"}
        [] -> {:error, 0, "expected )"}
      end
    end
  end

  defp primary([{{:punct, "["}, _line} | rest]), do: array(strip_newlines(rest), [])

  defp primary([{{:ident, name}, _line} | rest]), do: {:ok, {:id, name}, rest}

  defp primary([{{:punct, "{"}, line} | _rest]),
    do: {:error, line, "object literals are not read"}

  defp primary([{token, line} | _rest]), do: {:error, line, "unexpected #{describe(token)}"}
  defp primary([]), do: {:error, 0, "unexpected end of the piece"}

  defp array([{{:punct, "]"}, _line} | rest], acc), do: {:ok, {:array, Enum.reverse(acc)}, rest}
  defp array([{{:punct, ","}, _} | rest], acc), do: array(strip_newlines(rest), acc)

  defp array(tokens, acc) do
    with {:ok, value, rest} <- expression(tokens), do: array(strip_newlines(rest), [value | acc])
  end

  defp describe(:newline), do: "line break"
  defp describe(:arrow), do: "=>"
  defp describe({:punct, p}), do: inspect(p)
  defp describe({:ident, name}), do: name
  defp describe({:string, s}), do: inspect(s)
  defp describe({:number, n}), do: to_string(n)

  defp literal(string), do: inspect(string, printable_limit: :infinity)

  defp translate(statements) do
    {lets, rows, meta} = collect(statements, %{}, [], %{cps: nil, samples: []})

    rows = if rows == [], do: last_expression(statements), else: Enum.reverse(rows)

    chains =
      Enum.flat_map(rows, fn {{first, last}, ast, silent} ->
        if silent,
          do: [],
          else: ast |> substitute(lets) |> split() |> Enum.map(&{first, last, sounded(emit(&1))})
      end)

    case Enum.find(chains, fn {_l, _l2, source} -> match?({:error, _}, source) end) do
      nil -> {:ok, Enum.map(chains, fn {l, l2, source} -> {l, l2, source} end), meta}
      {line, _l2, {:error, message}} -> {:error, line, message}
    end
  catch
    {:strudel, line, message} -> {:error, line, message}
  end

  defp collect([], lets, rows, meta), do: {lets, rows, meta}

  defp collect([{:let, _line, name, value} | rest], lets, rows, meta) do
    collect(rest, Map.put(lets, name, substitute(value, lets)), rows, meta)
  end

  defp collect([{:row, line, value, silent} | rest], lets, rows, meta) do
    collect(rest, lets, [{line, value, silent} | rows], meta)
  end

  defp collect(
         [{:expression, {line, _last}, {:call, {:id, name}, args}} | rest],
         lets,
         rows,
         meta
       )
       when name in @statements do
    collect(rest, lets, rows, statement(name, args, line, meta))
  end

  defp collect([{:expression, _line, _value} | rest], lets, rows, meta),
    do: collect(rest, lets, rows, meta)

  defp statement("setcps", [{:num, cps}], _line, meta), do: %{meta | cps: cps}
  defp statement("setcpm", [{:num, cpm}], _line, meta), do: %{meta | cps: cpm / 60}
  defp statement("hush", _args, _line, meta), do: meta

  defp statement("samples", [{:str, source} | _rest], line, meta) do
    case Set.load(source) do
      {:ok, _names} ->
        %{meta | samples: meta.samples ++ [source]}

      {:error, reason} ->
        throw(
          {:strudel, line, "samples(#{inspect(source)}) could not be loaded: #{inspect(reason)}"}
        )
    end
  end

  defp statement(name, _args, line, _meta),
    do: throw({:strudel, line, "#{name}(...) takes a number or a string here"})

  defp last_expression(statements) do
    statements
    |> Enum.reverse()
    |> Enum.find_value([], fn
      {:expression, _lines, {:call, {:id, name}, _args}} when name in @statements -> nil
      {:expression, lines, value} -> [{lines, value, false}]
      _other -> nil
    end)
  end

  defp substitute({:id, name}, lets), do: Map.get(lets, name, {:id, name})

  defp substitute({:mcall, obj, name, args}, lets),
    do: {:mcall, substitute(obj, lets), name, Enum.map(args, &substitute(&1, lets))}

  defp substitute({:call, callee, args}, lets),
    do: {:call, substitute(callee, lets), Enum.map(args, &substitute(&1, lets))}

  defp substitute({:member, obj, name}, lets), do: {:member, substitute(obj, lets), name}

  defp substitute({:arrow, params, body}, lets),
    do: {:arrow, params, substitute(body, Map.drop(lets, params))}

  defp substitute({:array, items}, lets), do: {:array, Enum.map(items, &substitute(&1, lets))}

  defp substitute({:binop, op, a, b}, lets),
    do: {:binop, op, substitute(a, lets), substitute(b, lets)}

  defp substitute({:neg, a}, lets), do: {:neg, substitute(a, lets)}
  defp substitute(other, _lets), do: other

  defp split({:call, {:id, "stack"}, voices}), do: Enum.flat_map(voices, &split/1)

  defp split({:mcall, obj, name, args}) do
    case split(obj) do
      [single] -> [{:mcall, single, name, args}]
      several -> Enum.map(several, &{:mcall, &1, name, args})
    end
  end

  defp split(other), do: [other]

  defp sounded({:error, _reason} = error), do: error

  defp sounded(source) do
    if Regex.match?(~r/\b(s|sound)\(/, source), do: source, else: source <> " |> s(\"triangle\")"
  end

  defp emit(ast) do
    source = expression_source(ast, :top)

    if String.starts_with?(source, "fn "),
      do: {:error, "a chain must be a pattern, not a function"},
      else: source
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp expression_source({:num, n}, _where), do: number(n)
  defp expression_source({:str, s}, :receiver), do: "mini(#{literal(s)})"
  defp expression_source({:str, s}, _where), do: literal(s)
  defp expression_source({:neg, a}, where), do: "-" <> expression_source(a, where)

  defp expression_source({:array, items}, _where),
    do: "[" <> Enum.map_join(items, ", ", &expression_source(&1, :argument)) <> "]"

  defp expression_source({:binop, op, a, b}, _where) do
    "(" <>
      expression_source(a, :argument) <>
      " " <> op <> " " <> expression_source(b, :argument) <> ")"
  end

  defp expression_source({:id, name}, _where) when name in @signals, do: "#{name}()"
  defp expression_source({:id, "silence"}, _where), do: "silence()"
  defp expression_source({:id, name}, :argument), do: "&#{function_name(name)}/1"
  defp expression_source({:id, name}, _where), do: name

  defp expression_source({:arrow, params, body}, _where) do
    "fn #{Enum.join(params, ", ")} -> #{expression_source(body, :top)} end"
  end

  defp expression_source({:member, obj, name}, where),
    do: expression_source({:mcall, obj, name, []}, where)

  defp expression_source({:call, {:id, name}, args}, where) do
    cond do
      name in @constructors -> constructor(name, args)
      where == :argument -> "&(&1 |> #{call_source(name, args)})"
      true -> constructor(name, args)
    end
  end

  defp expression_source({:call, callee, args}, _where) do
    expression_source(callee, :receiver) <>
      ".(" <> Enum.map_join(args, ", ", &expression_source(&1, :argument)) <> ")"
  end

  defp expression_source({:mcall, obj, name, args}, _where) do
    expression_source(obj, :receiver) <> " |> " <> call_source(name, args)
  end

  defp constructor(name, args) do
    function = function_name(name)

    if name in @lists do
      "#{function}([" <> Enum.map_join(args, ", ", &expression_source(&1, :argument)) <> "])"
    else
      "#{function}(" <> Enum.map_join(args, ", ", &expression_source(&1, :argument)) <> ")"
    end
  end

  defp call_source(name, args) do
    function = function_name(name)
    arguments = Enum.map(args, &expression_source(&1, :argument))

    cond do
      function in @pattern_last -> "then(&#{function}(#{Enum.join(arguments ++ ["&1"], ", ")}))"
      arguments == [] -> "#{function}()"
      true -> "#{function}(#{Enum.join(arguments, ", ")})"
    end
  end

  defp function_name(name) do
    stripped = String.trim_leading(name, "_")
    mapped = Map.get(@aliases, stripped, stripped)
    snake = Macro.underscore(mapped)

    if MapSet.member?(known(), snake) do
      snake
    else
      raise ArgumentError, "#{name} is not a word this reads"
    end
  end

  defp known do
    functions =
      Keyword.keys(TuningFork.Pattern.__info__(:functions)) ++
        Keyword.keys(Control.__info__(:functions))

    MapSet.new(Enum.map(functions, &Atom.to_string/1) ++ ["mini"])
  end

  defp number(n) when is_float(n), do: Float.to_string(n)
  defp number(n), do: Integer.to_string(n)
end

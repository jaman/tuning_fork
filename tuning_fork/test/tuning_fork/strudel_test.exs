defmodule TuningFork.StrudelTest do
  use ExUnit.Case, async: true

  alias TuningFork.{Mixer, Pattern, Strudel}
  alias TuningFork.Pattern.Player

  defp rows(js) do
    {:ok, rows} = Strudel.to_rows(js)
    rows
  end

  defp row(js), do: js |> rows() |> hd()

  describe "spelling" do
    test "a method chain becomes a pipeline" do
      assert row(~S{s("bd sn").gain(.5).room(0.2)}) == ~S{s("bd sn") |> gain(0.5) |> room(0.2)}
    end

    test "sound is s, and other spellings are ours" do
      assert row(~S{sound("bd").sz(4).legato(.5)}) == ~S{s("bd") |> size(4) |> clip(0.5)}

      assert row(~S{s("bd").sometimesBy(.3, x => x.fast(2))}) ==
               ~S{s("bd") |> sometimes_by(0.3, fn x -> x |> fast(2) end)}
    end

    test "a bare transformer in an argument is a function of the pattern" do
      assert row(~S{s("bd").rarely(ply("2")).chunk(4, fast(2)).every(4, rev)}) ==
               ~S{s("bd") |> rarely(&(&1 |> ply("2"))) |> chunk(4, &(&1 |> fast(2))) |> then(&every(4, &rev/1, &1))}
    end

    test "signals and their ranges" do
      assert row(~S{s("bd").lpf(sine.range(500,1000).slow(8)).gain(perlin.range(.6,.9))}) ==
               ~S{s("bd") |> lpf(sine() |> range(500, 1000) |> slow(8)) |> gain(perlin() |> range(0.6, 0.9))}
    end

    test "a string with a method is mini-notation" do
      assert row(~S{s("bd*4").mask("<0 1>/16".early(.5))}) ==
               ~S{s("bd*4") |> mask(mini("<0 1>/16") |> early(0.5))}
    end

    test "stack, cat and seq take lists" do
      assert row(~S{stack(s("bd"), s("hh")).gain(.5)}) == ~S{s("bd") |> gain(0.5)}

      assert rows(~S{stack(s("bd"), s("hh")).gain(.5)}) == [
               ~S{s("bd") |> gain(0.5)},
               ~S{s("hh") |> gain(0.5)}
             ]

      assert row(~S{cat(s("bd"), s("hh"))}) == ~S{slowcat([s("bd"), s("hh")])}
      assert row(~S{seq("bd", "hh").s()}) == ~S{fastcat(["bd", "hh"]) |> s()}
    end

    test "arithmetic and negative numbers" do
      assert row(~S{s("bd").late(1/8).offset(-1)}) == ~S{s("bd") |> late((1 / 8)) |> offset(-1)}
    end

    test "arrow functions with two parameters and none" do
      assert row(~S{s("bd").superimpose(x => x.fast(2))}) ==
               ~S{s("bd") |> superimpose(fn x -> x |> fast(2) end)}
    end

    test "single and backtick quotes, comments, semicolons and blank lines" do
      js = """
      // a comment
      /* another
         one */
      s('bd').bank(`crate`);

      """

      assert row(js) == ~S{s("bd") |> bank("crate")}
    end

    test "a row with notes and no sound plays Strudel's triangle" do
      assert row(~S{note("c4 e4").room(.2)}) == ~S{note("c4 e4") |> room(0.2) |> s("triangle")}

      assert row(~S{n("0 2").scale("c:major")}) ==
               ~S{n("0 2") |> scale("c:major") |> s("triangle")}

      assert row(~S{note("c4").sound("sawtooth")}) == ~S{note("c4") |> s("sawtooth")}
      assert row(~S{s("bd")}) == ~S{s("bd")}
    end

    test "a chain may continue on the next line with a dot" do
      js = """
      s("bd")
        .gain(.5)
        .room(.3)
      """

      assert row(js) == ~S{s("bd") |> gain(0.5) |> room(0.3)}
    end
  end

  describe "statements" do
    test "$: lines are the rows, in order, and _$: lines are silent" do
      js = """
      $: s("bd*4")
      _$: s("hh*8")
      $: n("0 2").s("piano")
      """

      assert rows(js) == [~S{s("bd*4")}, ~S{n("0 2") |> s("piano")}]
    end

    test "without $: the last expression is the piece" do
      js = """
      s("nope")
      s("bd").gain(.5)
      """

      assert rows(js) == [~S{s("bd") |> gain(0.5)}]
    end

    test "let variables are written into the chains that use them" do
      js = """
      let chords = chord("<Bbm9 Fm9>/4").dict('ireal')
      stack(
        chords.voicing().s("gm_epiano1"),
        n("0 2").set(chords).voicing()
      )
      """

      assert rows(js) == [
               ~S{chord("<Bbm9 Fm9>/4") |> dict("ireal") |> voicing() |> s("gm_epiano1")},
               ~S{n("0 2") |> set(chord("<Bbm9 Fm9>/4") |> dict("ireal")) |> voicing() |> s("triangle")}
             ]
    end

    test "setcps is reported, and nested stacks are flattened with their chains distributed" do
      js = """
      setcps(.75)
      stack(
        stack(s("bd"), s("hh")).bank('crate').mask("<0 1>/16"),
        s("cp")
      ).late("[0 .01]*4").size(4)
      """

      assert {:ok, chains, %{cps: 0.75}} = Strudel.chains(js)

      assert Enum.map(chains, &elem(&1, 2)) == [
               ~S{s("bd") |> bank("crate") |> mask("<0 1>/16") |> late("[0 .01]*4") |> size(4)},
               ~S{s("hh") |> bank("crate") |> mask("<0 1>/16") |> late("[0 .01]*4") |> size(4)},
               ~S{s("cp") |> late("[0 .01]*4") |> size(4)}
             ]

      assert Enum.map(chains, &elem(&1, 0)) == [1, 1, 1]
    end

    test "each $: row remembers its line" do
      js = """
      // title

      $: s("bd")
      $: s("hh")
      """

      assert {:ok, [{2, 2, _}, {3, 3, _}], _meta} = Strudel.chains(js)
    end
  end

  describe "what it refuses, and where" do
    test "a word it does not read is named" do
      assert {:error, "line 1: nonsense is not a word this reads"} =
               Strudel.to_rows(~S{s("bd").nonsense(2)})
    end

    test "broken JavaScript is reported on its line" do
      assert {:error, _line, _message} =
               Strudel.chains(~S{s("bd")} <> "\n" <> ~S{s("hh"} <> "\n.gain(1)")

      assert {:error, 0, "unterminated string"} = Strudel.chains("s(\"bd")
      assert {:error, 0, "object literals are not read"} = Strudel.chains("s({s: \"bd\"})")
    end
  end

  describe "telling Strudel from rows" do
    test "method chains and $: lines are Strudel" do
      assert Strudel.strudel?(~S{s("bd").gain(.5)})
      assert Strudel.strudel?("$: s(\"bd\")")
      assert Strudel.strudel?("setcps(0.5)\ns(\"bd\")")
    end

    test "our own rows are not" do
      refute Strudel.strudel?(~S{s("bd") |> gain(0.5)})
      refute Strudel.strudel?(~S{s("bd*4")})
      refute Strudel.strudel?("hh*8?0.2\n~ ~ cp ~")
      refute Strudel.strudel?("// s(\"bd\").gain(1)")
    end
  end

  describe "played" do
    test "a translated piece renders as a pattern" do
      {:ok, pattern} = Strudel.pattern(~S{stack(s("bd*4"), s("hh*8").gain(.4))})
      pcm = Player.render(pattern, 8_000, cycles: 1, cps: 1)

      assert Mixer.peak(pcm) > 1_000
      assert length(Pattern.first_cycle(pattern)) == 12
    end
  end

  @coastline """
  // "coastline" @by eddyflux
  // @version 1.0
  setcps(.75)
  let chords = chord("<Bbm9 Fm9>/4").dict('ireal')
  stack(
    stack( // DRUMS
      s("bd").struct("<[x*<1 2> [~@3 x]] x>"),
      s("~ [rim, sd:<2 3>]").room("<0 .2>"),
      n("[0 <1 3>]*<2!3 4>").s("hh"),
      s("rd:<1!3 2>*2").mask("<0 0 1 1>/16").gain(.5)
    ).bank('crate')
    .mask("<[0 1] 1 1 1>/16".early(.5))
    , // CHORDS
    chords.offset(-1).voicing().s("gm_epiano1:1")
    .phaser(4).room(.5)
    , // MELODY
    n("<0!3 1*2>").set(chords).mode("root:g2")
    .voicing().s("gm_acoustic_bass"),
    chords.n("[0 <4 3 <2 5>>*2](<3 5>,8)")
    .anchor("D5").voicing()
    .segment(4).clip(rand.range(.4,.8))
    .room(.75).shape(.3).delay(.25)
    .fm(sine.range(3,8).slow(8))
    .lpf(sine.range(500,1000).slow(8)).lpq(5)
    .rarely(ply("2")).chunk(4, fast(2))
    .gain(perlin.range(.6, .9))
    .mask("<0 1 1 0>/16")
  )
  .late("[0 .01]*4").late("[0 .01]*2").size(4)
  """

  describe "coastline, by eddyflux" do
    test "reads as seven chains at 0.75 cps" do
      assert {:ok, chains, %{cps: 0.75}} = Strudel.chains(@coastline)
      assert length(chains) == 7

      assert Enum.at(chains, 0) |> elem(2) ==
               ~S{s("bd") |> struct("<[x*<1 2> [~@3 x]] x>") |> bank("crate") |> mask(mini("<[0 1] 1 1 1>/16") |> early(0.5)) |> late("[0 .01]*4") |> late("[0 .01]*2") |> size(4)}
    end

    test "every chain parses and the piece plays" do
      {:ok, pattern} = Strudel.pattern(@coastline)
      events = Enum.flat_map(0..15, &Pattern.first_cycle(pattern, &1))

      assert length(events) > 40

      assert Enum.any?(events, fn {_f, _t, value} ->
               Map.has_key?(value, :note) and value[:sound] == "gm_epiano1:1"
             end)

      assert Enum.any?(events, fn {_f, _t, value} ->
               value[:sound] == "bd" and value[:bank] == "crate"
             end)

      pcm = Player.render(pattern, 8_000, cycles: 2, cps: 0.75)
      assert Mixer.peak(pcm) > 500
    end
  end
end

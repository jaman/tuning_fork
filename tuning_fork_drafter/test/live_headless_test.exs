defmodule TuningFork.LiveHeadlessTest do
  @moduledoc """
  The live-coding app under the whole of Drafter, with no terminal.

  `TuningFork.LiveCodeAppTest` drives `update/2` directly, which proves what the keys do but
  not that anything reaches the screen. `Drafter.Test.start_headless/3` runs the real renderer,
  the real widget servers and the real compositor against an in-memory terminal, which is what
  catches a picture that is built correctly and then never drawn.

  What it cannot catch: the in-memory terminal reports `:braille`, not a pixel protocol, so
  `TuningFork.Drafter.Roll.image/3` returns `nil` before it encodes anything. The rate at which
  images are *asked for* is exercised here; what one costs to actually put on a kitty terminal
  is not.
  """

  use ExUnit.Case, async: false

  import Drafter.Test

  alias TuningFork.LiveCodeApp, as: App

  setup do
    Code.ensure_loaded!(TuningFork.Drafter.Roll)
    Drafter.Widget.Registry.register(TuningFork.Drafter.Roll)

    ctx =
      start_headless(App, %{
        pixels: true,
        cps: 0.5,
        sink: TuningFork.Sink.Silent,
        patterns: ["s(\"bd!4\") |> scope()"]
      })

    on_exit(fn -> stop(ctx) end)

    %{ctx: ctx}
  end

  defp sampled(ctx, times) do
    for _ <- 1..times do
      Process.sleep(60)
      state = get_state(ctx)

      case Map.get(state.rasters, 0) do
        {_source, _cycle, raster} -> :erlang.phash2(raster)
        _nothing -> nil
      end
    end
  end

  describe "keeping up with the music" do
    test "the clock runs", %{ctx: ctx} do
      before = get_state(ctx).cycle
      Process.sleep(500)

      assert get_state(ctx).cycle > before, "the transport should be advancing"
    end

    test "the scope is redrawn many times a beat, not once", %{ctx: ctx} do
      Process.sleep(300)
      frames = sampled(ctx, 25) |> Enum.reject(&is_nil/1)

      assert length(frames) > 15, "the app should be producing frames throughout"

      assert length(Enum.uniq(frames)) >= 4,
             "a bass drum four times a cycle should give at least four distinct traces, " <>
               "got #{length(Enum.uniq(frames))} in #{length(frames)} samples"
    end

    test "it is still drawing after several cycles, not frozen after the first", %{ctx: ctx} do
      Process.sleep(200)
      early = sampled(ctx, 8) |> Enum.reject(&is_nil/1)
      Process.sleep(1_500)
      later = sampled(ctx, 8) |> Enum.reject(&is_nil/1)

      assert length(Enum.uniq(early)) > 1, "should be moving early on"
      assert length(Enum.uniq(later)) > 1, "should still be moving two cycles later"
    end

    test "pausing stops the drawing and playing starts it again", %{ctx: ctx} do
      send_key(ctx, :p, [:ctrl])
      Process.sleep(200)
      refute get_state(ctx).playing

      still = sampled(ctx, 6)
      assert length(Enum.uniq(still)) == 1, "paused, nothing should be redrawn"

      send_key(ctx, :p, [:ctrl])
      Process.sleep(300)
      assert get_state(ctx).playing
      assert sampled(ctx, 8) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length() > 1
    end
  end

  describe "what the screen actually says" do
    test "the transport line is where spot/3 thinks it is", %{ctx: ctx} do
      Process.sleep(200)
      line = ctx |> screen_lines() |> Enum.at(App.transport_row())

      assert line =~ "cycle", "row #{App.transport_row()} should be the transport line"
    end

    test "the first pattern is drawn where layout/1 puts it", %{ctx: ctx} do
      Process.sleep(200)
      line = ctx |> screen_lines() |> Enum.at(App.rows_above())

      assert line =~ "bd", "row #{App.rows_above()} should be the first pattern"
    end

    defp press(ctx, x, y) do
      send_mouse(ctx, %{type: :mouse_down, x: x, y: y, button: :left})
      Process.sleep(150)
    end

    test "clicking the transport line as the screen lays it out pauses", %{ctx: ctx} do
      Process.sleep(200)
      assert get_state(ctx).playing

      press(ctx, 2, App.transport_row())

      refute get_state(ctx).playing, "a click on the play line should pause"
    end

    test "clicking a row where the screen draws it moves the cursor there", %{ctx: ctx} do
      Process.sleep(200)
      press(ctx, 2, App.transport_row())

      press(ctx, 6, App.rows_above())
      state = get_state(ctx)

      assert state.slot == 0
      assert Enum.at(state.slots, 0).cursor == 1, "x of 6 is the second character of the source"
    end

    test "releasing the button does not toggle a second time", %{ctx: ctx} do
      Process.sleep(200)
      press(ctx, 2, App.transport_row())
      refute get_state(ctx).playing

      send_click(ctx, 2, App.transport_row())
      Process.sleep(150)

      refute get_state(ctx).playing, "the mouse_up should not play it again"
    end
  end
end

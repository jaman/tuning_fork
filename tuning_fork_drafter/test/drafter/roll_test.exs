defmodule TuningFork.Drafter.RollTest do
  @moduledoc """
  The widget that puts a raster on the terminal, and which of the two kitty dialects it speaks.

  Not `async: true`: the branch is chosen from the environment, and these tests change it.
  """

  use ExUnit.Case, async: false

  alias FrenchCurve.Raster
  alias TuningFork.Drafter.Roll

  @rect %{width: 40, height: 4, x: 0, y: 0}

  setup do
    kept = System.get_env("TERM_PROGRAM")
    kept_version = System.get_env("TERM_PROGRAM_VERSION")
    kept_term = System.get_env("TERM")
    kept_window = System.get_env("KITTY_WINDOW_ID")

    on_exit(fn ->
      put("TERM_PROGRAM", kept)
      put("TERM_PROGRAM_VERSION", kept_version)
      put("TERM", kept_term)
      put("KITTY_WINDOW_ID", kept_window)
    end)

    :ok
  end

  defp put(name, nil), do: System.delete_env(name)
  defp put(name, value), do: System.put_env(name, value)

  defp as_kitty do
    System.delete_env("TERM_PROGRAM")
    System.delete_env("TERM_PROGRAM_VERSION")
    System.put_env("TERM", "xterm-kitty")
  end

  defp as_iterm do
    System.delete_env("KITTY_WINDOW_ID")
    System.put_env("TERM", "xterm-256color")
    System.put_env("TERM_PROGRAM", "iTerm.app")
    System.put_env("TERM_PROGRAM_VERSION", "3.5.0")
  end

  defp as_partial_kitty do
    as_iterm()
  end

  defp drawn do
    raster = Raster.new(16, 8, background: {0, 0, 0, 255})
    widget = Roll.mount(%{raster: raster, mode: :kitty})

    {paint, clear, region} = Roll.image(widget, @rect, {:roll, 0})

    {IO.iodata_to_binary(paint), IO.iodata_to_binary(clear), region}
  end

  describe "a terminal that keeps images under an id" do
    test "stores the image and places it, and can place it again without resending" do
      as_kitty()
      {paint, clear, region} = drawn()

      assert paint =~ "a=t,", "stored under an id"
      assert paint =~ "a=p", "and then placed"
      assert clear =~ "a=d", "with a delete to take it away again"
      assert region.place, "and a placement to redraw it with when text is written across it"
    end
  end

  describe "a kitty-speaking terminal that keeps nothing" do
    test "transmits and displays in one command instead" do
      as_partial_kitty()
      {paint, _clear, _region} = drawn()

      assert paint =~ "a=T", "one command that sends and shows together"
      refute paint =~ "a=t,", "storing under an id would leave a picture it never draws"
      refute paint =~ "a=p", "and it does not understand a placement"
    end

    test "it leaves the caret alone, so a picture low on the screen does not scroll it" do
      as_partial_kitty()
      {paint, _clear, _region} = drawn()

      assert paint =~ "C=1"
    end

    test "it does not ask the terminal to answer, since replies arrive as keystrokes" do
      as_partial_kitty()
      {paint, _clear, _region} = drawn()

      assert paint =~ "q=2"
    end

    test "the picture is still named, so it can be taken off the screen again" do
      as_partial_kitty()
      {paint, clear, region} = drawn()

      assert region.place == nil, "nil tells the compositor to send the picture again"

      assert clear =~ "a=d",
             "an overlay is not cells; without a delete it survives the program itself"

      assert String.starts_with?(paint, clear), "and each frame removes the one before it"
    end

    test "the picture still fills the box it was given" do
      as_partial_kitty()
      {paint, _clear, region} = drawn()

      assert paint =~ "c=#{@rect.width},r=#{@rect.height}"
      assert region.cols == @rect.width
      assert region.rows == @rect.height
    end
  end

  describe "iTerm" do
    test "uses its own inline protocol rather than kitty" do
      as_iterm()

      assert FrenchCurve.Capability.detect(System.get_env()) == :iterm2,
             "a kitty overlay cannot be removed on iTerm, so it is not offered one"
    end

    test "draws cells, which the text redraw rubs out and the screen takes away on exit" do
      as_iterm()
      raster = Raster.new(16, 8, background: {0, 0, 0, 255})
      widget = Roll.mount(%{raster: raster, mode: :iterm2})

      {paint, clear, region} = Roll.image(widget, @rect, {:roll, 0})
      paint = IO.iodata_to_binary(paint)

      assert String.starts_with?(paint, "\e]1337"), "an inline image"
      refute paint =~ "a=T", "not a kitty overlay"
      assert paint =~ "width=#{@rect.width};height=#{@rect.height}", "sized in cells"

      assert IO.iodata_to_binary(clear) == "",
             "cells need no delete — rewriting the text underneath is what removes them"

      assert region.place == nil
    end
  end

  describe "either way" do
    test "a frame is produced at all" do
      for setup <- [&as_kitty/0, &as_partial_kitty/0] do
        setup.()
        {paint, _clear, region} = drawn()

        assert byte_size(paint) > 0
        assert %{dx: 0, dy: 0} = region
      end
    end

    test "no raster is no image" do
      as_iterm()

      assert Roll.image(Roll.mount(%{raster: nil}), @rect, {:roll, 0}) == nil
    end
  end
end

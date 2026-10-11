defmodule TuningFork.Mt32Test do
  use ExUnit.Case, async: true

  alias TuningFork.Mt32

  @moduletag :tmp_dir

  test "a directory without a Munt library is reported as such", %{tmp_dir: dir} do
    assert Mt32.open(location: dir) == {:error, {:no_library, dir}}
  end

  test "a file that is not a library is refused by the loader", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "libmt32emu.dylib"), "not a library")
    File.write!(Path.join(dir, "libmt32emu.so"), "not a library")
    File.write!(Path.join(dir, "MT32_CONTROL.ROM"), "")
    File.write!(Path.join(dir, "MT32_PCM.ROM"), "")

    assert {:error, {:not_a_library, _reason}} = Mt32.open(location: dir)
  end

  test "a library without ROMs names the missing ROM", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "libmt32emu.dylib"), "")
    File.write!(Path.join(dir, "libmt32emu.so"), "")

    assert Mt32.open(location: dir) == {:error, {:missing_rom, "MT32_CONTROL.ROM"}}
  end
end

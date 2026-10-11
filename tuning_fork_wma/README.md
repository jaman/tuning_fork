# TuningForkWma

Decodes xWMA audio — the WMA v2 streams in XACT wave banks (`.xwb`) and `.xwma` files —
in pure Elixir. It needs no `ffmpeg` and no native code.

```elixir
def deps do
  [
    {:tuning_fork, "~> 0.1.12"},
    {:tuning_fork_wma, "~> 0.1"}
  ]
end
```

With this package installed, `TuningFork.Xwma.decode/1` decodes xWMA with
`TuningFork.Wma` without any configuration, ahead of the machine's `ffmpeg`. A whole
`.xwma` file decodes as it is:

```elixir
{:ok, pcm, %{rate: 44_100, channels: 2}} =
  "music.xwma"
  |> File.read!()
  |> TuningFork.Xwma.decode()
```

An XACT wave bank (`.xwb`) holds each entry as the packets and the seek table without the
file around them; `TuningFork.Xwma.riff/2` wraps those in a file, which then decodes the
same way:

```elixir
riff = TuningFork.Xwma.riff(packets, %{channels: 2, rate: 44_100, bytes_per_second: 12_000, block_align: 4459, seek: table})
{:ok, pcm, %{rate: 44_100, channels: 2}} = TuningFork.Xwma.decode(riff)
```

`TuningFork.Wma.decode/1` can also be called directly with the bytes of an `.xwma` file. It
returns signed 16-bit little-endian interleaved PCM with the rate and channel count, the
same samples `ffmpeg` gives for the file, to within one step of rounding.

Supported: WMA v2 (format tag `0x0161`), mono and stereo, sample rates up to 50 kHz, as
xWMA codes it. A packet that does not decode is skipped and the rest of the file still
decodes.

## Licence

GNU Lesser General Public License, version 2.1 or (at your option) any later version; see
`LICENSE`.

## Credits

The decoder is a port to Elixir of the WMA decoder of [FFmpeg](https://ffmpeg.org)'s
libavcodec (`wmadec.c`, `wma.c`, `wma.h`, `wmadata.h`, `wma_common.c`, `wma_freqs.c`,
the exponent codes of `aactab.c`, and the inverse MDCT of libavutil's `tx`), copyright the
FFmpeg project and its contributors, licensed under the LGPL 2.1 or later. FFmpeg's WMA
decoder was written by Fabrice Bellard. Its tables are in `TuningFork.Wma.Tables`.

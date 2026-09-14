# TuningForkSamples

Sonic Pi's sample bank for [TuningFork](https://hex.pm/packages/tuning_fork): 206 recordings, public domain,
fetched from Sonic Pi's repository the first time each is played and kept under
`$XDG_CACHE_HOME/tuning_fork/samples`.

```elixir
{:tuning_fork, "~> 0.1"},
{:tuning_fork_samples, "~> 0.1"}
```

With this package started, every name in the bank plays wherever a drum name does:

```elixir
s("bd_haus*4 elec_blip")                                # a Strudel pattern
part(bpm: 120, synth: Kit.voice("perc_bell", 1))        # a loop
sample :perc_bell, rate: 0.5                            # the Sonic Pi vocabulary
TuningFork.Samples.load!(:ambi_choir)                   # the recording itself
```

## Names

The names are Sonic Pi's. `TuningFork.Samples.names/0` lists all 206;
`TuningFork.Samples.families/0` groups them by prefix:

| Family | Some of them |
| --- | --- |
| `bd` | `bd_haus` `bd_808` `bd_fat` `bd_tek` `bd_zum` `bd_boom` |
| `sn` | `sn_dub` `sn_dolf` `sn_zome` `sn_generic` |
| `hat` | `hat_snap` `hat_zap` `hat_tap` `hat_bdu` `hat_metal` |
| `drum` | `drum_heavy_kick` `drum_snare_hard` `drum_cymbal_closed` `drum_cowbell` `drum_roll` |
| `elec` | `elec_blip` `elec_beep` `elec_ping` `elec_twang` `elec_bell` `elec_snare` |
| `perc` | `perc_bell` `perc_snap` `perc_swash` `perc_till` `perc_door` |
| `ambi` | `ambi_choir` `ambi_drone` `ambi_piano` `ambi_lunar_land` `ambi_glass_hum` |
| `bass` | `bass_hit_c` `bass_hard_c` `bass_thick_c` `bass_trance_c` `bass_dnb_f` |
| `loop` | `loop_amen` `loop_amen_full` `loop_breakbeat` `loop_industrial` `loop_garzul` |
| `tabla` | `tabla_ghe1` `tabla_na` `tabla_tas1` `tabla_te1` `tabla_tun1` |
| `glitch` | `glitch_bass_g` `glitch_perc_1` `glitch_robot_1` |
| `vinyl` | `vinyl_backspin` `vinyl_hiss` `vinyl_rewind` `vinyl_scratch` |
| `guit` | `guit_e_fifths` `guit_e_slide` `guit_em9` `guit_harmonics` |
| `misc` | `misc_burp` `misc_crow` `misc_cineboom` |
| `mehackit` | `mehackit_phone_1` `mehackit_robot_1` |
| `arovane` | `arovane_beat_a` … `arovane_beat_e` |
| `tbd` | `tbd_pad_1` `tbd_perc_hat` `tbd_highkey_c4` `tbd_fxbed_loop` |
| `ride` | `ride_tri` `ride_via` |

A pitched recording is played at its own speed unless the voice is told what note it is
(`Sample.load!` takes a `:root`). A number after the name — `bd_haus:2` — picks a file where
a name holds several, and is the same recording where it holds one.

## Loading

A recording is fetched on its first use and decoded from FLAC — `TuningFork.Flac` is pure
Elixir — then kept in `TuningFork.Sample.Bank`. On a live stage a recording still on its way
is silent for that hit and plays from the next; `TuningFork.Samples.prefetch/0` fetches all
206 (34 MB) in the background beforehand, and a pattern or loop prefetches the names it is
about to play. `TuningFork.Samples.source/1` points the package at another directory of
`<name>.flac` files, local or on the web, for a machine without access to GitHub.

## Licence

Every recording is under Creative Commons Zero. `priv/SOURCES.md` is Sonic Pi's own list of
where each came from on freesound.org, and of the sets donated by Uwe Zahn (Arovane) and
The Black Dog.

# Authors and Credits

## NightSlashers_MiSTer core

**Author**: Umberto Parisi ([rmonic79](https://github.com/rmonic79))

The original RTL source files for the Night Slashers specific logic
(under `rtl/nightslashers/`, the ARM CPU wrapper under `rtl/cpu_arm/`, the
DECO156 CPU decrypt / DECO56 / DECO74 tile decrypt, and the project wrapper
`Template.sv`) are copyright Umberto Parisi and distributed under GNU GPL v3
or later.

## Third-party components

This core builds on top of excellent open-source projects. All third-party
sources retain their original copyright and license. The core as a whole
is distributed under **GNU GPL v3 or later** to stay compatible with the
most restrictive upstream (JTFRAME / JTCORES).

| Component | Author | Project | License |
|-----------|--------|---------|---------|
| **Amber** — ARMv2a (ARM2/3) CPU core, used for the encrypted DECO156 main CPU | Conor Santifort | [OpenCores — amber](https://opencores.org/projects/amber) | LGPL |
| **T80** — Zilog Z80 (sound CPU) core | Daniel Wallner (original, OpenCores), with MikeJ fixes and Sorgelig / MiSTer-devel maintenance | [MiSTer-devel](https://github.com/MiSTer-devel) | GPL-3 |
| **JT51** — Yamaha YM2151 (OPM) FM synthesizer | Jose Tejada ([@topapate](https://twitter.com/topapate)) | [jotego/jt51](https://github.com/jotego/jt51) | GPL-3 |
| **JT6295** — OKI MSM6295 ADPCM decoder | Jose Tejada | [jotego/jt6295](https://github.com/jotego/jt6295) | GPL-3 |
| **JTFRAME** — framework, clock enables, filters, mixer, shift registers, SDRAM64 | Jose Tejada | [jotego/jtframe](https://github.com/jotego/jtframe) | GPL-3 |
| **Savestate infrastructure** — ssbus, memory_stream, auto_save_adaptor, ram adaptors | Martin Donlon ([wickerwaka](https://github.com/wickerwaka)) | [wickerwaka/Arcade-TaitoF2_MiSTer](https://github.com/wickerwaka/Arcade-TaitoF2_MiSTer) | GPL-3 |
| **JTFRAME SDRAM64** — SDRAM controller (4-bank) | Jose Tejada | [jotego/jtframe](https://github.com/jotego/jtframe) | GPL-3 |
| **MAME** — reference for DECO16IC tilemap, DECO104 protection, DECO ACE, DECO156 / DECO56 / DECO74 decrypt, memory maps, timing | MAMEDev team | [mamedev/mame](https://github.com/mamedev/mame) | GPL-2+ |
| **sys/ framework** — MiSTer HPS/IO, OSD, video scaler, audio | Sorgelig / MiSTer-devel | [MiSTer-devel/Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) | GPL-3 |

## Reference

- **Night Slashers arcade hardware** — Data East Corporation, 1994
  (DE-0397-0 board). This FPGA core is a reimplementation from hardware
  documentation, MAME source code, and observation of real hardware behavior.
  ROMs are **not** included and must be provided by the user.
- **MAME project** — invaluable reference for memory maps, timing, the
  DECO16IC tilemap chips, DECO104 protection, the DECO ACE mixer, and the
  DECO156 (encrypted ARM) CPU + DECO56/DECO74 tile decrypt.
  [mamedev/mame](https://github.com/mamedev/mame)

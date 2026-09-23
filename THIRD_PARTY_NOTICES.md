# Third-party notices

DropMaster itself is MIT-licensed (see `LICENSE`). It contains one
third-party component.

## LAME (MP3 encoder)

- **What:** LAME 3.100, the MP3 encoding library `libmp3lame`. Used only for
  MP3 export.
- **Copyright:** © The LAME Project and its contributors - see
  <https://lame.sourceforge.io>.
- **License:** GNU Library General Public License, version 2 (LGPL-2.0). The
  full text ships with the source as `DropMaster/LAME/COPYING.LAME.txt`.
- **How it is used:** the unmodified library sources are compiled directly
  into the DropMaster application (`DropMaster/LAME/`). The only file added is
  `DropMaster/LAME/config.h`, a hand-written build configuration for macOS on
  Apple Silicon. The MP3 decoder, the x86 assembly and the SSE code are not
  built.
- **Relinking:** LAME is linked statically. As the LGPL requires, the
  complete source of both DropMaster and LAME is available, so DropMaster can
  be rebuilt against a modified version of LAME: replace the files in
  `DropMaster/LAME/` and build with `./build_dmg.sh`.

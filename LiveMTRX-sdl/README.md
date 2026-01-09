LiveMTRX-sdl
=================

SDL2 + Metal scaffold for LiveMTRX.

Goals:
- Run the existing stream simulation on the CPU (C)
- Render glyphs via a glyph atlas (GPU)
- Apply a CRT post-process in a fragment shader (Metal)

Build (macOS):
- Install SDL2 (Homebrew: `brew install sdl2`)
- mkdir build && cd build
- cmake ..
- make

Files:
- src/main.c         : bootstrap + SDL event loop
- src/sim.c / sim.h  : simulation port of the Python streams
- src/renderer.m     : Metal renderer glue (initial stub)
- src/shaders/*      : vertex + fragment shaders (conceptual)
- assets/atlas.png   : glyph atlas (placeholder)

Next:
I can implement sim.c mapping from your Python dataclasses and a first-pass Metal CRT shader.

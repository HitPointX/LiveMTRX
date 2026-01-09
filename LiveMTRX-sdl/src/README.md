Source notes

- Port strategy: sim.c mirrors the Python stream simulation; sim provides a simple frame of GlyphInstance structures.
- Renderer: renderer.m is an Objective-C Metal glue layer — implement glyph atlas texture creation, instance buffer updates, and a post-process pipeline that runs the CRT shader (crt.frag equivalent in Metal).
- Shaders: provided GLSL-like conceptual shader; when implementing, port to Metal Shading Language (.metal) and use proper samplers and coordinate spaces.

I can now:
- Convert sim.c to follow your Python ColumnStream behavior (length, persistent buffers, LUTs)
- Implement a Metal renderer that draws instanced quads from the glyph atlas and applies a two-pass bloom + CRT shader
- Produce a small Python tool to bake an atlas.png from a system font

Tell me which of these to do next.

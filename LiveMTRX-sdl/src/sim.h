#pragma once
#include <stdint.h>
#include <stdbool.h>

// Minimal sim API (expand later)

typedef struct {
    int x, y;    // integer positions for the GPU
    int glyph;   // atlas index
    int tier;    // intensity tier
} GlyphInstance;

// A frame contains a pointer to glyph instances (owned by sim)
typedef struct {
    GlyphInstance *instances;
    int count;
} SimFrame;

bool sim_init(int width, int height);
void sim_shutdown(void);
void sim_step(double dt);
SimFrame sim_get_frame(void);


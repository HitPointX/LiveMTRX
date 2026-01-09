#include "sim.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

// Very small placeholder simulation: produces a few moving glyphs.
static GlyphInstance *g_instances = NULL;
static int g_count = 0;
static int g_w = 80, g_h = 25;

bool sim_init(int width, int height) {
    g_w = width;
    g_h = height;
    srand((unsigned)time(NULL));
    g_count = 128;
    g_instances = calloc(g_count, sizeof(GlyphInstance));
    for (int i = 0; i < g_count; ++i) {
        g_instances[i].x = rand() % g_w;
        g_instances[i].y = rand() % g_h;
        g_instances[i].glyph = rand() % 256;
        g_instances[i].tier = rand() % 3;
    }
    return true;
}

void sim_shutdown(void) {
    free(g_instances);
    g_instances = NULL;
    g_count = 0;
}

void sim_step(double dt) {
    // placeholder: nudge glyphs down
    for (int i = 0; i < g_count; ++i) {
        g_instances[i].y += (int)(dt * 6.0);
        if (g_instances[i].y >= g_h) g_instances[i].y = 0;
    }
}

SimFrame sim_get_frame(void) {
    SimFrame f = { .instances = g_instances, .count = g_count };
    return f;
}


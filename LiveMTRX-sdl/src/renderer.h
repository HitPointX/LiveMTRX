#pragma once
#include "sim.h"
#include <SDL.h>
#include <stdbool.h>

bool renderer_init(SDL_Window *window);
void renderer_handle_event(const SDL_Event *e);
void renderer_draw(SimFrame frame);
void renderer_shutdown(void);

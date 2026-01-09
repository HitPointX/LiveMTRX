#include <SDL.h>
#include <stdbool.h>
#include <stdio.h>
#include "sim.h"
#include "renderer.h"

int main(int argc, char **argv) {
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0) {
        fprintf(stderr, "SDL_Init Error: %s\n", SDL_GetError());
        return 1;
    }

    SDL_Window *win = SDL_CreateWindow("LiveMTRX-sdl", 100, 100, 1280, 720, SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_METAL);
    if (!win) {
        fprintf(stderr, "SDL_CreateWindow Error: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }

    if (!renderer_init(win)) {
        fprintf(stderr, "renderer_init failed\n");
        SDL_DestroyWindow(win);
        SDL_Quit();
        return 1;
    }

    int w, h;
    SDL_GetWindowSize(win, &w, &h);
    sim_init(w, h);

    bool running = true;
    uint64_t last = SDL_GetPerformanceCounter();

    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = false;
            else if (e.type == SDL_KEYDOWN) {
                if (e.key.keysym.sym == SDLK_q) running = false;
            }
            renderer_handle_event(&e);
        }

        uint64_t now = SDL_GetPerformanceCounter();
        double dt = (double)(now - last) / SDL_GetPerformanceFrequency();
        last = now;

        sim_step(dt);
        renderer_draw(sim_get_frame());

        // simple throttle
        SDL_Delay(1);
    }

    renderer_shutdown();
    sim_shutdown();
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}

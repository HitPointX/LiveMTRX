#!/usr/bin/env python3
"""
LiveMTRX - terminal Matrix effect for macOS
"""
import sys
import os
import random
import time
import shutil
import signal

from collections import deque

# ANSI escape helpers
CSI = "\x1b["

# Color palettes (foreground)
PALETTES = [
    # Greens
    [(32, 32, 32), (0, 255, 0), (0, 200, 0), (32, 255, 32)],
    # Rainbows
    [(255, 0, 0), (255, 165, 0), (255, 255, 0), (0, 255, 0), (0, 0, 255), (75, 0, 130)],
    # Blues
    [(0, 255, 255), (0, 200, 255), (0, 150, 255), (32, 32, 64)],
]

# Characters to display
CHARS = list('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$%^&*()[]{}<>/\\|;:,."\'')

# Terminal control
def clear():
    sys.stdout.write(CSI + '2J' + CSI + 'H')

def move(x, y):
    sys.stdout.write(f"{CSI}{y};{x}H")

def hide_cursor():
    sys.stdout.write(CSI + '?25l')

def show_cursor():
    sys.stdout.write(CSI + '?25h')

def set_rgb(r, g, b, bright=False):
    # Use 38;2 for truecolor
    return f"{CSI}38;2;{r};{g};{b}m"

def reset():
    sys.stdout.write(CSI + '0m')

class Column:
    def __init__(self, x, height, palette):
        self.x = x
        self.height = height
        self.palette = palette
        self.drops = deque()
        self.spawn_delay = random.randint(0, 30)
        self.speed = random.uniform(0.02, 0.12)

    def step(self):
        if self.spawn_delay > 0:
            self.spawn_delay -= 1
        else:
            # spawn new drop occasionally
            if random.random() < 0.15:
                length = random.randint(3, min(20, self.height // 2))
                head_pos = 0
                self.drops.append({'pos': head_pos, 'len': length, 'age': 0, 'lead_color': None})

        new_drops = deque()
        for drop in self.drops:
            drop['pos'] += 1
            drop['age'] += 1
            # remove if past bottom
            if drop['pos'] - drop['len'] > self.height:
                continue
            new_drops.append(drop)
        self.drops = new_drops

    def draw(self):
        out = ''
        for drop in self.drops:
            for i in range(drop['len']):
                y = drop['pos'] - i
                if y <= 0 or y > self.height:
                    continue
                # choose color based on i (head brighter)
                t = i / max(1, drop['len'] - 1)
                if i == 0:
                    # lead - will be white/grey occasionally
                    if drop['lead_color'] is None:
                        if random.random() < 0.1:
                            drop['lead_color'] = (255, 255, 255) if random.random() < 0.5 else (200, 200, 200)
                        else:
                            drop['lead_color'] = None
                    color = drop['lead_color'] if drop['lead_color'] else random.choice(self.palette)
                else:
                    # interpolate palette
                    color = random.choice(self.palette)
                ch = random.choice(CHARS)
                out += f"{move(self.x, y)}{set_rgb(*color)}{ch}"
        return out


def main():
    cols, rows = shutil.get_terminal_size()
    hide_cursor()

    # initialize columns
    columns = [Column(x+1, rows, random.choice(PALETTES)) for x in range(cols)]

    palette_change_time = time.time() + 30
    try:
        clear()
        while True:
            now = time.time()
            if now > palette_change_time:
                # change palettes randomly
                for c in columns:
                    c.palette = random.choice(PALETTES)
                palette_change_time = now + 30

            frame = ''
            for c in columns:
                c.step()
                frame += c.draw()

            sys.stdout.write(frame)
            sys.stdout.flush()
            time.sleep(0.05)
    except KeyboardInterrupt:
        reset()
        show_cursor()
        clear()
        sys.exit(0)

if __name__ == '__main__':
    main()

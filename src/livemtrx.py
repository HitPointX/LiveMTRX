#!/usr/bin/env python3
import curses
import random
import time
from dataclasses import dataclass
from typing import List
import os

# Debug logging
DEBUG = os.environ.get('LIVEMTRX_DEBUG', '0') in ('1', 'true', 'True')
LOG_PATH = '/tmp/livemtrx.log'

def log(msg: str):
    if not DEBUG:
        return
    try:
        with open(LOG_PATH, 'a') as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except Exception:
        pass

log('livemtrx.py starting')
log(f'TERM={os.environ.get("TERM")}, COLORTERM={os.environ.get("COLORTERM")}, LANG={os.environ.get("LANG")}')


THEME_PERIOD_SEC = 30.0
TARGET_FPS = 45.0
DT = 1.0 / TARGET_FPS
DEFAULT_DENSITY = 0.75

# Speed modulation
SPEED_MOOD_PERIOD_SEC = 10.0          # every 10s pick a new speed "mood"
SPEED_EASE_SEC = 1.25                 # smooth transition duration
BASE_SPEED_MIN = 4.0                  # slower baseline
BASE_SPEED_MAX = 12.0                 # slower baseline

# Darkness tuning
BACKGROUND_DIM_START = 0.35   # fraction of tail where heavy dimming starts
BACKGROUND_DIM_FORCE = True  # always dim deep background glyphs
DARKEN_COLOR_OFFSET = 8      # shift fg color darker (256-color only)

# --- CRT-ish post FX (terminal approximation) ---
ENABLE_CHROMA = True
CHROMA_STRENGTH = 0.06          # lower subtle chroma
CHROMA_APPLY_TO = "head_plus"   # "head_only" | "head_plus" | "all"
CHROMA_MAX_OFFSET = 1           # 1 cell offset only (terminal safe)

ENABLE_SCANLINES = True
SCANLINE_EVERY = 2
SCANLINE_DIM_AMOUNT = 1         # 1 = DIM, 2 = DIM+slightly darker color (256 only)

ENABLE_ROLLING_SCANLINE = True
ROLL_PERIOD_SEC = 10.0           # slower roll = more CRT
ROLL_WIDTH = 1
ROLL_MODE = "dim"               # "dim" or "bright"

# Partial redraw / caching
PARTIAL_REDRAW = True
CLEAR_TAIL_CELL = False     # True = crisper but more draws
TAIL_CLEAR_CHAR = ' '

# Predictive tick for FX and input (controls max wakeup rate)
FX_TICK = 1.0 / 30.0  # 30Hz for scanline/input responsiveness

# Slightly more "matrixy" pool (still includes some symbols)
ASCII_POOL = (
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789"
    "@#$%&*+=-:;.,!?/\\|[]{}()<>"
)

# Unicode glyph pool - curated to *usually* render in common macOS mono fonts.
# If you see tofu boxes, remove the ranges you don't like.
UNICODE_GLYPHS = (
    # Katakana (classic matrix vibe)
    "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉ"
    "ﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ"
    # Greek (usually safe)
    "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ"
    "αβγδεζηθικλμνξοπρστυφχψω"
    # Math-ish symbols (often safe)
    "∑∏√∞≈≠≤≥÷×±∫∂∇∈∩∪⊂⊃⊕⊗"
    # Box drawing (safe and very terminal-friendly)
    "│┃━─┌┐└┘├┤┬┴┼╭╮╰╯"
    # Misc techy symbols
    "◊◈◇◆○●◎◌◍◐◑◒◓"
    "■□▢▣▤▥▦▧▨▩"
)

# What percent of chars should come from UNICODE_GLYPHS
GLYPH_MIX = 0.28  # 0.0 = pure ASCII, 1.0 = pure unicode

@dataclass
class ColumnStream:
    x: int
    y: float
    speed: float
    length: int
    active: bool
    chars: List[str]
    last_head_y: int
    lut: List[int]

class ColorManager:
    """
    macOS curses can behave weird with use_default_colors() and bg = -1.
    So we keep it simple: black background, and only use supported fg colors.
    If 256-colors exist, we still only init a small set of pairs to avoid churn.
    """
    def __init__(self):
        curses.start_color()
        self.has_256 = (curses.COLORS >= 256)
        self._pair = {}   # fg -> pair_id
        self._next = 1

        self.bg = curses.COLOR_BLACK

        # Pre-seed some "safe" fgs
        self.safe_basic = [
            curses.COLOR_GREEN,
            curses.COLOR_CYAN,
            curses.COLOR_BLUE,
            curses.COLOR_MAGENTA,
            curses.COLOR_YELLOW,
            curses.COLOR_RED,
            curses.COLOR_WHITE,
        ]

    def pair(self, fg: int) -> int:
        # Clamp fg to valid range
        if fg < 0:
            fg = curses.COLOR_GREEN
        if self.has_256:
            fg = max(0, min(255, fg))
        else:
            # fallback to basic green if not standard
            if fg not in self.safe_basic:
                fg = curses.COLOR_GREEN

        if fg in self._pair:
            return self._pair[fg]

        pid = self._next
        # If we somehow exceed pairs, fall back
        if pid >= curses.COLOR_PAIRS:
            return self._pair.get(curses.COLOR_GREEN, 1)

        try:
            curses.init_pair(pid, fg, self.bg)
        except Exception:
            # Hard fallback
            curses.init_pair(pid, curses.COLOR_GREEN, self.bg)

        self._pair[fg] = pid
        self._next += 1
        return pid

def now() -> float:
    return time.monotonic()

def clamp(v: float, lo: float, hi: float) -> float:
    return lo if v < lo else hi if v > hi else v

# Choose a glyph, mixing ASCII and curated Unicode
def rand_glyph() -> str:
    if UNICODE_GLYPHS and random.random() < GLYPH_MIX:
        return random.choice(UNICODE_GLYPHS)
    return random.choice(ASCII_POOL)

# Darken a color index safely for 256-color terminals
def darken_color(fg: int, has_256: bool) -> int:
    if not has_256:
        return fg
    return max(0, fg - DARKEN_COLOR_OFFSET)

# Scanline helper
def scanline_row(y: int) -> bool:
    return (y % SCANLINE_EVERY) == 0

# Rolling scanline index
def roll_row(t: float, h: int) -> int:
    if h <= 0:
        return 0
    return int((t / ROLL_PERIOD_SEC) * h) % h

# Tint helper: derive subtle fringe color from base instead of jumping to red/cyan
def tint_color(base_fg: int, cm_has_256: bool, direction: int) -> int:
    """
    Return a subtle tint derived from the base color instead of pure red/cyan.
    direction: -1 left fringe, +1 right fringe
    """
    if not cm_has_256:
        # basic mode: very subtle tinting
        return curses.COLOR_WHITE if direction < 0 else curses.COLOR_CYAN

    # Nudge the color index slightly toward darker/lighter for tint
    if direction < 0:
        return max(0, base_fg - 2)
    else:
        return min(255, base_fg + 2)

def make_palette(has_256: bool) -> List[int]:
    """
    A theme palette for body glyphs.
    For 256-color terminals, we mostly live in green-cyan land
    with occasional 'weird' accents.
    """
    if not has_256:
        pal = [curses.COLOR_GREEN, curses.COLOR_CYAN, curses.COLOR_YELLOW]
        random.shuffle(pal)
        return pal

    greens = list(range(22, 47))     # greens
    teals  = list(range(30, 52))     # cyan-ish greens
    neons  = list(range(82, 87))     # bright greens
    chaos  = list(range(160, 201))   # reds/pinks/purples

    base = greens + teals
    if random.random() < 0.35:
        base += neons
    if random.random() < 0.08:
        base += chaos

    random.shuffle(base)
    return base[:10] if len(base) >= 10 else base

# Spawn/reset a stream with prefilled chars
def spawn_stream(x: int, density: float) -> ColumnStream:
    length = random.randint(10, 42)
    active = random.random() < density
    chars = [rand_glyph() for _ in range(length)]
    # build intensity LUT for this stream length
    lut = build_intensity_lut(length)
    return ColumnStream(
        x=x,
        y=random.uniform(-length * 2.0, 0.0),
        speed=random.uniform(BASE_SPEED_MIN, BASE_SPEED_MAX),
        length=length,
        active=active,
        chars=chars,
        last_head_y=-10_000,
        lut=lut,
    )

# intensity LUT helper
def build_intensity_lut(length: int) -> List[int]:
    lut = [0] * length
    for i in range(length):
        if i == 0:
            lut[i] = 0
        elif i <= 2:
            lut[i] = 1
        elif i <= int(length * 0.55):
            lut[i] = 2
        else:
            lut[i] = 3
    return lut

def init_streams(width: int, density: float) -> List[ColumnStream]:
    return [spawn_stream(x, density) for x in range(width)]

def draw(stdscr):
    curses.curs_set(0)
    stdscr.nodelay(True)
    stdscr.keypad(True)

    cm = ColorManager()

    h, w = stdscr.getmaxyx()
    density = DEFAULT_DENSITY
    streams = init_streams(w, density)

    theme_palette = make_palette(cm.has_256)
    next_theme_at = now() + THEME_PERIOD_SEC

    # speed mood state
    speed_factor = 1.0
    target_speed_factor = 1.0
    next_speed_mood_at = now() + SPEED_MOOD_PERIOD_SEC
    speed_ease_t0 = now()
    speed_ease_from = 1.0

    # header color: flip between white and "grey-ish"
    lead_is_grey = random.random() < 0.5
    next_lead_flip = now() + random.uniform(6.0, 16.0)

    last = now()

    # screen dirty cache
    screen_ch = [[" "] * w for _ in range(h)]
    screen_attr = [[0] * w for _ in range(h)]

    def put(y: int, x: int, ch: str, attr: int):
        if 0 <= y < h and 0 <= x < w:
            if screen_ch[y][x] == ch and screen_attr[y][x] == attr:
                return
            screen_ch[y][x] = ch
            screen_attr[y][x] = attr
            try:
                stdscr.addch(y, x, ch, attr)
            except curses.error:
                pass

    # helper to compute attr for an index in a stream
    def compute_attr(i: int, s: ColumnStream, base_fg_choice: int, lead_fg_local: int):
        # use stream LUT for tier
        tier = s.lut[i] if i < len(s.lut) else 2
        if tier == 0:
            base_fg = lead_fg_local
            attr_local = curses.color_pair(cm.pair(base_fg)) | curses.A_BOLD
            if (not cm.has_256) and lead_is_grey:
                attr_local |= curses.A_DIM
        elif tier == 1:
            base_fg = base_fg_choice
            attr_local = curses.color_pair(cm.pair(base_fg)) | curses.A_BOLD
        elif tier == 2:
            base_fg = base_fg_choice
            attr_local = curses.color_pair(cm.pair(base_fg))
        else:
            base_fg = base_fg_choice
            if cm.has_256:
                base_fg = max(0, base_fg - 10)
            attr_local = curses.color_pair(cm.pair(base_fg)) | curses.A_DIM
        return attr_local, base_fg

    def pick_speed_mood() -> float:
        r = random.random()
        # Weighted moods: mostly chill, sometimes spicy
        if r < 0.50:
            return random.uniform(0.55, 0.85)   # slow
        elif r < 0.85:
            return random.uniform(0.85, 1.20)   # normal
        elif r < 0.97:
            return random.uniform(1.20, 1.70)   # fast
        else:
            return random.uniform(1.70, 2.40)   # turbo gremlin (rare)

    while True:
        t = now()
        dt = t - last
        last = t
        if dt <= 0:
            dt = DT

        # input
        try:
            k = stdscr.getch()
        except Exception:
            k = -1

        if k in (ord('q'), ord('Q')):
            break
        elif k in (ord('c'), ord('C')):
            theme_palette = make_palette(cm.has_256)
            next_theme_at = t + THEME_PERIOD_SEC
        elif k in (ord('r'), ord('R')):
            random.seed(int(time.time() * 1000) ^ random.getrandbits(32))
            streams = init_streams(w, density)
        elif k == ord('+'):
            density = clamp(density + 0.05, 0.05, 1.0)
            streams = init_streams(w, density)
        elif k == ord('-'):
            density = clamp(density - 0.05, 0.05, 1.0)
            streams = init_streams(w, density)

        # resize
        nh, nw = stdscr.getmaxyx()
        if (nh, nw) != (h, w):
            h, w = nh, nw
            streams = init_streams(w, density)
            stdscr.erase()

        # theme tick
        if t >= next_theme_at:
            theme_palette = make_palette(cm.has_256)
            next_theme_at = t + THEME_PERIOD_SEC

        # lead flip tick
        if t >= next_lead_flip:
            lead_is_grey = not lead_is_grey
            next_lead_flip = t + random.uniform(6.0, 16.0)

        # speed mood tick
        if t >= next_speed_mood_at:
            next_speed_mood_at = t + SPEED_MOOD_PERIOD_SEC
            speed_ease_t0 = t
            speed_ease_from = speed_factor
            target_speed_factor = pick_speed_mood()

        # ease speed_factor toward target to avoid sudden pops
        ease_u = (t - speed_ease_t0) / SPEED_EASE_SEC
        if ease_u >= 1.0:
            speed_factor = target_speed_factor
        else:
            ease_u = max(0.0, ease_u)
            speed_factor = speed_ease_from + (target_speed_factor - speed_ease_from) * ease_u

        # choose lead fg
        if cm.has_256:
            lead_fg = random.choice([250, 251, 252, 253, 254, 255]) if lead_is_grey else 255
        else:
            lead_fg = curses.COLOR_WHITE

        # --- Predict next stream event (row crossing) to reduce wasted frames ---
        next_event_dt = FX_TICK
        for s in streams:
            if not s.active:
                continue
            v = s.speed * speed_factor
            if v <= 1e-6:
                continue
            next_boundary = int(s.y) + 1
            dt_to_boundary = (next_boundary - s.y) / v
            if dt_to_boundary > 0 and dt_to_boundary < next_event_dt:
                next_event_dt = dt_to_boundary

        # simple "fade" by writing spaces at random spots
        if random.random() < 0.10:
            fx = random.randrange(0, w)
            fy = random.randrange(0, h)
            put(fy, fx, ' ', 0)

        # very subtle terminal 'grain' seasoning
        if random.random() < 0.002:
            gx = random.randrange(0, w)
            gy = random.randrange(0, h)
            put(gy, gx, '·', curses.A_DIM)

        # draw streams
        for s in streams:
            if not s.active:
                # occasionally (re)activate with a fresh spawn
                if random.random() < density * 0.02:
                    ns = spawn_stream(s.x, density)
                    s.y = ns.y
                    s.speed = ns.speed
                    s.length = ns.length
                    s.chars = ns.chars
                    s.last_head_y = ns.last_head_y
                    s.active = True
                continue

            # advance stream head
            s.y += (s.speed * speed_factor) * dt
            head = int(s.y)

            # Shift buffered chars only when head moves — this creates long streaks
            if head != s.last_head_y:
                old_head = s.last_head_y
                steps = head - s.last_head_y
                if steps > 0:
                    steps = min(steps, s.length)
                    for _ in range(steps):
                        s.chars.insert(0, rand_glyph())
                        s.chars.pop()
                s.last_head_y = head

                # Partial redraw: only draw the new head area to reduce draws
                if PARTIAL_REDRAW and steps > 0:
                    # pick a stable body color for this frame to reduce RNG
                    frame_body_fg = random.choice(theme_palette) if theme_palette else curses.COLOR_GREEN
                    for dy in range(0, min(4, s.length)):
                        y = head - dy
                        if 0 <= y < h:
                            i = dy
                            ch = s.chars[i]
                            attr_local, base_fg_local = compute_attr(i, s, frame_body_fg, lead_fg)

                            # Head phosphor halo (CRT bloom illusion)
                            if i == 0:
                                hy = y + 1
                                if 0 <= hy < h:
                                    halo_attr = curses.color_pair(cm.pair(base_fg_local)) | curses.A_DIM
                                    put(hy, s.x, ch, halo_attr)

                            # scanline (apply only as DIM, never recolor)
                            if ENABLE_SCANLINES and (y & 1) == 0:
                                attr_local |= curses.A_DIM
                            if ENABLE_ROLLING_SCANLINE and y == roll_row(t, h):
                                attr_local |= curses.A_BOLD

                            put(y, s.x, ch, attr_local)

                    # optional tail clear
                    if CLEAR_TAIL_CELL:
                        tail_y = head - s.length
                        if 0 <= tail_y < h:
                            put(tail_y, s.x, TAIL_CLEAR_CHAR, 0)

                    # skip full column redraw
                    continue

            # reset if fully offscreen
            if head - s.length > h + 2:
                if random.random() < density:
                    ns = spawn_stream(s.x, density)
                    s.y = ns.y
                    s.speed = ns.speed
                    s.length = ns.length
                    s.chars = ns.chars
                    s.last_head_y = ns.last_head_y
                    s.lut = ns.lut
                    s.active = True
                else:
                    s.active = False
                continue

            # occasional small mutations so tails aren't perfectly static
            if random.random() < 0.06 and s.length > 1:
                # mutate an index in the lively near-head half
                idx = random.randrange(0, max(1, int(s.length * 0.5)))
                s.chars[idx] = rand_glyph()
            elif random.random() < 0.015:
                # rare deep-tail mutation
                idx = random.randrange(0, s.length)
                s.chars[idx] = rand_glyph()

            # draw using buffered chars and a brightness gradient (full column draw)
            frame_body_fg = random.choice(theme_palette) if theme_palette else curses.COLOR_GREEN
            for i in range(s.length):
                y = head - i
                if y < 0 or y >= h:
                    continue
                ch = s.chars[i]
                attr_local, base_fg_local = compute_attr(i, s, frame_body_fg, lead_fg)

                # Head phosphor halo (CRT bloom illusion)
                if i == 0:
                    hy = y + 1
                    if 0 <= hy < h:
                        halo_attr = curses.color_pair(cm.pair(base_fg_local)) | curses.A_DIM
                        put(hy, s.x, ch, halo_attr)

                # scanline (apply only as DIM, never recolor)
                if ENABLE_SCANLINES and (y & 1) == 0:
                    attr_local |= curses.A_DIM
                if ENABLE_ROLLING_SCANLINE and y == roll_row(t, h):
                    attr_local |= curses.A_BOLD

                put(y, s.x, ch, attr_local)

        stdscr.refresh()
        # Sleep until next important event (stream boundary or FX tick)
        sleep_for = max(0.0, min(next_event_dt, 0.05))
        time.sleep(sleep_for)

def main():
    try:
        curses.wrapper(draw)
    except Exception as e:
        log(f'Unhandled exception in main: {e}')
        raise

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass

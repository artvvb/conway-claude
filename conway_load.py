#!/usr/bin/env python3
"""conway_load.py -- Load a Conway pattern into the Basys 3 engine over UART
and start the simulation.

The script speaks the protocol implemented by uart_cmd.sv:

    '.'                                    stop the engine
    'R'                                    zero both framebuffers
    'W' (4 hex) count
        (4 hex) start_row
        (4 hex) start_col
        (4 hex) width
        (count nibbles) payload            row-major, MSB-first within nibble
    '>'                                    start free-running simulation

Each named pattern below is an ASCII rectangle ('#' = alive, anything else =
dead).  --pattern selects which one; a few entries are tiled/random fills
generated procedurally.

Typical use:
    python conway_load.py COM3                       (default: gosper gun)
    python conway_load.py COM3 -p glider-fleet
    python conway_load.py COM3 -p random --seed 7
    python conway_load.py COM3 -p pulsar --row 200 --col 320

Note on payload padding
    If width * height is not a multiple of 4, the last nibble has 1-3 trailing
    zero bits.  These zeros are written to pixels just past the bottom-right
    of your sub-grid -- harmless after a fresh 'R', clobbering otherwise.
    Use --no-reset only when you know the affected pixels are already dead.
"""

import argparse
import random
import sys
import time

import serial


# ----------------------------------------------------------------------------
# Pattern catalogue
# ----------------------------------------------------------------------------
PATTERNS = {
    "glider": [
        ".#.",
        "..#",
        "###",
    ],
    "blinker": [
        "###",
    ],
    "block": [
        "##",
        "##",
    ],
    "beacon": [
        "##..",
        "##..",
        "..##",
        "..##",
    ],
    "toad": [
        ".###",
        "###.",
    ],
    "lwss": [           # lightweight spaceship (moves left)
        "#..#.",
        "....#",
        "#...#",
        ".####",
    ],
    "r-pent": [         # R-pentomino: tiny but very chaotic
        ".##",
        "##.",
        ".#.",
    ],
    "acorn": [          # methuselah, stabilises after ~5200 generations
        ".#.....",
        "...#...",
        "##..###",
    ],
    "diehard": [        # methuselah, dies after 130 generations
        "......#.",
        "##......",
        ".#...###",
    ],
    "pulsar": [         # period-3 oscillator, 13 x 13
        "..###...###..",
        ".............",
        "#....#.#....#",
        "#....#.#....#",
        "#....#.#....#",
        "..###...###..",
        ".............",
        "..###...###..",
        "#....#.#....#",
        "#....#.#....#",
        "#....#.#....#",
        ".............",
        "..###...###..",
    ],
    "gosper": [         # Gosper glider gun, 36 x 9 -- emits gliders forever
        "........................#...........",
        "......................#.#...........",
        "............##......##............##",
        "...........#...#....##............##",
        "##........#.....#...##..............",
        "##........#...#.##....#.#...........",
        "..........#.....#.......#...........",
        "...........#...#....................",
        "............##......................",
    ],
}


def tile(rows, n_x, n_y, spacing=8):
    """Repeat `rows` in an n_x x n_y grid with `spacing` empty cells between
    each instance.  Returns the resulting list of strings (uniform width)."""
    h = len(rows)
    w = max(len(r) for r in rows)
    rows = [r.ljust(w, ".") for r in rows]

    block_w = w + spacing
    block_h = h + spacing
    out_w = block_w * n_x - spacing
    out_h = block_h * n_y - spacing
    grid = [["."] * out_w for _ in range(out_h)]

    for ty in range(n_y):
        for tx in range(n_x):
            for y, r in enumerate(rows):
                for x, c in enumerate(r):
                    if c == "#":
                        grid[ty * block_h + y][tx * block_w + x] = "#"
    return ["".join(r) for r in grid]


def random_field(w, h, density=0.3, seed=None):
    """Random alive/dead grid of w x h with the given density."""
    if seed is not None:
        random.seed(seed)
    return [
        "".join("#" if random.random() < density else "." for _ in range(w))
        for _ in range(h)
    ]


def stripes(w, h, period=4, vertical=True):
    """Repeating live/dead stripes -- noisy initial state."""
    if vertical:
        return ["".join("#" if x % period == 0 else "." for x in range(w))
                for _ in range(h)]
    return ["#" * w if y % period == 0 else "." * w for y in range(h)]


# ----------------------------------------------------------------------------
# Wire-format encoder
# ----------------------------------------------------------------------------
def pack_payload(rows, width):
    """Convert ASCII rows -> hex nibble string in the order uart_cmd consumes:
    row-major across the sub-grid, MSB-first within each nibble."""
    bits = []
    for r in rows:
        r = r.ljust(width, ".")[:width]
        bits.extend("1" if c == "#" else "0" for c in r)
    # Pad to a whole nibble; trailing zeros land just past the sub-grid.
    bits += ["0"] * ((-len(bits)) % 4)

    nibbles = []
    for i in range(0, len(bits), 4):
        nibbles.append(f"{int(''.join(bits[i:i + 4]), 2):X}")
    return "".join(nibbles)


def write_command(start_row, start_col, width, rows):
    payload = pack_payload(rows, width)
    return (f"W{len(payload):04X}"
            f"{start_row:04X}{start_col:04X}{width:04X}"
            f"{payload}")


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
def build_pattern(args):
    name = args.pattern
    if name == "random":
        return random_field(args.rand_w, args.rand_h, args.density, args.seed)
    if name == "stripes":
        return stripes(args.rand_w, args.rand_h, period=args.period)
    if name == "glider-fleet":
        return tile(PATTERNS["glider"], args.repeat, args.repeat, args.spacing)
    if name == "blinker-grid":
        return tile(PATTERNS["blinker"], args.repeat, args.repeat, args.spacing)
    if name == "block-grid":
        return tile(PATTERNS["block"], args.repeat, args.repeat, args.spacing)
    if name in PATTERNS:
        return PATTERNS[name]
    sys.exit(f"Unknown pattern: {name}")


def main():
    ap = argparse.ArgumentParser(
        description="Load a Conway pattern into the Basys 3 over UART.")
    ap.add_argument("port", help="serial port, e.g. COM3 or /dev/ttyUSB0")
    ap.add_argument("--pattern", "-p", default="gosper",
                    help="pattern name; one of "
                         + ", ".join(sorted(PATTERNS))
                         + ", glider-fleet, blinker-grid, block-grid, "
                         + "random, stripes")
    ap.add_argument("--row", type=int, default=200, help="top-left row")
    ap.add_argument("--col", type=int, default=300, help="top-left column")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--no-reset", action="store_true",
                    help="skip the 'R' sweep before writing")
    ap.add_argument("--no-start", action="store_true",
                    help="don't issue '>' after writing")
    # Random / stripes options
    ap.add_argument("--rand-w", type=int, default=200)
    ap.add_argument("--rand-h", type=int, default=150)
    ap.add_argument("--density", type=float, default=0.3)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--period", type=int, default=4)
    # Tiled options
    ap.add_argument("--repeat", type=int, default=10)
    ap.add_argument("--spacing", type=int, default=8)
    args = ap.parse_args()

    rows = build_pattern(args)
    width = max(len(r) for r in rows)
    height = len(rows)
    rows = [r.ljust(width, ".") for r in rows]

    cmd = write_command(args.row, args.col, width, rows)
    payload_chars = len(cmd) - 1 - 16    # minus 'W' and the four 4-char params
    n_pixels = width * height

    print(f"Pattern  : {args.pattern}")
    print(f"Size     : {width} x {height}  ({n_pixels} pixels, "
          f"{payload_chars} payload nibbles)")
    print(f"Position : row={args.row}, col={args.col}")

    try:
        ser = serial.Serial(args.port, args.baud, timeout=1)
    except serial.SerialException as exc:
        sys.exit(f"Error opening {args.port}: {exc}")

    with ser:
        # Stop -- gives the FPGA a clean state regardless of what was running.
        ser.write(b".")
        ser.flush()
        time.sleep(0.005)

        if not args.no_reset:
            print("Reset    : R")
            ser.write(b"R")
            ser.flush()
            # 'R' sweeps every pixel: 640 * 480 / 25 MHz ~= 12.3 ms.
            time.sleep(0.05)

        print(f"Write    : W ({len(cmd)} bytes total)")
        ser.write(cmd.encode("ascii"))
        ser.flush()
        # Each payload nibble takes 4 cycles to write at 25 MHz; far below
        # the UART byte rate, but allow the OS-side buffer to flush fully.
        time.sleep(0.05 + payload_chars / args.baud * 10)

        if not args.no_start:
            print("Start    : >")
            ser.write(b">")
            ser.flush()

    print("Done.")


if __name__ == "__main__":
    main()

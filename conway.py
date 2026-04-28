"""
conway.py — Streaming Conway's Game of Life: Python model for Verilog/FPGA.

Architecture
------------
Framebuffers (×2)
  Each framebuffer is a 3×3 array of block RAMs.  Pixel (x, y) lives in
  BRAM[x%3][y%3] at address  (y//3)*(W//3) + (x//3).  Because the three
  x-coordinates of any 3×3 neighbourhood are always three consecutive values
  mod 3 (and similarly for y), the nine neighbourhood pixels occupy all nine
  BRAMs exactly once — enabling a conflict-free single-cycle parallel read.

Pipeline (2 register stages, gated by enable)
  Stage 0 register  : captures (cx, cy) — the address issued to the BRAMs.
  Stage 1 register  : captures the 3×3 neighbourhood from the BRAMs and the
                      (cx, cy) it belongs to.
  Write-back        : applies the Conway rule and writes to the write buffer.

  Pipeline latency from address issue to write-back is 2 clock cycles.
  One pixel is produced per clock cycle when enable = 1.

Enable / backpressure
  enable = 0 freezes the entire pipeline and all counters.  A downstream
  video controller drives this low during horizontal and vertical blanking.

Framebuffer swap
  After the last pixel of a frame has been written, the framebuffers swap:
  the just-written buffer becomes the source for the next computation.
  Counters and pipeline registers reset at the same moment, matching the
  hardware vsync counter-reset behaviour.

Constraints
  W and H must be multiples of 3.

Verilog mapping notes
  - BRAMArray.mem[bx][by]       → true dual-port BRAM primitive
  - ConwayStreamingModel._s1/2  → pipeline registers (always @(posedge clk))
  - cx, cy                      → raster-scan counters
  - read_fb / write_fb          → 1-bit register selecting the active buffer pair
  - _conway_rule                → 4-bit adder tree + LUT
"""

from itertools import product as _product


# ---------------------------------------------------------------------------
# Block-RAM array
# ---------------------------------------------------------------------------

class BRAMArray:
    """
    3×3 array of block RAMs representing one Conway framebuffer.

    Addressing
    ----------
    Pixel (x, y)  →  BRAM[x%3][y%3]  at  address  (y//3)*(W//3) + (x//3)

    Any 3×3 neighbourhood centred at (cx, cy) reads each BRAM exactly once.
    The BRAM index for neighbourhood offset (dx, dy) is:
        bx = (cx + dx) % 3
        by = (cy + dy) % 3
    Conversely, given a BRAM index (bx, by) and centre (cx, cy):
        dx = ((bx - cx%3) + 4) % 3 - 1     ∈ {-1, 0, 1}
        dy = ((by - cy%3) + 4) % 3 - 1
    """

    def __init__(self, width: int, height: int):
        self.W  = width
        self.H  = height
        self.bw = width  // 3   # BRAM word-columns  (entries per BRAM row)
        self.bh = height // 3   # BRAM word-rows
        # mem[bx][by] → flat list of bw*bh single-bit cells
        self.mem: list = [
            [[0] * (self.bw * self.bh) for _ in range(3)]
            for _ in range(3)
        ]

    def _loc(self, x: int, y: int):
        """Return (bx, by, addr) for pixel (x, y) with toroidal wraparound."""
        x = x % self.W
        y = y % self.H
        return x % 3, y % 3, (y // 3) * self.bw + (x // 3)

    def read_pixel(self, x: int, y: int) -> int:
        bx, by, a = self._loc(x, y)
        return self.mem[bx][by][a]

    def write_pixel(self, x: int, y: int, val: int):
        bx, by, a = self._loc(x, y)
        self.mem[bx][by][a] = val & 1

    def read_neighbourhood(self, cx: int, cy: int) -> list:
        """
        Read the full 3×3 neighbourhood centred at (cx, cy).

        Issues one read to each of the nine BRAMs simultaneously (no port
        conflicts by construction).  Returns nbhd[row][col] where row and col
        are in [0, 2]; nbhd[1][1] is the centre pixel.

        In Verilog this maps to nine simultaneous BRAM read-address assertions.
        The address presented to BRAM[bx][by] on clock cycle N is:
            addr[bx][by] = addr_of( (cx + dx) % W , (cy + dy) % H )
        where dx = ((bx - cx%3) + 4)%3 - 1  and  dy = ((by - cy%3) + 4)%3 - 1.
        """
        cx_m3 = cx % 3
        cy_m3 = cy % 3
        nbhd = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
        for bx, by in _product(range(3), range(3)):
            dx = ((bx - cx_m3) + 4) % 3 - 1   # ∈ {-1, 0, 1}
            dy = ((by - cy_m3) + 4) % 3 - 1
            x  = (cx + dx) % self.W
            y  = (cy + dy) % self.H
            addr = (y // 3) * self.bw + (x // 3)
            nbhd[dy + 1][dx + 1] = self.mem[bx][by][addr]
        return nbhd

    def load(self, grid):
        """Bulk-write from grid[y][x] into the BRAM array."""
        for y in range(self.H):
            for x in range(self.W):
                self.write_pixel(x, y, int(bool(grid[y][x])))

    def dump(self) -> list:
        """Return the full frame as a 2-D list (row-major)."""
        return [[self.read_pixel(x, y) for x in range(self.W)]
                for y in range(self.H)]


# ---------------------------------------------------------------------------
# Conway rule
# ---------------------------------------------------------------------------

def _conway_rule(nbhd: list) -> int:
    """Apply Conway's rule to a 3×3 neighbourhood list-of-lists."""
    live = sum(nbhd[r][c] for r in range(3) for c in range(3)) - nbhd[1][1]
    if nbhd[1][1]:
        return 1 if live in (2, 3) else 0
    return 1 if live == 3 else 0


# ---------------------------------------------------------------------------
# Streaming model
# ---------------------------------------------------------------------------

class ConwayStreamingModel:
    """
    Cycle-accurate Python model of the streaming Conway's Game of Life engine.

    Usage
    -----
        model = ConwayStreamingModel(width, height)
        model.initialize(initial_grid)
        for _ in range(total_cycles):
            model.clock(enable=pixel_valid)
            if model.out_valid:
                process(model.out_x, model.out_y, model.out_pixel)

    Output ports (updated each clock() call)
    -----------------------------------------
    out_valid  bool   – asserted when out_x/out_y/out_pixel carry valid data
    out_x      int    – column of the pixel being output
    out_y      int    – row    of the pixel being output
    out_pixel  int    – new cell state (0 or 1)
    frame_count int   – number of fully written frames completed so far
    """

    def __init__(self, width: int, height: int):
        assert width  % 3 == 0, "Width must be a multiple of 3"
        assert height % 3 == 0, "Height must be a multiple of 3"
        self.W = width
        self.H = height

        # Dual framebuffers — one read source, one write destination
        self.fb      = [BRAMArray(width, height), BRAMArray(width, height)]
        self.read_fb = 0
        self.write_fb = 1

        # Raster-scan counters — drive BRAM read address generation
        self.cx = 0
        self.cy = 0

        # Pipeline stage registers
        #   _s1 : (cx, cy)              – address issued last cycle (→ stage 0 reg)
        #   _s2 : (cx, cy, nbhd 3×3)   – neighbourhood data       (→ stage 1 reg)
        self._s1 = None
        self._s2 = None

        # Write-side bookkeeping
        self.write_count = 0
        self.frame_count = 0

        # Output ports
        self.out_valid = False
        self.out_x     = 0
        self.out_y     = 0
        self.out_pixel = 0

    # -----------------------------------------------------------------------
    # Clock function
    # -----------------------------------------------------------------------

    def clock(self, enable: bool = True):
        """
        Advance one clock cycle.

        enable=False  →  entire pipeline and all counters freeze.
        This models the backpressure a video controller applies during blanking.

        Pipeline behaviour with enable=True
        ------------------------------------
        Cycle N  : Counter (cx,cy) is registered into _s1.
                   BRAM addresses presented: (cx+dx)%W, (cy+dy)%H for all
                   nine (dx,dy) offsets.
        Cycle N+1: BRAM read data (neighbourhood) captured into _s2.
        Cycle N+2: Conway rule applied; result written to write framebuffer.
                   out_valid/out_x/out_y/out_pixel updated.
        """
        if not enable:
            self.out_valid = False
            return

        # Snapshot registers — all pipeline stages update in parallel at
        # the clock edge; save current values before overwriting.
        s1 = self._s1
        s2 = self._s2

        # ── Stage 1: compute Conway rule, write back ─────────────────────
        self.out_valid   = False
        frame_boundary   = False

        if s2 is not None:
            cx, cy, nbhd = s2
            val = _conway_rule(nbhd)
            self.fb[self.write_fb].write_pixel(cx, cy, val)

            self.out_valid  = True
            self.out_x      = cx
            self.out_y      = cy
            self.out_pixel  = val

            self.write_count += 1
            if self.write_count == self.W * self.H:
                self.write_count = 0
                self.read_fb, self.write_fb = self.write_fb, self.read_fb
                self.frame_count  += 1
                frame_boundary     = True

        # On a frame boundary: reset pipeline registers and raster counters.
        # In hardware this is accomplished by the vsync signal resetting the
        # raster counter and the blanking interval draining the pipeline.
        # Returning here prevents stale pipeline entries from being read by
        # the next frame's BRAM accesses.
        if frame_boundary:
            self._s1 = None
            self._s2 = None
            self.cx  = 0
            self.cy  = 0
            return

        # ── Stage 0→1: issue BRAM read, capture neighbourhood ────────────
        if s1 is not None:
            cx, cy   = s1
            nbhd     = self.fb[self.read_fb].read_neighbourhood(cx, cy)
            self._s2 = (cx, cy, nbhd)
        else:
            self._s2 = None

        # ── Counter → stage 0: register current address ──────────────────
        self._s1 = (self.cx, self.cy)

        # Advance raster-scan counters (horizontal then vertical)
        nx = self.cx + 1
        ny = self.cy
        if nx == self.W:
            nx  = 0
            ny += 1
            if ny == self.H:
                ny = 0
        self.cx, self.cy = nx, ny

    # -----------------------------------------------------------------------
    # Convenience drivers
    # -----------------------------------------------------------------------

    def run_frame(self, blanking_cycles: int = 0):
        """
        Drive exactly one complete frame through the pipeline.

        Active region: W×H + 2 cycles with enable=1.
          - 2 cycles to fill the pipeline (no output yet)
          - W×H cycles of valid pixel output
          - frame boundary resets pipeline and counters automatically
        Blanking region: blanking_cycles cycles with enable=0.
        """
        for _ in range(self.W * self.H + 2):
            self.clock(enable=True)
        for _ in range(blanking_cycles):
            self.clock(enable=False)

    def run_frames(self, n: int, blanking_cycles: int = 0):
        """Run n complete frames."""
        for _ in range(n):
            self.run_frame(blanking_cycles)

    # -----------------------------------------------------------------------
    # Frame accessors
    # -----------------------------------------------------------------------

    def get_display_frame(self) -> list:
        """
        Return the most recently completed frame as a 2-D list (row-major).
        After run_frame() this is read_fb — the last fully written result.
        """
        return self.fb[self.read_fb].dump()

    # -----------------------------------------------------------------------
    # Initialisation
    # -----------------------------------------------------------------------

    def initialize(self, grid):
        """
        Load an initial pattern into the read framebuffer.
        grid must be indexable as grid[y][x].
        """
        self.fb[self.read_fb].load(grid)

    # -----------------------------------------------------------------------
    # Reference implementation (for verification)
    # -----------------------------------------------------------------------

    @staticmethod
    def reference_step(grid: list) -> list:
        """Pure-Python Conway step without any pipelining or BRAMs."""
        H = len(grid)
        W = len(grid[0])
        def nbhd(cx, cy):
            return [[grid[(cy + dy) % H][(cx + dx) % W]
                     for dx in range(-1, 2)]
                    for dy in range(-1, 2)]
        return [[_conway_rule(nbhd(x, y)) for x in range(W)]
                for y in range(H)]


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def print_frame(frame, live: str = '█', dead: str = '·', indent: str = '  '):
    """Pretty-print a 2-D frame to stdout."""
    for row in frame:
        print(indent + ''.join(live if c else dead for c in row))


def make_glider(width: int, height: int, ox: int = 1, oy: int = 1) -> list:
    """
    Return a blank grid with a standard glider placed at offset (ox, oy).

    Glider shape (x→ right, y↓ down):
        . X .
        . . X
        X X X
    """
    grid = [[0] * width for _ in range(height)]
    for dx, dy in [(1, 0), (2, 1), (0, 2), (1, 2), (2, 2)]:
        grid[(oy + dy) % height][(ox + dx) % width] = 1
    return grid


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

def verify(width: int = 12, height: int = 12, n_frames: int = 10):
    """
    Run the streaming model for n_frames and compare every pixel of every
    frame against the pure-Python reference step.
    """
    print(f"Verifying {width}×{height} grid, {n_frames} frames …")
    initial = make_glider(width, height)
    model   = ConwayStreamingModel(width, height)
    model.initialize(initial)

    ref = initial
    for i in range(n_frames):
        model.run_frame(blanking_cycles=4)
        got = model.get_display_frame()
        ref = ConwayStreamingModel.reference_step(ref)
        mismatch = [(y, x) for y in range(height) for x in range(width)
                    if got[y][x] != ref[y][x]]
        if mismatch:
            raise AssertionError(
                f"Frame {i+1}: {len(mismatch)} pixel mismatches: {mismatch[:8]}")
        print(f"  frame {i+1:3d}  ✓")
    print("All frames match.\n")


# ---------------------------------------------------------------------------
# Demo
# ---------------------------------------------------------------------------

def demo(width: int = 12, height: int = 12, n_frames: int = 5,
         blanking: int = 4):
    model = ConwayStreamingModel(width, height)
    initial = make_glider(width, height)
    model.initialize(initial)

    print(f"Conway streaming model  {width}×{height}  "
          f"(blanking={blanking} cycles/frame)\n")
    print("Frame 0  [initial]:")
    print_frame(initial)
    print()

    for i in range(n_frames):
        model.run_frame(blanking_cycles=blanking)
        print(f"Frame {i + 1}:")
        print_frame(model.get_display_frame())
        print()


if __name__ == '__main__':
    verify()
    demo()

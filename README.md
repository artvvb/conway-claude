# Streaming Conway's Game of Life

A SystemVerilog implementation of Conway's Game of Life, streams 1 pixel per pixel-clock to a 640 x 480 VGA display, controlled over UART by a Python host. Targets the Digilent Basys 3 (Xilinx XC7A35T-1CPG236C).

**Important:** This prototype project has largely been generated using Claude code, as an experiment in digital hardware design through code generation tools. The git history is intended to reflect what has been added by hand and what hasn't - commits with a prompt in the extended commit description consist entirely of the output of that prompt, with some followups rejecting specific changes and prompting further edits, but no hand-written edits.

## Overview

The interesting part is the architecture, not the cellular automaton. To produce
one new pixel per pixel-clock cycle the engine has to read a 3 x 3 neighbourhood
in a single cycle, every cycle. A single block RAM only has two ports, so a
naive scheme can't service nine simultaneous reads.

Before attempting generation of SystemVerilog sources or testbenches, the
architecture was first modeled in `conway.py`, with prompts that indicated that
the code would eventually be used to generate a hardware design.

The trick used here, mirrored from `conway.py`, is a **3 x 3 bank of 1-bit
BRAMs per framebuffer**. Pixel `(x, y)` lives in `BRAM[x mod 3][y mod 3]` at
address `(y div 3) * W3 + (x div 3)`. Any 3 x 3 neighbourhood centred at
`(cx, cy)` covers nine pixels whose `(x mod 3, y mod 3)` tuples are exactly the
nine combinations of `{0, 1, 2} x {0, 1, 2}` -- so the reads hit each of the
nine BRAMs exactly once. Conflict-free single-cycle 9-pixel reads.

Other bits worth a look:

- **AXI-Stream backpressure** end-to-end: the VGA controller deasserts `tready`
  during blanking and the conway engine freezes its counters and pipeline
  exactly long enough to flush the last pixel into block RAM.
- **Cycle-accurate Python model** in [conway.py](conway.py) -- the SystemVerilog
  is a direct translation, including paired (mod3, div3) counters that avoid
  expensive modulus / division at run-time on the FPGA.
- **Single 25 MHz pixel-clock domain**: no clock-domain crossings anywhere.
  UART RX, command parser, engine, VGA controller -- all on one clock.
- **UART command protocol** with a Python loader and a tkinter GUI, so loading
  a pattern is one shell command (or a click).

The repo also includes source for two simpler test bitstreams (`vga_test`, `uart_rx_test`)
that were stepping stones to the final design and are still useful for bring-up.

## Command-line build

The build flow is a single Tcl script driven by Vivado in batch mode. It
takes the top-module name as a `tclargs` parameter; the file is expected at
`./<top>.sv` with a matching constraints file `./<top>.xdc`. Sub-module
sources are pulled in by `\`include` directives in the top file (this is why
the build only needs to attach one `.sv`).

```
vivado -mode batch -source ./build.tcl -tclargs conway_top
vivado -mode batch -source ./build.tcl -tclargs vga_test
vivado -mode batch -source ./build.tcl -tclargs uart_rx_test
```

Without arguments the default is `vga_test`. The script prints live progress
during synthesis and implementation:

```
[14:31:02]  launching synth_1
[14:31:18]  synth_1  20%   Running synth_design
[14:32:47]  synth_1  100%  synth_design Complete!
[14:32:47]  launching impl_1 (through write_bitstream)
[14:33:01]  impl_1   30%   Running place_design
...
[14:36:55]  bitstream: .../hw/conway_top/project_1.runs/impl_1/conway_top.bit
```

To program the board after a successful build:

```
vivado -mode batch -source ./prog.tcl -tclargs conway_top
```

## Running Conway from the command line

Once the board is programmed with `conway_top.bit` and the USB-UART bridge
shows up as a serial port (e.g. `COM3` on Windows - check the Device Manager),
`conway_load.py` is the front door:

```
python conway_load.py COM3
python conway_load.py COM3 -p glider-fleet --row 50 --col 50
python conway_load.py COM3 -p random --seed 42 --density 0.35
python conway_load.py COM3 -p pulsar --row 220 --col 310
```

Behind the scenes each invocation:

1. sends `'.'` to halt the engine,
2. sends `'R'` to zero both framebuffers,
3. encodes the chosen pattern as a `'W'` command and writes the sub-grid,
4. sends `'>'` to start free-running simulation.

Built-in patterns: `glider`, `blinker`, `block`, `beacon`, `toad`, `lwss`,
`r-pent`, `acorn`, `diehard`, `pulsar`, `gosper`, plus procedural ones
`glider-fleet`, `blinker-grid`, `block-grid`, `random`, and `stripes`. See
`--help` for tiling / random / position options.

Note: For lower-level control there's also `uart_write.py`, initially intended
for use with the uart_rx_test image, which sends raw 4-digit hex words at a prompt
and exits on `q`. Useful when developing or debugging the protocol.

## Running Conway from the GUI

`conway_gui.py` wraps the loader in a tkinter window so the form fields map
1:1 to `conway_load.py` flags:

```
python conway_gui.py
```

The GUI offers:

- **Connection** -- port combobox auto-populated from `pyserial.tools.list_ports`,
  baud entry, and a Refresh button.
- **Pattern** -- dropdown of every pattern, plus row / col entries.
- **Tiled options** -- repeat / spacing for the `*-fleet` and `*-grid`
  patterns.
- **Random / Stripes options** -- width, height, density, seed, period.
- **Behaviour** -- "Reset before write" and "Start after write" checkboxes
  (unchecking maps to `--no-reset` / `--no-start`).
- **Action buttons** -- `Load pattern` runs the loader; the four shortcut
  buttons next to it (`>`, `.`, `-`, `R`) bypass the loader and write a
  single byte directly via pyserial. `-` (step one frame) is the most useful
  shortcut once a pattern is running.
- **Output pane** -- streams stdout/stderr of every loader invocation, with
  the equivalent shell command echoed first for copy/paste reproducibility.

The loader runs in a background thread so the GUI stays responsive during
the larger random fills (which can take a few seconds at 115 200 baud).

If you need behaviour the GUI doesn't expose -- arbitrary `W` payloads,
custom patterns drawn in code, scripted sequences -- drop down to
`conway_load.py` or `uart_write.py`.

## Secondary test bitstreams

These two were built first as bring-up vehicles for the VGA and UART halves
of the design, but are still useful when something seems off and you need to
isolate a layer.

### vga_test

Builds with `vivado -mode batch -source ./build.tcl -tclargs vga_test`. After
programming, the monitor shows one of four test patterns:

- SW[1:0] = `00`: SMPTE colour bars (8 vertical stripes, 80 px wide).
- SW[1:0] = `01`: 64 x 64 px checkerboard.
- SW[1:0] = `10`: RGB gradient (R from column, G from row, B from XOR).
- SW[1:0] = `11`: white crosshatch on black, 80 x 64 px cells.

Output is black until BTNC is pressed; BTNC toggles between IDLE (black) and
RUN (pattern). LEDs reflect state: LD0 = idle, LD1 = run, LD3:2 = active
pattern, LD7:4 = a frame counter at ~4 Hz, LD8 = MMCM locked.

This is the right bitstream to confirm the cable, the monitor, and the
25 MHz pixel clock are all behaving before troubleshooting Conway.

### uart_rx_test

Builds with `tclargs uart_rx_test`. After programming, send hex characters
into the serial port (e.g. through `uart_write.py` or any terminal at
115 200 8N1) and watch them shift into the 16 LEDs as 4-bit nibbles:

```
python uart_write.py COM3
> 1234
Sent: 1234
```

LEDs LD15..LD0 should now read `0001 0010 0011 0100`. BTNC clears the LEDs
back to zero. Non-hex characters are silently dropped (they're flagged as
invalid by `hex_decode` and ignored by the shifter). Confirms that the UART
receiver, hex decoder, and full byte handshake work end-to-end.

## Architecture

### Top-level wiring

`conway_top.sv` ties the protocol stack to the engine to the display. Every
block runs on the same 25 MHz pixel clock derived from the board's 100 MHz
oscillator via an `MMCME2_BASE`, so there are no clock-domain crossings to
manage.

```
                 100 MHz osc
                      |
                  MMCME2_BASE        (BTNC) ----+
                      |                          v
                  25 MHz pix_clk           reset sync
                      |                          |
                      +----------- + ---------- rst_n
                                   |
   rxd  -->  uart_rx  -->  hex_decode  --(byte)--+
                                |   '------(nibble + invalid)--+
                                |                              |
                                |   tready / tvalid (shared)   |
                                |                              v
                                |                         uart_cmd
                                |                          |   ^
                                |              prog_*      |   |  run, frame_done
                                |              (we, x,     |   |  frame_start
                                |               y, data)   v   |
                                |                       conway -+----------> vga_controller -> VGA
                                |                          ^                          |
                                |                          |  tready / tvalid          v
                                +--------------------------+                       Hsync, Vsync
```

The `conway` engine outputs a 1-bit pixel; `conway_top` expands `1 -> 12'hFFF`
and `0 -> 12'h000` before feeding the VGA controller.

### BRAM banking and the conflict-free 9-pixel read

Each framebuffer is a 3 x 3 array of 1-bit BRAMs (`bram.sv`, depth
`W3 * H3 = 214 * 160 = 34 240`). The mapping is:

```
   pixel (x, y)
       |
       v
   BRAM[ x mod 3 ][ y mod 3 ]   at addr   (y div 3) * W3  +  (x div 3)
```

A 3 x 3 neighbourhood centred at `(cx, cy)` reads pixels at the nine offsets
`(cx + dx, cy + dy)` for `dx, dy in {-1, 0, +1}`. The (mod 3) coordinates of
those nine pixels are exactly the nine combinations of `{cx-1, cx, cx+1} mod 3`
(distinct) crossed with `{cy-1, cy, cy+1} mod 3` -- so the nine reads land on
nine different BRAMs. One read per BRAM per cycle. No port conflicts.

Sketch (showing just the x dimension; cx mod 3 = 1 here):

```
   address  ...  cx_d3-1  cx_d3   cx_d3+1  ...
                 +---+    +---+    +---+
   BRAM[0]       |   |    |   |    |   |     -- holds x = 0, 3, 6, ...
                 +---+    +---+    +---+
                          ^
                          | (cx-1) -> dx = -1
                 +---+    +---+    +---+
   BRAM[1]       |   |    | * |    |   |     -- holds x = 1, 4, 7, ...   (cx itself)
                 +---+    +---+    +---+
                          ^
                          | (cx)   -> dx = 0
                 +---+    +---+    +---+
   BRAM[2]       |   |    |   |    |   |     -- holds x = 2, 5, 8, ...
                 +---+    +---+    +---+
                                   ^
                                   | (cx+1) -> dx = +1
```

`(cx mod 3, cy mod 3)` rotates the responsibility for "which BRAM holds the
centre, the left, the right, the up-left, etc." across all 9 cells of the
neighbourhood; a small lookup (`delta_lut` in `conway.sv`) recovers the
`(dx, dy)` offset each BRAM is currently servicing.

The original `conway.py` uses toroidal wrap, which forces `W mod 3 == H mod 3
== 0` to keep the wrap-point neighbours in distinct mod-3 banks. The HW uses
**bounded edges** (off-grid neighbours contribute 0) which removes the
divisibility constraint, so 640 x 480 -- where 640 isn't a multiple of 3 --
just works. `W3 = ceil(W / 3)` and a per-BRAM `oob_mask` registered alongside
the data implements this.

### Pipeline

Each engine cycle is two stages, separated by the BRAM's synchronous read
register:

```
   cycle N             cycle N+1
   ---------------     ----------------
   counters cx, cy     bram_rdata[bx][by]
        |                    |
        v                    v
   r_addr[bx][by]   ---->  nbhd[r][c]  (combinational unscramble)
   oob_mask[bx][by]              |
        |                         v
   present to BRAMs          live_count, centre_alive
                                  |
                                  v
                               next_state
                                  |
                                  v   write to write_fb
                              eng_w_*  (cx_s1, cy_s1)
```

`(cx_s1, cy_s1)` is the registered version of the counters that travels with
the data through the BRAM; it's used both to address the write port and to
detect the last pixel of the frame for the framebuffer swap.

### Backpressure and frame synchronisation

The VGA controller asserts `tready = active` (high during the 640 x 480 active
region) and emits `frame_start` for one cycle in the very last blanking
position. The conway engine treats them as:

- `tready = 1`: counters and pipeline-valid advance, BRAMs read/write.
- `tready = 0`: counters and pipeline-valid hold (with a one-cycle drain so
  the final pixel `(W-1, H-1)` -- which the BRAM read latency pushes into
  the first blanking cycle -- still gets written exactly once).
- `frame_start = 1`: counters and pipeline-valid clear synchronously.

This way the engine produces exactly W * H pixels per VGA frame, the
framebuffers swap on the right edge, and 25 MHz is the only clock anywhere
in the design.

### Programming path

`uart_cmd.sv` is a small FSM that consumes the byte stream from `uart_rx`
(plus the parallel hex-decoded nibble stream from `hex_decode`):

```
            byte stream                  nibble + invalid stream
                |                                |
                v                                v
            +--------+      'W' header     +-----------+
            |        |---hex chars (16)--->|  W_PARAMS |
            |  IDLE  |                     +-----+-----+
            |        |    'R'                    |
            |        |---->[ R_SWEEP ]<----------+
            |        |    '-'                    |  W_FETCH /
            |        |---->[ STEP_WAIT_FS / FD ]   W_WRITE  (4 cycles/nibble)
            |        |    '>' / '.'  -> run_mode
            +--------+
```

`W` is followed by four 4-hex-char parameters (`count`, `start_row`,
`start_col`, `width`) then `count` payload nibbles. Each nibble's four bits
march MSB-first across consecutive pixels of the sub-grid, wrapping to the
next row when `width` columns are filled. While `prog_mode` is asserted the
engine pipeline is disabled and the prog interface writes **both**
framebuffers in lock-step so the simulation starts from a consistent state.

## Known issues and future work

**One-pixel raster offset.** The pipeline's one-cycle BRAM-read latency means
the first valid pixel of each frame appears on the second cycle of the active
region, not the first. The leftmost column of each scan line displays whatever
`tdata` was when `tvalid` first dropped (`tvalid` is gated to 0 here, so
`vga_controller` paints black). It's a single pixel; visually invisible at
640 x 480 unless you're hunting for it. Could be fixed by driving BRAM
addresses from the *next* counter value instead of the current one, or by
running the pipeline one extra cycle into back-porch.

**No toroidal wrap.** The bounded-edge implementation diverges from
`conway.py`'s reference toroidal wrap. Patterns that cross the screen edge
will die / glitch differently than the Python model would predict. Restoring
toroidal wrap requires either constraining `W` and `H` to be multiples of 3
(loses the 640 x 480 default) or a more elaborate banking scheme that
handles the wrap-point bank conflict.

**Slow pattern loading.** The `W` command writes one pixel per ~10 us
(115 200 baud, one nibble = four pixels per ~350 us). A full-screen random
fill takes ~3 seconds. For larger patterns this dominates user-perceived
latency. A fix would be a higher baud rate plus a small write FIFO, or
moving programming to a binary protocol.

**Fixed display palette.** Live cells are white, dead cells black. There's
no per-cell colour, age tracking, or trail effect. A second 12-bit
"colour-by-state" lookup before the VGA expansion in `conway_top.sv` would
add minimal logic.

**No on-board pattern generator.** Every pattern is loaded over UART. A
small ROM of canned patterns indexed by switches, or an LFSR for noise
fills, would make the board self-contained.

**Single 25 MHz domain caps engine throughput.** The engine produces one
pixel per VGA active cycle (~14 M pixels/s effective after blanking). Adding
a faster engine clock with an asynchronous FIFO between the engine and
`vga_controller` would let multi-step-per-frame ("speed up") modes work.
The tradeoff is a CDC the design currently avoids.

**No simulation harness in the repo.** The Python model is cycle-accurate
and self-verifying (`python conway.py` runs the verification loop), but the
SystemVerilog has no formal testbench. A cocotb or open-source-Verilator
testbench cross-checked against `conway.py` would close the loop.

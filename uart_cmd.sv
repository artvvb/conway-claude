// uart_cmd.sv -- Command parser driving the conway engine over UART.
//
// Inputs come pre-decoded: the raw byte from uart_rx and the hex-decoded
// nibble from hex_decode share one tvalid/tready handshake (hex_decode is
// purely combinational, so they always fire together).  The byte stream is
// used to identify command bytes; the nibble stream is used for hex payload.
//
// Command set
//   'W'  Write a sub-grid of the framebuffers.  Followed by:
//          (4 hex chars)  count          number of payload nibbles    (16 bits)
//          (4 hex chars)  start_row      top-left row    of target region
//          (4 hex chars)  start_col      top-left column of target region
//          (4 hex chars)  width          width  (in pixels) of target region
//          (count chars)  payload        hex nibbles, packed MSB-first into
//                                        pixels of the sub-grid in row-major
//                                        order.  After every `width` pixels
//                                        the column resets to 0 and the row
//                                        advances by one (mid-nibble row
//                                        wraps are allowed).
//   'R'  Reset both framebuffers to all zeros.  Also forces run = 0.
//   '-'  Advance exactly one frame (waits for frame_start, asserts run for
//        one full frame, deasserts on frame_done).
//   '>'  Start free-running simulation (sets run = 1).
//   '.'  Stop simulation (sets run = 0).
//   any other byte: ignored in IDLE.
//
// Aborts
//   Any non-hex character received during W params or W payload returns the
//   parser to IDLE.
//
// Backpressure
//   tready is high in IDLE / W_PARAMS / W_FETCH (when more payload remains),
//   low everywhere else.  This naturally stalls the byte stream while the
//   FSM is busy writing pixels or running the simulation.

`timescale 1ns / 1ps
`default_nettype none

module uart_cmd #(
    parameter int W   = 640,
    parameter int H   = 480,
    parameter int X_W = $clog2(W),
    parameter int Y_W = $clog2(H)
) (
    input  wire             clk,
    input  wire             rst_n,

    // Byte stream from uart_rx (raw 8-bit ASCII)
    input  wire [7:0]       s_axis_byte_tdata,
    // Hex-decoded nibble + invalid flag (parallel to byte stream)
    input  wire [3:0]       s_axis_nibble_tdata,
    input  wire             s_axis_nibble_tuser,    // 1 = byte was not a hex digit
    input  wire             s_axis_tvalid,
    output logic            s_axis_tready,

    // Engine control
    output logic            run,
    input  wire             frame_done,
    input  wire             frame_start,

    // Programming interface (to conway)
    output logic            prog_mode,
    output logic            prog_we,
    output logic [X_W-1:0]  prog_x,
    output logic [Y_W-1:0]  prog_y,
    output logic            prog_data
);

    typedef enum logic [2:0] {
        IDLE         = 3'd0,
        W_PARAMS     = 3'd1,    // collect 16 hex chars of params
        W_FETCH      = 3'd2,    // wait for next payload nibble
        W_WRITE      = 3'd3,    // emit 4 prog_we pulses for current nibble
        R_SWEEP      = 3'd4,    // zero every pixel
        STEP_WAIT_FS = 3'd5,    // wait for frame_start
        STEP_WAIT_FD = 3'd6     // run=1, wait for frame_done
    } state_t;

    state_t state;
    logic   run_mode;           // sticky run flag set by '>' / cleared by '.', '-', 'R'

    // Param parsing
    logic [15:0] sr;            // 16-bit hex shift register
    logic [1:0]  sr_chars;      // 0..3 chars within current param
    logic [1:0]  param_idx;     // 0..3 which param

    logic [15:0] count;
    logic [15:0] start_row;
    logic [15:0] start_col;
    logic [15:0] width;         // sub-grid width, in pixels (row stride)

    // Payload tracking
    logic [15:0] payload_left;
    logic [3:0]  curr_nibble;
    logic [1:0]  bit_idx;       // counts down 3 -> 0  (MSB first)
    logic [15:0] pix_row;       // row offset within sub-grid
    logic [15:0] pix_col;       // column offset within sub-grid

    // Reset sweep tracking
    logic [X_W-1:0] sweep_x;
    logic [Y_W-1:0] sweep_y;

    // -------------------------------------------------------------------------
    // Combinational outputs
    // -------------------------------------------------------------------------
    always_comb begin
        s_axis_tready = 1'b0;
        prog_mode     = 1'b0;
        prog_we       = 1'b0;
        prog_x        = '0;
        prog_y        = '0;
        prog_data     = 1'b0;
        run           = run_mode | (state == STEP_WAIT_FD);

        unique case (state)
            IDLE:         s_axis_tready = 1'b1;
            W_PARAMS:     s_axis_tready = 1'b1;
            W_FETCH:      s_axis_tready = (payload_left != '0);

            W_WRITE: begin
                prog_mode = 1'b1;
                prog_we   = 1'b1;
                prog_x    = X_W'(start_col + pix_col);
                prog_y    = Y_W'(start_row + pix_row);
                prog_data = curr_nibble[bit_idx];
            end

            R_SWEEP: begin
                prog_mode = 1'b1;
                prog_we   = 1'b1;
                prog_x    = sweep_x;
                prog_y    = sweep_y;
                prog_data = 1'b0;
            end

            default: ;          // STEP_WAIT_FS / STEP_WAIT_FD
        endcase
    end

    // -------------------------------------------------------------------------
    // Sequential FSM
    // -------------------------------------------------------------------------
    wire byte_handshake = s_axis_tvalid & s_axis_tready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            run_mode      <= 1'b0;
            sr            <= '0;
            sr_chars      <= '0;
            param_idx     <= '0;
            count         <= '0;
            start_row     <= '0;
            start_col     <= '0;
            width         <= '0;
            payload_left  <= '0;
            curr_nibble   <= '0;
            bit_idx       <= '0;
            pix_row       <= '0;
            pix_col       <= '0;
            sweep_x       <= '0;
            sweep_y       <= '0;
        end else begin
            unique case (state)

                // -------------------------------------------------------------
                IDLE: begin
                    if (byte_handshake) begin
                        unique case (s_axis_byte_tdata)
                            "W": begin
                                state     <= W_PARAMS;
                                sr        <= '0;
                                sr_chars  <= '0;
                                param_idx <= '0;
                            end
                            "R": begin
                                state    <= R_SWEEP;
                                sweep_x  <= '0;
                                sweep_y  <= '0;
                                run_mode <= 1'b0;
                            end
                            "-": begin
                                state    <= STEP_WAIT_FS;
                                run_mode <= 1'b0;
                            end
                            ">": run_mode <= 1'b1;
                            ".": run_mode <= 1'b0;
                            default: ;          // ignore
                        endcase
                    end
                end

                // -------------------------------------------------------------
                W_PARAMS: begin
                    if (byte_handshake) begin
                        if (s_axis_nibble_tuser) begin
                            state <= IDLE;      // abort on non-hex
                        end else begin
                            sr       <= {sr[11:0], s_axis_nibble_tdata};
                            sr_chars <= sr_chars + 1'b1;
                            if (sr_chars == 2'd3) begin
                                // 4th char of this param: latch into target reg
                                sr_chars <= '0;
                                unique case (param_idx)
                                    2'd0: count     <= {sr[11:0], s_axis_nibble_tdata};
                                    2'd1: start_row <= {sr[11:0], s_axis_nibble_tdata};
                                    2'd2: start_col <= {sr[11:0], s_axis_nibble_tdata};
                                    2'd3: width     <= {sr[11:0], s_axis_nibble_tdata};
                                endcase
                                if (param_idx == 2'd3) begin
                                    payload_left <= count;
                                    pix_row      <= '0;
                                    pix_col      <= '0;
                                    state        <= W_FETCH;
                                end else begin
                                    param_idx <= param_idx + 1'b1;
                                end
                            end
                        end
                    end
                end

                // -------------------------------------------------------------
                W_FETCH: begin
                    if (payload_left == '0) begin
                        state <= IDLE;
                    end else if (byte_handshake) begin
                        if (s_axis_nibble_tuser) begin
                            state <= IDLE;
                        end else begin
                            curr_nibble <= s_axis_nibble_tdata;
                            bit_idx     <= 2'd3;
                            state       <= W_WRITE;
                        end
                    end
                end

                // -------------------------------------------------------------
                W_WRITE: begin
                    // Row-major scan within the sub-grid: advance column,
                    // wrap to next row after `width` columns.
                    if (pix_col + 16'd1 == width) begin
                        pix_col <= '0;
                        pix_row <= pix_row + 16'd1;
                    end else begin
                        pix_col <= pix_col + 16'd1;
                    end

                    if (bit_idx == 2'd0) begin
                        payload_left <= payload_left - 16'd1;
                        if (payload_left == 16'd1)
                            state <= IDLE;          // just wrote last bit of last nibble
                        else
                            state <= W_FETCH;
                    end else begin
                        bit_idx <= bit_idx - 1'b1;
                    end
                end

                // -------------------------------------------------------------
                R_SWEEP: begin
                    if (sweep_x == X_W'(W - 1)) begin
                        sweep_x <= '0;
                        if (sweep_y == Y_W'(H - 1)) begin
                            state <= IDLE;
                        end else begin
                            sweep_y <= sweep_y + 1'b1;
                        end
                    end else begin
                        sweep_x <= sweep_x + 1'b1;
                    end
                end

                // -------------------------------------------------------------
                STEP_WAIT_FS: begin
                    if (frame_start) state <= STEP_WAIT_FD;
                end

                // -------------------------------------------------------------
                STEP_WAIT_FD: begin
                    if (frame_done) state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire

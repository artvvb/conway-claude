// hex-decode.sv — AXI-Stream ASCII → 4-bit hex nibble decoder
//
// Purely combinational passthrough.  tvalid and tready are forwarded
// unchanged; the only transformation is the data decode.
//
// Encoding:
//   '0'–'9'  (0x30–0x39): nibble = tdata[3:0]        (lower nybble of ASCII digit)
//   'A'–'F'  (0x41–0x46): nibble = tdata[3:0] + 4'd9  (A→1+9=10, …, F→6+9=15)
//   'a'–'f'  (0x61–0x66): nibble = tdata[3:0] + 4'd9  (same lower 4 bits as upper)
//   anything else: m_axis_tuser = 1 (invalid), m_axis_tdata = 4'd0
//
// tuser is registered separately if the consumer needs it synchronously;
// here it is combinational alongside tdata.

`timescale 1ns / 1ps
`default_nettype none

module hex_decode (
    // Slave — raw ASCII byte
    input  wire [7:0] s_axis_tdata,
    input  wire       s_axis_tvalid,
    output wire       s_axis_tready,

    // Master — 4-bit nibble
    output wire [3:0] m_axis_tdata,
    output wire       m_axis_tvalid,
    output wire       m_axis_tuser,   // 1 = character was not a valid hex digit
    input  wire       m_axis_tready
);

    // Flow-through: no buffering
    assign s_axis_tready = m_axis_tready;
    assign m_axis_tvalid = s_axis_tvalid;

    // Character classification
    wire is_digit = (s_axis_tdata >= 8'h30) && (s_axis_tdata <= 8'h39);   // '0'–'9'
    wire is_upper = (s_axis_tdata >= 8'h41) && (s_axis_tdata <= 8'h46);   // 'A'–'F'
    wire is_lower = (s_axis_tdata >= 8'h61) && (s_axis_tdata <= 8'h66);   // 'a'–'f'

    assign m_axis_tuser = ~(is_digit | is_upper | is_lower);

    assign m_axis_tdata = is_digit              ? s_axis_tdata[3:0] :
                          (is_upper | is_lower) ? (s_axis_tdata[3:0] + 4'd9) :
                                                   4'd0;

endmodule

`default_nettype wire

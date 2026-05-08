#!/usr/bin/env python3
"""Send 16-bit hex values to the Basys 3 UART LED demo over a serial port.

Usage:
    python uart-write.py <COM_PORT>

Each prompt accepts a decimal integer in the range 0–65535.  The value is
converted to a 4-digit uppercase hex string and transmitted at 115200 baud.
Type 'q' (or press Ctrl-D / Ctrl-Z) to exit.
"""

import sys
import serial


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: uart-write.py <COM_PORT>", file=sys.stderr)
        sys.exit(1)

    port = sys.argv[1]

    try:
        ser = serial.Serial(port, baudrate=115200, timeout=1)
    except serial.SerialException as exc:
        print(f"Error opening {port}: {exc}", file=sys.stderr)
        sys.exit(1)

    with ser:
        print(f"Connected to {port} at 115200 baud.")
        print("Enter a 16-bit decimal value (0–65535) or 'q' to quit.\n")

        while True:
            try:
                line = input("> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break

            if line.lower() == "q":
                break

            try:
                value = int(line)
            except ValueError:
                print("  Invalid input — enter a decimal integer or 'q'.")
                continue

            if not (0 <= value <= 65535):
                print("  Out of range — value must be 0–65535.")
                continue

            hex_str = f"{value:04X}"
            ser.write(hex_str.encode("ascii"))
            print(f"  Sent: {hex_str}")


if __name__ == "__main__":
    main()

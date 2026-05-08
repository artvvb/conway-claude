#!/usr/bin/env python3
"""conway_gui.py -- Tkinter wrapper around conway_load.py.

Builds a command line for conway_load.py from the form fields, runs it in a
subprocess, and streams stdout into the log pane.  Also offers single-byte
shortcut buttons (start / stop / step / reset) that talk to the FPGA via
pyserial directly without invoking the loader.
"""

import os
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import ttk, scrolledtext


# Optional dependency: only used for port enumeration and the shortcut buttons.
try:
    import serial
    from serial.tools import list_ports
except ImportError:
    serial = None
    list_ports = None


SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
LOAD_SCRIPT = os.path.join(SCRIPT_DIR, "conway_load.py")

PATTERNS = [
    "gosper", "glider", "blinker", "block", "beacon", "toad", "lwss",
    "r-pent", "acorn", "diehard", "pulsar",
    "glider-fleet", "blinker-grid", "block-grid",
    "random", "stripes",
]


def detect_ports():
    if list_ports is None:
        return []
    return [p.device for p in list_ports.comports()]


class ConwayGui:
    def __init__(self, root):
        root.title("Conway Pattern Loader")
        root.geometry("760x640")
        self.root = root

        main = ttk.Frame(root, padding=8)
        main.pack(fill="both", expand=True)

        self._build_connection(main)
        self._build_pattern(main)
        self._build_tiled(main)
        self._build_random(main)
        self._build_behaviour(main)
        self._build_actions(main)
        self._build_log(main)

    # ------------------------------------------------------------------
    # Frame builders
    # ------------------------------------------------------------------
    def _build_connection(self, parent):
        f = ttk.LabelFrame(parent, text="Connection", padding=6)
        f.pack(fill="x", pady=2)

        ports = detect_ports()
        self.port_var = tk.StringVar(value=ports[0] if ports else "COM3")
        ttk.Label(f, text="Port:").grid(row=0, column=0, sticky="w", padx=2)
        self.port_combo = ttk.Combobox(f, textvariable=self.port_var,
                                       values=ports, width=14)
        self.port_combo.grid(row=0, column=1, sticky="w", padx=2)

        ttk.Button(f, text="Refresh", command=self._refresh_ports
                   ).grid(row=0, column=2, padx=4)

        ttk.Label(f, text="Baud:").grid(row=0, column=3, sticky="w", padx=8)
        self.baud_var = tk.StringVar(value="115200")
        ttk.Entry(f, textvariable=self.baud_var, width=10
                  ).grid(row=0, column=4, sticky="w", padx=2)

    def _build_pattern(self, parent):
        f = ttk.LabelFrame(parent, text="Pattern", padding=6)
        f.pack(fill="x", pady=2)

        ttk.Label(f, text="Pattern:").grid(row=0, column=0, sticky="w", padx=2)
        self.pattern_var = tk.StringVar(value="gosper")
        ttk.Combobox(f, textvariable=self.pattern_var, values=PATTERNS,
                     width=16).grid(row=0, column=1, sticky="w", padx=2)

        ttk.Label(f, text="Row:").grid(row=0, column=2, sticky="w", padx=8)
        self.row_var = tk.StringVar(value="200")
        ttk.Entry(f, textvariable=self.row_var, width=8
                  ).grid(row=0, column=3, sticky="w", padx=2)

        ttk.Label(f, text="Col:").grid(row=0, column=4, sticky="w", padx=8)
        self.col_var = tk.StringVar(value="300")
        ttk.Entry(f, textvariable=self.col_var, width=8
                  ).grid(row=0, column=5, sticky="w", padx=2)

    def _build_tiled(self, parent):
        f = ttk.LabelFrame(parent,
                           text="Tiled options (glider-fleet / blinker-grid / block-grid)",
                           padding=6)
        f.pack(fill="x", pady=2)

        ttk.Label(f, text="Repeat:").grid(row=0, column=0, sticky="w", padx=2)
        self.repeat_var = tk.StringVar(value="10")
        ttk.Entry(f, textvariable=self.repeat_var, width=8
                  ).grid(row=0, column=1, sticky="w", padx=2)

        ttk.Label(f, text="Spacing:").grid(row=0, column=2, sticky="w", padx=8)
        self.spacing_var = tk.StringVar(value="8")
        ttk.Entry(f, textvariable=self.spacing_var, width=8
                  ).grid(row=0, column=3, sticky="w", padx=2)

    def _build_random(self, parent):
        f = ttk.LabelFrame(parent, text="Random / Stripes options", padding=6)
        f.pack(fill="x", pady=2)

        ttk.Label(f, text="Width:").grid(row=0, column=0, sticky="w", padx=2)
        self.rand_w_var = tk.StringVar(value="200")
        ttk.Entry(f, textvariable=self.rand_w_var, width=8
                  ).grid(row=0, column=1, sticky="w", padx=2)

        ttk.Label(f, text="Height:").grid(row=0, column=2, sticky="w", padx=8)
        self.rand_h_var = tk.StringVar(value="150")
        ttk.Entry(f, textvariable=self.rand_h_var, width=8
                  ).grid(row=0, column=3, sticky="w", padx=2)

        ttk.Label(f, text="Density (random):").grid(row=1, column=0,
                                                    sticky="w", padx=2)
        self.density_var = tk.StringVar(value="0.3")
        ttk.Entry(f, textvariable=self.density_var, width=8
                  ).grid(row=1, column=1, sticky="w", padx=2)

        ttk.Label(f, text="Seed (random):").grid(row=1, column=2,
                                                  sticky="w", padx=8)
        self.seed_var = tk.StringVar(value="")
        ttk.Entry(f, textvariable=self.seed_var, width=8
                  ).grid(row=1, column=3, sticky="w", padx=2)

        ttk.Label(f, text="Period (stripes):").grid(row=2, column=0,
                                                    sticky="w", padx=2)
        self.period_var = tk.StringVar(value="4")
        ttk.Entry(f, textvariable=self.period_var, width=8
                  ).grid(row=2, column=1, sticky="w", padx=2)

    def _build_behaviour(self, parent):
        f = ttk.LabelFrame(parent, text="Behaviour", padding=6)
        f.pack(fill="x", pady=2)

        self.reset_var = tk.BooleanVar(value=True)
        self.start_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(f, text="Reset framebuffer ('R') before write",
                        variable=self.reset_var
                        ).grid(row=0, column=0, sticky="w", padx=2)
        ttk.Checkbutton(f, text="Start engine ('>') after write",
                        variable=self.start_var
                        ).grid(row=0, column=1, sticky="w", padx=10)

    def _build_actions(self, parent):
        f = ttk.Frame(parent)
        f.pack(fill="x", pady=4)

        self.load_btn = ttk.Button(f, text="Load pattern", command=self._on_load)
        self.load_btn.pack(side="left", padx=2)

        ttk.Separator(f, orient="vertical").pack(side="left", fill="y", padx=6)

        ttk.Button(f, text="Start  ('>')",
                   command=lambda: self._send_byte(b">")).pack(side="left", padx=2)
        ttk.Button(f, text="Stop  ('.')",
                   command=lambda: self._send_byte(b".")).pack(side="left", padx=2)
        ttk.Button(f, text="Step  ('-')",
                   command=lambda: self._send_byte(b"-")).pack(side="left", padx=2)
        ttk.Button(f, text="Reset ('R')",
                   command=lambda: self._send_byte(b"R")).pack(side="left", padx=2)

        ttk.Button(f, text="Clear log", command=self._clear_log
                   ).pack(side="right", padx=2)

    def _build_log(self, parent):
        f = ttk.LabelFrame(parent, text="Output", padding=6)
        f.pack(fill="both", expand=True, pady=2)
        self.log = scrolledtext.ScrolledText(f, height=14,
                                             font=("Consolas", 9))
        self.log.pack(fill="both", expand=True)

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
    def _refresh_ports(self):
        ports = detect_ports()
        self.port_combo["values"] = ports
        if ports and self.port_var.get() not in ports:
            self.port_var.set(ports[0])
        self._log(f"detected {len(ports)} port(s): {', '.join(ports) or '<none>'}\n")

    def _log(self, text):
        self.log.insert("end", text)
        self.log.see("end")

    def _clear_log(self):
        self.log.delete("1.0", "end")

    def _build_args(self):
        port = self.port_var.get().strip()
        if not port:
            raise ValueError("port is empty")
        args = [
            sys.executable, LOAD_SCRIPT,
            port,
            "-p",        self.pattern_var.get(),
            "--row",     self.row_var.get(),
            "--col",     self.col_var.get(),
            "--baud",    self.baud_var.get(),
            "--rand-w",  self.rand_w_var.get(),
            "--rand-h",  self.rand_h_var.get(),
            "--density", self.density_var.get(),
            "--period",  self.period_var.get(),
            "--repeat",  self.repeat_var.get(),
            "--spacing", self.spacing_var.get(),
        ]
        seed = self.seed_var.get().strip()
        if seed:
            args.extend(["--seed", seed])
        if not self.reset_var.get():
            args.append("--no-reset")
        if not self.start_var.get():
            args.append("--no-start")
        return args

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------
    def _on_load(self):
        try:
            args = self._build_args()
        except Exception as exc:
            self._log(f"error: {exc}\n")
            return

        # Show the equivalent CLI for copy/paste / debugging.
        self._log("\n$ " + " ".join(_quote(a) for a in args[1:]) + "\n")

        self.load_btn.config(state="disabled")
        threading.Thread(target=self._run_subprocess, args=(args,),
                         daemon=True).start()

    def _run_subprocess(self, args):
        try:
            proc = subprocess.Popen(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            for line in proc.stdout:
                self.root.after(0, self._log, line)
            proc.wait()
            self.root.after(0, self._log, f"[exit {proc.returncode}]\n")
        except Exception as exc:
            self.root.after(0, self._log, f"error: {exc}\n")
        finally:
            self.root.after(0, lambda: self.load_btn.config(state="normal"))

    def _send_byte(self, byte):
        if serial is None:
            self._log("error: pyserial not installed\n")
            return
        port = self.port_var.get().strip()
        if not port:
            self._log("error: no port\n")
            return
        try:
            baud = int(self.baud_var.get())
        except ValueError:
            self._log("error: bad baud\n")
            return
        try:
            with serial.Serial(port, baud, timeout=1) as ser:
                ser.write(byte)
                ser.flush()
            self._log(f"sent {byte!r} to {port}\n")
        except Exception as exc:
            self._log(f"error: {exc}\n")


def _quote(s):
    """Minimal shell-style quoting for the CLI echo."""
    if any(c in s for c in ' \t"\''):
        return '"' + s.replace('"', '\\"') + '"'
    return s


def main():
    root = tk.Tk()
    ConwayGui(root)
    root.mainloop()


if __name__ == "__main__":
    main()

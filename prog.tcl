# Invoke with "vivado -mode batch -source ./prog.tcl"

set script_dir [file dirname [file normalize [info script]]]
set top_module {vga_test}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

current_hw_device [get_hw_devices xc7a35t_0]
refresh_hw_device -update_hw_probes false [lindex [get_hw_devices xc7a35t_0] 0]
set_property PROBES.FILE {} [get_hw_devices xc7a35t_0]
set_property FULL_PROBES.FILE {} [get_hw_devices xc7a35t_0]
set_property PROGRAM.FILE ${script_dir}/hw/${top_module}/project_1.runs/impl_1/${top_module}.bit [get_hw_devices xc7a35t_0]
program_hw_devices [get_hw_devices xc7a35t_0]
refresh_hw_device [lindex [get_hw_devices xc7a35t_0] 0]

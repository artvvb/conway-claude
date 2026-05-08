# Invoke with "vivado -mode batch -source ./build.tcl -tclargs <top_module>"
# If no top_module is supplied, defaults to vga_test.

set script_dir [file dirname [file normalize [info script]]]
if {$argc >= 1} {
    set top_module [lindex $argv 0]
} else {
    set top_module {vga_test}
}
puts "build.tcl: top_module = ${top_module}"

if {[file exists ${script_dir}/hw] == 0} {file mkdir ${script_dir}/hw}

set_param board.repoPaths {C:/Users/Artvv/OneDrive/Documents/GitHub/vivado-boards}

create_project project_1 ${script_dir}/hw/${top_module} -force -part xc7a35tcpg236-1
set_property board_part digilentinc.com:basys3:part0:1.2 [current_project]
add_files ${script_dir}/${top_module}.sv
update_compile_order -fileset sources_1
add_files -fileset constrs_1 -norecurse ${script_dir}/${top_module}.xdc
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

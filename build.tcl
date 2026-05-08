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

# ----------------------------------------------------------------------------
# Run synthesis and implementation in two stages, polling each run's STATUS
# and PROGRESS so the batch log shows live progress instead of a long silence.
# ----------------------------------------------------------------------------
proc ts {} { return [clock format [clock seconds] -format {%H:%M:%S}] }

proc monitor_run {run_name} {
    set last ""
    while {1} {
        set status   [get_property STATUS   [get_runs $run_name]]
        set progress [get_property PROGRESS [get_runs $run_name]]
        set line "\[[ts]\]  $run_name  [format %-5s $progress]  $status"
        if {$line ne $last} {
            puts $line
            flush stdout
            set last $line
        }
        if {[regexp -nocase {complete|error|cancel} $status]} { return $status }
        after 3000
    }
}

puts "\[[ts]\]  launching synth_1"
flush stdout
launch_runs synth_1 -jobs 8
set status [monitor_run synth_1]
if {[regexp -nocase {error|cancel} $status]} {
    error "synth_1 did not complete: $status"
}

puts "\[[ts]\]  launching impl_1 (through write_bitstream)"
flush stdout
launch_runs impl_1 -to_step write_bitstream -jobs 8
set status [monitor_run impl_1]
if {[regexp -nocase {error|cancel} $status]} {
    error "impl_1 did not complete: $status"
}

puts "\[[ts]\]  bitstream: ${script_dir}/hw/${top_module}/project_1.runs/impl_1/${top_module}.bit"

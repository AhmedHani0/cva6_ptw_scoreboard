# run_onespin_ptw.tcl
# -----------------------------------------------------------------------------
# OneSpin run script for standalone CVA6 PTW scoreboard verification.
#
# PTW = Page Table Walker.
# This script mirrors the existing TLB/shared-TLB flow:
#   1. Read CVA6 packages and dependencies.
#   2. Read the formal package.
#   3. Read the PTW DUT, formal top, and scoreboard bind.
#   4. Elaborate cva6_ptw_formal_top.
#   5. Compile, enter MV mode, and run all checks.
# -----------------------------------------------------------------------------

set CVA6_REPO_ROOT "/import/lab/users/hassan/Downloads/MasterProjekt/cva6"
set CVA6_RTL_ROOT  "$CVA6_REPO_ROOT/core"
set WORK_ROOT      "/import/lab/users/hassan/Downloads/MasterProjekt/cva6_ptw_scoreboard"

set CF_MATH_PKG_FILE $CVA6_REPO_ROOT/vendor/pulp-platform/common_cells/src/cf_math_pkg.sv

# Common likely PMP paths in CVA6 trees. The foreach below reads only files that exist.
set PMP_CANDIDATE_FILES [list \
    $CVA6_RTL_ROOT/pmp/src/pmp.sv \
    $CVA6_RTL_ROOT/pmp/src/pmp_entry.sv \
    $CVA6_RTL_ROOT/pmp/src/pmp_data_if.sv
]

# Helper: read a SystemVerilog file and print what is being read.
proc read_sv {path} {
    puts "Reading: $path"
    read_verilog -sv $path
}

proc read_sv_if_exists {path} {
    if {[file exists $path]} {
        read_sv $path
    } else {
        puts "Skipping missing optional file: $path"
    }
}

# 1) Read CVA6 packages first.
read_sv $CVA6_RTL_ROOT/include/config_pkg.sv
read_sv $CVA6_RTL_ROOT/include/cv32a60x_config_pkg.sv
read_sv $CVA6_RTL_ROOT/include/build_config_pkg.sv
read_sv $CVA6_RTL_ROOT/include/riscv_pkg.sv
read_sv $CVA6_RTL_ROOT/include/ariane_pkg.sv

# 2) Read support package/module dependencies used by cva6_ptw and pmp.
read_sv_if_exists $CF_MATH_PKG_FILE
foreach f $PMP_CANDIDATE_FILES {
    read_sv_if_exists $f
}

# 3) Read our formal package before DUT/top/checker.
read_sv $WORK_ROOT/cva6_ptw_formal_pkg.sv

# 4) Read DUT and formal top/checker.
read_sv $WORK_ROOT/cva6_ptw.sv
read_sv $WORK_ROOT/cva6_ptw_formal_top.sv
read_sv $WORK_ROOT/cva6_ptw_scoreboard_bind.sv

# 5) Elaborate the wrapper.
set_elaborate_option -golden -top {Verilog!work.cva6_ptw_formal_top}
elaborate -golden

# 6) Compile formal model.
compile

# 7) Set MV mode.
set_mode mv

# 8) Print available checks.
set all_checks [get_checks]
puts "Available checks:"
foreach c $all_checks {
    puts "  $c"
}

# 9) Run all checks one by one.
foreach c $all_checks {
    puts "============================================================"
    puts "Running check: $c"
    puts "============================================================"
    check -verbose $c
}

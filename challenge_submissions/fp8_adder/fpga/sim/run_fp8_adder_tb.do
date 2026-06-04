transcript on
if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vlog ../src/fp8_adder.v fp8_adder_tb.v
vsim -c work.fp8_adder_tb -do "run -all; quit -f"
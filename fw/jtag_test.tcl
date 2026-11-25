# Test the DAQ demo over JTAG, without Linux (board in JTAG boot mode, JP5 = JTAG).
#
#   xsdb jtag_test.tcl [watch_seconds]
#
# Loads out/zdaq.bit, initializes the PS from out/ps7_init.tcl, then talks to
# the registers and the event FIFO through the debug port:
#   - prints version, status (master, MMCM locked, board id)
#   - enables + clears, fires 3 soft triggers, reads and checks the events
#   - then watches for watch_seconds (default 30) and prints every event,
#     so BTN0 / BTN1 can be tried by hand.

set here [file dirname [file normalize [info script]]]
set out  $here/out
set watch [expr {[llength $argv] > 0 ? [lindex $argv 0] : 30}]

set REG  0x43C00000
set FIFO 0x43C10000
# axi_fifo_mm_s registers (AXI4-Lite data interface)
set RDFR [expr {$FIFO + 0x18}]   ;# write 0xA5: reset RX FIFO
set RDFO [expr {$FIFO + 0x1C}]   ;# RX occupancy (words)
set RDFD [expr {$FIFO + 0x20}]   ;# RX data
set RLR  [expr {$FIFO + 0x24}]   ;# RX length of next packet (bytes)
set ISR  [expr {$FIFO + 0x00}]

proc rd {a} { return [lindex [mrd -value $a] 0] }
proc wr {a v} { mwr $a $v }

connect
targets -set -filter {name =~ "APU*"}
rst -system
after 1000
fpga -file $out/zdaq.bit
targets -set -filter {name =~ "ARM*#0"}
# the hardware description tells xsdb that the PL address range may be accessed
loadhw -hw $out/zdaq.xsa -mem-ranges [list {0x40000000 0xbfffffff}]
source $out/ps7_init.tcl
ps7_init
ps7_post_config
after 200

set ver [rd $REG]
set st  [rd [expr {$REG + 0x08}]]
puts [format "VERSION 0x%08X  STATUS 0x%08X  master=%d locked=%d board_id=%d" \
    $ver $st [expr {$st & 1}] [expr {($st >> 1) & 1}] [expr {($st >> 4) & 3}]]
puts [format "INPUTS 0x%08X  TRAIN_PERIOD %d" [rd [expr {$REG + 0x0C}]] [rd [expr {$REG + 0x10}]]]

# read one event from the FIFO if there is one; returns the list of words
proc get_event {} {
    global RDFO RLR RDFD
    if {[rd $RDFO] == 0} { return {} }
    set n [expr {[rd $RLR] / 4}]
    set w {}
    for {set i 0} {$i < $n} {incr i} { lappend w [rd $RDFD] }
    return $w
}

proc show {w} {
    # event: length (bytes), timestamp low, high, packet counter, 3 tags
    set ts [expr {([lindex $w 2] << 32) | [lindex $w 1]}]
    set str [format "event %6d  ts %14d (%.6f s)  length %d" \
        [lindex $w 3] $ts [expr {$ts / 125.0e6}] [lindex $w 0]]
    if {[lindex $w 0] != 4 * [llength $w]} { append str "  LENGTH MISMATCH" }
    foreach k {4 5 6} tag {0xFEEDC0DE 0xDECAFBAD 0xF0F0F0F0} {
        if {[lindex $w $k] != $tag} { append str "  BAD TAG $k"; break }
    }
    puts $str
}

wr $RDFR 0xA5
wr [expr {$REG + 0x04}] 3          ;# enable + clear
after 10

puts "--- 3 soft triggers"
for {set k 0} {$k < 3} {incr k} { wr [expr {$REG + 0x24}] 1; after 5 }
after 10
set got 0
while {[llength [set w [get_event]]] > 0} {
    show $w
    if {[lindex $w 3] != $got || [llength $w] != 7} { puts "  ** unexpected" }
    incr got
}
puts [format "TRIG_COUNT %d  EVT_COUNT %d  DROP_COUNT %d" \
    [rd [expr {$REG + 0x18}]] [rd [expr {$REG + 0x1C}]] [rd [expr {$REG + 0x20}]]]
if {$got == 3} { puts "soft triggers OK" } else { puts "soft triggers: got $got events, expected 3" }

puts "--- watching $watch s: press BTN0 (one trigger) or hold BTN1 (train every 10 ms); SW3 must be on"
set t_end [expr {[clock seconds] + $watch}]
set prev_ts -1
while {[clock seconds] < $t_end} {
    set w [get_event]
    if {[llength $w] == 0} { after 20; continue }
    show $w
    set ts [expr {([lindex $w 2] << 32) | [lindex $w 1]}]
    if {$prev_ts >= 0} { puts [format "      +%.3f ms" [expr {($ts - $prev_ts) / 125.0e3}]] }
    set prev_ts $ts
}
puts [format "TRIG_COUNT %d  EVT_COUNT %d  DROP_COUNT %d  occupancy %d" \
    [rd [expr {$REG + 0x18}]] [rd [expr {$REG + 0x1C}]] [rd [expr {$REG + 0x20}]] [rd $RDFO]]

#!/bin/bash
# Bus-timing simulations for the Smart-Zynq apple_bus (Vivado 2024.2 xsim).
#   ./run.sh bus  [NAME=value ...]   random bus cycles vs a ROM card (tb_bus.sv)
#   ./run.sh disk [NAME=value ...]   P5 boot-ROM read loop vs the real DiskII (tb_disk.sv)
#   ./run.sh menu [NAME=value ...]   Disk II $C800 boot-menu RAM + drive swap/flush (tb_menu.sv)
#   ./run.sh u2   [NAME=value ...]   Uthernet II W5100 indirect register reads (tb_u2.sv)
#   ./run.sh phy  [NAME=value ...]   a2_bus_phy drive start/stop/soft-landing options (tb_phy.sv)
#   ./run.sh loop [NAME=value ...]   the IIe LDA $C505 test loop, per-cycle drive timing (tb_loop.sv)
#   ./run.sh drvwr                   drive_ii write head alone: one nibble per $C0nC access (tb_drvwr.sv)
#   ./run.sh hdd                     ProDOS hard disk card, blocks via the host sector buffer (tb_hdd.sv)
#   ./run.sh sscnet                  Super Serial Card 6551 <-> network bridge, both directions (tb_sscnet.sv)
#   ./run.sh osd                     HDMI notice line text under the Apple picture (tb_osd.sv)
# NAMEs are the testbench parameters, e.g. ADDR_N=14 DATA_N=11 WRITE_N=2 T_ADS=400.
# top.sv currently uses 14/11/2; the pre-2026-09-25 values were 14/20/12 (11-step read).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$HERE/../.." && pwd)                 # repository root
T=$S                                          # shared hdl/ lives at the root
B=$S/boards/a2n20v2-SmartZynq                  # Smart Zynq board: rtl/, src/a2hostd/
source /tools/Xilinx/Vivado/2024.2/settings64.sh >/dev/null 2>&1
MODE=$1; shift
GEN=""; TAG=""
for kv in "$@"; do GEN="$GEN -generic_top $kv"; TAG="${TAG}_$kv"; done
W=$HERE/work/${MODE}${TAG}
mkdir -p "$W" && cd "$W"
COMMON="$T/hdl/support/cdc.sv $T/hdl/support/cdc_denoise.sv $T/hdl/bus/a2bus_if.sv $T/hdl/bus/a2bus_control_if.sv $T/hdl/bus/a2bus_timing.sv $T/hdl/bus/apple_bus.sv $B/rtl/generated/a2bridge_pl_wrapper.sv $B/rtl/a2_bus_phy.sv"
if [ "$MODE" = disk ]; then
    [ -f track0.hex ] || { gcc -O2 -I$B/src/a2hostd/include "$HERE/mktrack.c" $B/src/a2hostd/src/gcr_dsk.c -o mktrack && ./mktrack; }
    cp $T/hdl/disk/diskii.hex $T/hdl/disk/diskmenu.hex $T/hdl/slots/slots.hex .
    SRCS="$COMMON $T/hdl/support/rom.v $T/hdl/memory/a2mem_if.sv $T/hdl/memory/mem_port_if.sv $T/hdl/memory/mem_if_mux.sv $T/hdl/slots/slot_if.sv $T/hdl/slots/slotmaker_config_if.sv $T/hdl/slots/slotmaker.sv $T/hdl/disk/drive_volume_if.sv $T/hdl/disk/drive_ii.sv $T/hdl/disk/apple_disk.sv $HERE/tb_disk.sv"
    TOP=tb_disk
elif [ "$MODE" = menu ]; then
    cp $T/hdl/disk/diskii.hex $T/hdl/disk/diskmenu.hex $T/hdl/slots/slots.hex .
    [ -f track0.hex ] || { gcc -O2 -I$B/src/a2hostd/include "$HERE/mktrack.c" $B/src/a2hostd/src/gcr_dsk.c -o mktrack && ./mktrack; }
    SRCS="$COMMON $T/hdl/support/rom.v $T/hdl/memory/a2mem_if.sv $T/hdl/memory/mem_port_if.sv $T/hdl/memory/mem_if_mux.sv $T/hdl/slots/slot_if.sv $T/hdl/slots/slotmaker_config_if.sv $T/hdl/slots/slotmaker.sv $T/hdl/disk/drive_volume_if.sv $T/hdl/disk/drive_ii.sv $T/hdl/disk/apple_disk.sv $T/hdl/slots/phys_slot_detect.sv $HERE/tb_menu.sv"
    TOP=tb_menu
elif [ "$MODE" = u2 ]; then
    cp $T/hdl/slots/slots.hex .
    SRCS="$COMMON $T/hdl/memory/a2mem_if.sv $T/hdl/memory/mem_port_if.sv $T/hdl/disk/drive_volume_if.sv $T/hdl/slots/slot_if.sv $T/hdl/slots/slotmaker_config_if.sv $T/hdl/slots/slotmaker.sv $T/hdl/uthernet2/uthernet2.sv $HERE/tb_u2.sv"
    TOP=tb_u2
elif [ "$MODE" = drvwr ]; then
    SRCS="$T/hdl/bus/a2bus_if.sv $T/hdl/memory/mem_port_if.sv $T/hdl/disk/drive_volume_if.sv $T/hdl/disk/drive_ii.sv $HERE/tb_drvwr.sv"
    TOP=tb_drvwr
elif [ "$MODE" = hdd ]; then
    cp $T/hdl/disk/hdd_rom.hex .
    SRCS="$T/hdl/bus/a2bus_if.sv $T/hdl/memory/mem_port_if.sv $T/hdl/disk/drive_volume_if.sv $T/hdl/slots/slot_if.sv $T/hdl/support/rom.v $T/hdl/disk/hdd.sv $HERE/tb_hdd.sv"
    TOP=tb_hdd
elif [ "$MODE" = sscnet ]; then
    SRCS="$T/hdl/support/uart_rx.v $T/hdl/support/uart_tx.v $T/hdl/support/uart_6551.v $T/hdl/ssc/ssc_net_bridge.sv $HERE/tb_sscnet.sv"
    TOP=tb_sscnet
elif [ "$MODE" = osd ]; then
    cp $T/hdl/video/video.hex .
    SRCS="$T/hdl/video/osd_line.sv $HERE/tb_osd.sv"; TOP=tb_osd
elif [ "$MODE" = phy ]; then
    SRCS="$B/rtl/a2_bus_phy.sv $HERE/tb_phy.sv"; TOP=tb_phy
elif [ "$MODE" = loop ]; then
    cp $T/hdl/disk/diskii.hex .
    SRCS="$COMMON $HERE/tb_loop.sv"; TOP=tb_loop
else
    SRCS="$COMMON $HERE/tb_bus.sv"; TOP=tb_bus
fi
xvlog -sv -d SMART_ZYNQ $SRCS > xvlog.log 2>&1 || { grep ERROR xvlog.log; exit 1; }
xelab -debug off --timescale 1ns/1ps -override_timeunit -override_timeprecision $TOP -s snap $GEN > xelab.log 2>&1 || { grep ERROR xelab.log; exit 1; }
xsim snap -R > xsim.log 2>&1
grep -E "^RESULT" xsim.log || { grep -E "ERROR|Error|FATAL" xsim.log | head; exit 1; }

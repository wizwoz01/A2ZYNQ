# A2FPGA core documentation

These pages come from the [A2FPGA project's docs](https://github.com/a2fpga/a2fpga_core/tree/main/docs)
and describe the core that A2ZYNQ is built on: how it snoops the Apple bus,
how virtual cards plug in, how memory, video and audio work, and how a
coprocessor talks to it. I copied the pages that apply to this port and left
out the ones about the Gowin toolchain and the other boards. Where the
behaviour on A2ZYNQ is different from upstream (the Disk II write path, the
boot menu, the storage paths, the SSC network bridge) I updated the text, and
links to files that only exist upstream point to the upstream repository.

If you want the Zynq-specific side (the SPI host interface, the DDR memory
path, the storage fixes, power), that's in
[boards/a2n20v2-SmartZynq/docs](../../boards/a2n20v2-SmartZynq/docs/).

## Reading order

1. [architecture.md](architecture.md) - how the code is organized: shared `hdl/` vs per-board, the video, sound and bus pipelines, key file map.
2. [bus-interface.md](bus-interface.md) - Apple II bus snooping (`a2bus_if`), the slot/card system, and how to build a virtual card.
3. [peripheral-cards.md](peripheral-cards.md) - the emulated cards: Disk II and the boot menu, hard disk, SSC, Mockingboard, SuperSprite, Uthernet II.
4. [gotchas.md](gotchas.md) - traps that cost days if you don't know about them.

## Reference

| Page | What's in it |
|------|--------------|
| [architecture.md](architecture.md) | Module organization, the subsystems, where things live |
| [bus-interface.md](bus-interface.md) | `a2bus_if`, `slot_if`, slot decode, driving data back, adding a card |
| [peripheral-cards.md](peripheral-cards.md) | Every emulated card, its registers and the cores it reuses |
| [coprocessor-interface.md](coprocessor-interface.md) | How an MCU (here: Linux) observes and controls the core |
| [memory-system.md](memory-system.md) | `mem_port_if`, multi-port arbitration, memory backends, CDC |
| [video-pipeline.md](video-pipeline.md) | The display paths, `pixel_stream_if`, adding a video generator |
| [audio.md](audio.md) | Sound sources, mixing, filtering, HDMI audio |
| [gotchas.md](gotchas.md) | Known traps: synthesis quirks, CDC bugs, memory lessons |
| [memory_bandwidth_analysis.md](memory_bandwidth_analysis.md) | DDR3/SDRAM bandwidth headroom |

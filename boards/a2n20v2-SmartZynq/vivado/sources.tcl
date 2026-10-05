# A2ZYNQ source list for Vivado, relative to the repository.
# build.tcl sets a2_root (the repository) and a2_board (boards/a2n20v2-SmartZynq)
# before sourcing this. Add a new HDL file here and in nowhere else.
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_board/hdl"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_board/hdl/bl616"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_board/hdl/gowin/clk_hdmi"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_board/hdl/gowin/clk_logic"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/bus"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/debug"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/disk"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/f18a"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/hdmi"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/memory"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/mockingboard"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/sdram"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/slots"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/sound"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/ssc"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/supersprite"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/support"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/uthernet2"]] [current_fileset]
set_property include_dirs [concat [get_property include_dirs [current_fileset]] [list "$a2_root/hdl/video"]] [current_fileset]
add_files -norecurse "$a2_root/hdl/bus/a2bus_if.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/bus/a2bus_if.sv"]
add_files -norecurse "$a2_root/hdl/bus/a2bus_control_if.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/bus/a2bus_control_if.sv"]
add_files -norecurse "$a2_root/hdl/bus/a2bus_timing.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/bus/a2bus_timing.sv"]
add_files -norecurse "$a2_root/hdl/debug/debugoverlay.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/debug/debugoverlay.sv"]
add_files -norecurse "$a2_root/hdl/disk/apple_disk.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/disk/apple_disk.sv"]
add_files -norecurse "$a2_root/hdl/disk/drive_ii.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/disk/drive_ii.sv"]
add_files -norecurse "$a2_root/hdl/disk/drive_volume_if.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/disk/drive_volume_if.sv"]
add_files -norecurse "$a2_root/hdl/disk/hdd.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/disk/hdd.sv"]
add_files -norecurse "$a2_root/hdl/disk/hdd_rom.hex"
add_files -norecurse "$a2_root/hdl/disk/diskmenu.hex"
add_files -norecurse "$a2_root/hdl/f18a/f18a_color.vhd"
add_files -norecurse "$a2_root/hdl/f18a/f18a_core.vhd"
add_files -norecurse "$a2_root/hdl/f18a/f18a_counters.vhd"
add_files -norecurse "$a2_root/hdl/f18a/f18a_cpu.vhd"
add_files -norecurse "$a2_root/hdl/f18a/f18a_div32x16.vhd"
add_files -norecurse "$a2_root/hdl/f18a/f18a_gpu_if.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/f18a/f18a_gpu_if.sv"]
add_files -norecurse "$a2_root/hdl/f18a/f18a_single_port_ram.vhd"
add_files -norecurse "$a2_root/hdl/f18a/f18a_sprites.vhd"
add_files -norecurse "$a2_root/hdl/f18a/f18a_tile_linebuf_ssram.vhd"
add_files -norecurse "$a2_root/hdl/f18a/f18a_tiles.vhd"
add_files -norecurse "$a2_root/hdl/f18a/f18a_version.vhd"
add_files -norecurse "$a2_root/hdl/f18a/f18a_vga_cont_640_60.vhd"
add_files -norecurse "$a2_root/hdl/f18a/f18a_vram.vhd"
add_files -norecurse "$a2_root/hdl/f18a/f18a.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/f18a/f18a.sv"]
add_files -norecurse "$a2_root/hdl/hdmi/audio_clock_regeneration_packet.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/hdmi/audio_clock_regeneration_packet.sv"]
add_files -norecurse "$a2_root/hdl/hdmi/audio_info_frame.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/hdmi/audio_info_frame.sv"]
add_files -norecurse "$a2_root/hdl/hdmi/audio_sample_packet.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/hdmi/audio_sample_packet.sv"]
add_files -norecurse "$a2_root/hdl/hdmi/auxiliary_video_information_info_frame.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/hdmi/auxiliary_video_information_info_frame.sv"]
add_files -norecurse "$a2_root/hdl/hdmi/hdmi.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/hdmi/hdmi.sv"]
add_files -norecurse "$a2_root/hdl/hdmi/packet_assembler.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/hdmi/packet_assembler.sv"]
add_files -norecurse "$a2_root/hdl/hdmi/packet_picker.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/hdmi/packet_picker.sv"]
add_files -norecurse "$a2_root/hdl/hdmi/serializer.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/hdmi/serializer.sv"]
add_files -norecurse "$a2_root/hdl/hdmi/source_product_description_info_frame.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/hdmi/source_product_description_info_frame.sv"]
add_files -norecurse "$a2_root/hdl/hdmi/tmds_channel.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/hdmi/tmds_channel.sv"]
add_files -norecurse "$a2_root/hdl/memory/a2mem_if.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/memory/a2mem_if.sv"]
add_files -norecurse "$a2_root/hdl/mockingboard/mockingboard.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/mockingboard/mockingboard.sv"]
add_files -norecurse "$a2_root/hdl/sound/apple_speaker.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/sound/apple_speaker.sv"]
add_files -norecurse "$a2_root/hdl/sound/audio_out.v"
add_files -norecurse "$a2_root/hdl/sound/audio_timing.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/sound/audio_timing.sv"]
add_files -norecurse "$a2_root/hdl/memory/mem_if_mux.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/memory/mem_if_mux.sv"]
add_files -norecurse "$a2_root/hdl/memory/mem_port_if.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/memory/mem_port_if.sv"]
add_files -norecurse "$a2_root/hdl/sdram/sdram_ports.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/sdram/sdram_ports.sv"]
add_files -norecurse "$a2_root/hdl/sdram/sdram.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/sdram/sdram.sv"]
add_files -norecurse "$a2_root/hdl/slots/slot_if.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/slots/slot_if.sv"]
add_files -norecurse "$a2_root/hdl/slots/slotmaker.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/slots/slotmaker.sv"]
add_files -norecurse "$a2_root/hdl/slots/phys_slot_detect.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/slots/phys_slot_detect.sv"]
add_files -norecurse "$a2_root/hdl/video/osd_line.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/video/osd_line.sv"]
add_files -norecurse "$a2_root/hdl/ssc/ssc_net_bridge.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/ssc/ssc_net_bridge.sv"]
add_files -norecurse "$a2_root/hdl/slots/slotmaker_config_if.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/slots/slotmaker_config_if.sv"]
add_files -norecurse "$a2_root/hdl/slots/slots.hex"
add_files -norecurse "$a2_root/hdl/sound/doc5503.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/sound/doc5503.sv"]
add_files -norecurse "$a2_root/hdl/sound/sound_glu.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/sound/sound_glu.sv"]
add_files -norecurse "$a2_root/hdl/ssc/ssc_rom.vhd"
add_files -norecurse "$a2_root/hdl/ssc/super_serial_card.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/ssc/super_serial_card.sv"]
add_files -norecurse "$a2_root/hdl/supersprite/supersprite.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/supersprite/supersprite.sv"]
add_files -norecurse "$a2_root/hdl/uthernet2/uthernet2.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/uthernet2/uthernet2.sv"]
add_files -norecurse "$a2_root/hdl/support/cdc.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/support/cdc.sv"]
add_files -norecurse "$a2_root/hdl/support/cdc_denoise.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/support/cdc_denoise.sv"]
add_files -norecurse "$a2_root/hdl/support/cdc_fifo.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/support/cdc_fifo.sv"]
add_files -norecurse "$a2_root/hdl/support/cdc_sampling.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/support/cdc_sampling.sv"]
add_files -norecurse "$a2_root/hdl/support/clock_enable_counter.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/support/clock_enable_counter.sv"]
add_files -norecurse "$a2_root/hdl/support/countdown.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/support/countdown.sv"]
add_files -norecurse "$a2_root/hdl/support/debounce.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/support/debounce.sv"]
add_files -norecurse "$a2_root/hdl/support/rising_edge.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/support/rising_edge.sv"]
add_files -norecurse "$a2_root/hdl/support/iir_filter.v"
add_files -norecurse "$a2_root/hdl/support/pulse_crossing.v"
add_files -norecurse "$a2_root/hdl/support/pulse_generator.v"
add_files -norecurse "$a2_root/hdl/support/rom.v"
add_files -norecurse "$a2_root/hdl/support/sdpram32.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/support/sdpram32.sv"]
add_files -norecurse "$a2_root/hdl/support/srff.v"
add_files -norecurse "$a2_root/hdl/support/timer.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/support/timer.sv"]
add_files -norecurse "$a2_root/hdl/support/uart_6551.v"
add_files -norecurse "$a2_root/hdl/support/uart_rx.v"
add_files -norecurse "$a2_root/hdl/support/uart_tx.v"
add_files -norecurse "$a2_root/hdl/support/via6522.vhd"
add_files -norecurse "$a2_root/hdl/support/YM2149.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/support/YM2149.sv"]
add_files -norecurse "$a2_root/hdl/support/ws2812.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/support/ws2812.sv"]
add_files -norecurse "$a2_root/hdl/video/apple_video.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/video/apple_video.sv"]
add_files -norecurse "$a2_root/hdl/video/apple_video_gen.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/video/apple_video_gen.sv"]
add_files -norecurse "$a2_root/hdl/video/vgc.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/video/vgc.sv"]
add_files -norecurse "$a2_root/hdl/video/vgc_gen.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/video/vgc_gen.sv"]
add_files -norecurse "$a2_root/hdl/video/pixel_stream_if.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/video/pixel_stream_if.sv"]
add_files -norecurse "$a2_root/hdl/video/direct_display.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/video/direct_display.sv"]
add_files -norecurse "$a2_root/hdl/video/video_control_if.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/video/video_control_if.sv"]
add_files -norecurse "$a2_root/hdl/video/video.hex"
add_files -norecurse "$a2_root/hdl/bus/apple_bus.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/bus/apple_bus.sv"]
add_files -norecurse "$a2_board/hdl/gowin/clk_hdmi/clk_hdmi.v"
add_files -norecurse "$a2_board/hdl/gowin/clk_logic/clk_logic.v"
add_files -norecurse "$a2_root/hdl/memory/apple_memory_sdram.sv"
set_property file_type SystemVerilog [get_files "$a2_root/hdl/memory/apple_memory_sdram.sv"]
add_files -norecurse "$a2_board/hdl/bl616/bl616_spi_proto_proc.sv"
set_property file_type SystemVerilog [get_files "$a2_board/hdl/bl616/bl616_spi_proto_proc.sv"]
add_files -norecurse "$a2_board/hdl/bl616/bl616_spi_connector.sv"
set_property file_type SystemVerilog [get_files "$a2_board/hdl/bl616/bl616_spi_connector.sv"]
add_files -norecurse "$a2_board/hdl/bl616/mcu_status_led.sv"
set_property file_type SystemVerilog [get_files "$a2_board/hdl/bl616/mcu_status_led.sv"]
add_files -norecurse "$a2_board/hdl/bl616/fpga_sd_spi.sv"
set_property file_type SystemVerilog [get_files "$a2_board/hdl/bl616/fpga_sd_spi.sv"]
add_files -norecurse "$a2_board/hdl/bl616/a2bus_event_fifo.sv"
set_property file_type SystemVerilog [get_files "$a2_board/hdl/bl616/a2bus_event_fifo.sv"]
add_files -norecurse "$a2_board/hdl/top.sv"
set_property file_type SystemVerilog [get_files "$a2_board/hdl/top.sv"]

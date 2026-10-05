# Synthesis-only stability constraints for Vivado 2024.2 mux-collapse crash workaround.
# Applied to the A2 core hierarchy adjacent to doc5503/sound_glu.

set_property KEEP_HIERARCHY yes [get_cells -quiet -hierarchical -filter {REF_NAME == doc5503}]
set_property KEEP_HIERARCHY yes [get_cells -quiet -hierarchical -filter {REF_NAME == sound_glu}]
set_property KEEP_HIERARCHY yes [get_cells -quiet -hierarchical -filter {REF_NAME == legacy_a2fpga_binding}]
set_property KEEP_HIERARCHY yes [get_cells -quiet -hierarchical -filter {REF_NAME == smart_zynq_a2_application}]
set_property USE_DSP no [get_cells -quiet -hierarchical -filter {REF_NAME == doc5503}]

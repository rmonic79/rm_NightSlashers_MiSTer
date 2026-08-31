# Report diagnostico (solo report, zero impatto sul fit): path reali del cono IRQ2/jt51-HuC
report_timing -setup -npaths 100 -detail path_only -file "output_files/diag_setup_worst.txt"
report_timing -hold  -npaths 100 -detail path_only -file "output_files/diag_hold_worst.txt"
report_timing -setup -npaths 60 -detail full_path -to [get_registers {*HUC6280_CPU:CORE*}] -file "output_files/diag_setup_to_core.txt"
report_timing -hold  -npaths 60 -detail full_path -to [get_registers {*HUC6280_CPU:CORE*}] -file "output_files/diag_hold_to_core.txt"
report_timing -setup -npaths 40 -detail full_path -from [get_registers {*u_audio_huc*jt51*}] -file "output_files/diag_setup_from_jt51huc.txt"
report_timing -hold  -npaths 40 -detail full_path -from [get_registers {*u_audio_huc*jt51*}] -file "output_files/diag_hold_from_jt51huc.txt"
report_timing -setup -npaths 40 -detail full_path -from [get_registers {*u_audio_huc|sndlatch*}] -file "output_files/diag_setup_from_latch.txt"
report_timing -hold  -npaths 40 -detail full_path -from [get_registers {*u_audio_huc|sndlatch*}] -file "output_files/diag_hold_from_latch.txt"

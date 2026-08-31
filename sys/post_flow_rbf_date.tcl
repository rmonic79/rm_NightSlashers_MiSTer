# Post-flow: copia il RBF generato da Quartus in una copia datata.
#   output_files/rmNightSlashers.rbf -> output_files/rmNightSlashers_yyyymmdd.rbf
# Se il nome esiste gia' (piu' build nello stesso giorno): _yyyymmdd_1, _2, ...
# Gira dentro `quartus_sh --flow compile` (POST_FLOW_SCRIPT_FILE). Non tocca
# il rmNightSlashers.rbf base (quello resta per l'upload MiSTer).

set out_dir "output_files"
set base    "rmNightSlashers"
set src     "$out_dir/$base.rbf"

if {![file exists $src]} {
    puts "post_flow_rbf_date: $src non trovato, skip"
    return
}

set stamp [clock format [clock seconds] -format %Y%m%d]
set dst   "$out_dir/${base}_${stamp}.rbf"

if {[file exists $dst]} {
    set n 1
    while {[file exists "$out_dir/${base}_${stamp}_${n}.rbf"]} { incr n }
    set dst "$out_dir/${base}_${stamp}_${n}.rbf"
}

file copy -force $src $dst
puts "post_flow_rbf_date: creato $dst"

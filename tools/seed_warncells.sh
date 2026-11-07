#!/bin/sh
# Prints SQL that seeds warn_cell_known with the DWD district warning cell ids (9 digits, type 1 `1<AGS5>000`, type 10 prefix 9).
# Input: any text with the ids (CSV column, one per line, or the WARNCELLID values of the DWD WFS layer dwd:Warngebiete_Kreise, 402 ids).
# Usage: tools/seed_warncells.sh < ids.txt | mariadb <database>     (never run automatically; the server only checks ids once
# at least WarnCellCatalog.minimumSeed ids are known, an unseeded table accepts every well-formed id).
grep -Eo '(^|[^0-9])[19][0-9]{8}([^0-9]|$)' | grep -Eo '[19][0-9]{8}' | sort -u | awk 'BEGIN { print "INSERT IGNORE INTO warn_cell_known (warncell_id) VALUES" }
  { printf "%s(\x27%s\x27)", (NR > 1 ? ",\n" : ""), $1 } END { print ";" }'

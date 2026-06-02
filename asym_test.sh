source /tmp/ccgtest/ccg.sh
wd=$(mktemp -d)
# A real conflict whose OURS content legitimately contains a line "<<<<<<< example"
# (e.g. a doc/test fixture about git). One real conflict block.
printf '%s\n' \
'top' \
'<<<<<<< HEAD' \
'ours line 1' \
'<<<<<<< example (literal content, not a real marker)' \
'ours line 2' \
'=======' \
'theirs line 1' \
'>>>>>>> feat' \
'bottom' > a.txt
echo "### parse produces these conflicts:"
_ccg_parse_conflicts a.txt "$wd" | sed 's#'"$wd"'#WD#g'
echo "### now simulate apply counting (count <<< vs >>> blocks):"
awk '/^<{7} /{o++} /^>{7} /{c++} END{print "apply opens(<<<)="o"  parse closes(>>>)="c}' a.txt

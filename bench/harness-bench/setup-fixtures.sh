#!/data/data/com.termux/files/usr/bin/bash
# bench/harness-bench/setup-fixtures.sh — build the task environment.
#
# Run before EVERY task, not once. Several tasks mutate the tree (delete empty
# files, rename, move); without a reset, task N sees whatever task N-1 left and
# the scores stop being comparable across models.
#
# The fixture is deterministic: same files every time, so a model's score is a
# property of the model, not of the order the tasks happened to run in.

set -uo pipefail

LAB="${LAB:-/storage/emulated/0/bench-lab}"

rm -rf "$LAB"
mkdir -p "$LAB"/{archive,logs,docs/sub}

# --- 3 jpg + 1 jpeg (t01 counts .jpg, t19 renames .jpeg and expects >=4) ----
: > "$LAB/a.jpg"; : > "$LAB/b.jpg"; : > "$LAB/c.jpg"
: > "$LAB/pic.jpeg"

# --- 2 named *report* (t02) -------------------------------------------------
printf 'quarter one\n' > "$LAB/report-q1.txt"
printf 'quarter two\n' > "$LAB/report-q2.txt"

# --- 3 .log (t03, t16) ------------------------------------------------------
printf 'log line\n'      > "$LAB/x.log"
printf 'log line\n'      > "$LAB/y.log"
printf 'log line\n'      > "$LAB/z.log"

# --- 2 draft* (t04) ---------------------------------------------------------
: > "$LAB/draft-a.txt"; : > "$LAB/draft-b.txt"

# --- time: 2 recent, 1 ancient (t05, t06) -----------------------------------
printf 'recent one\n' > "$LAB/recent1.txt"
printf 'recent two\n' > "$LAB/recent2.txt"
printf 'ancient\n'    > "$LAB/ancient.txt"
touch -t 202401010000 "$LAB/ancient.txt"      # POSIX -t, no GNU -d on toybox

# --- size: 1 big, 2 empty (t07, t08, t21) -----------------------------------
head -c 2000000 /dev/zero > "$LAB/big.bin"    # 2 MB, > 1M
: > "$LAB/empty1"; : > "$LAB/empty2"

# --- content: TODO / error / mixed (t09, t11, t30) --------------------------
printf 'TODO: wire the parser\nsomething else\n'          > "$LAB/todo1.txt"
printf 'TODO: rename this\nanother line\n'                > "$LAB/todo2.txt"
printf 'TODO: rewrite\nFIXME: and this\n'                 > "$LAB/mixed.txt"

# --- plain text used by several tasks (t10, t17, t23-25) --------------------
printf 'cherry\napple\nbanana\napple\n' > "$LAB/data.txt"   # 4 lines, 3 unique
printf 'notes here\n'  > "$LAB/notes.txt"
printf 'old content\n' > "$LAB/old.txt"
printf 'temp\n'        > "$LAB/tmp.txt"

# --- a file deeper than two levels (t29) ------------------------------------
printf 'deep file\n' > "$LAB/docs/sub/lab-deep.txt"

# --- text with the word error, twice (t11) ----------------------------------
printf 'error: one\nok\nerror: two\n' > "$LAB/errlines.txt"

# --- total line count of top-level *.txt must be 12 (t10) -------------------
#    report-q1 1 + report-q2 1 + recent1 1 + recent2 1 + ancient 1
#    + todo1 2 + todo2 2 + mixed 2 + data 4 = 15 ... so the fixture below
#    rewrites t10's expected value instead. See tasks.tsv.

echo "fixture built at $LAB"
find "$LAB" -type f | wc -l | sed 's/^/  files: /'
find "$LAB" -mindepth 1 -maxdepth 1 -type d | wc -l | sed 's/^/  dirs : /'

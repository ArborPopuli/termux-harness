#!/data/data/com.termux/files/usr/bin/bash
# tests/guards.sh — offline checks that the safety guards actually work.
#
# Needs no model, no server, no network and no device memory, so it is safe to
# run at any time — including on a phone that is already short on memory. Where
# a check needs the real pattern, it is read out of the script that uses it, so
# the test cannot drift away from the code.
#
# Exits 0 only if every check passed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

SCRIPTS="agent.sh install.sh start-llama-server.sh bench/run-bench.sh bench/capture-evidence.sh tests/integration.sh tests/guards.sh"

echo "########## 1. every script parses ##########"
for f in $SCRIPTS; do
    if bash -n "$HERE/$f" 2>/dev/null; then ok "$f"; else bad "$f does not parse"; fi
done

echo
echo "########## 2. the scripts meant to be run are executable ##########"
# Not cosmetic: `[ -x ]` guarded the stop-the-server step in run-bench.sh, and a
# missing exec bit made that step silently skip and OOM the phone. If this check
# fails, that bug is back.
for f in agent.sh install.sh start-llama-server.sh bench/run-bench.sh bench/capture-evidence.sh tests/integration.sh tests/guards.sh; do
    if [ -x "$HERE/$f" ]; then ok "$f is executable"; else bad "$f is NOT executable"; fi
done

echo
echo "########## 3. a published run is never overwritten ##########"
# run1 is committed under bench/raw/. Both bench scripts must decline the label
# rather than clobber the evidence.
bash "$HERE/bench/run-bench.sh" run1 >/dev/null 2>&1
RC=$?
[ "$RC" -eq 3 ] && ok "run-bench.sh refused label 'run1' (exit 3)" \
                || bad "run-bench.sh exited $RC for an existing label, expected 3"

# Same guard, same reasoning. The label does not exist on disk, so the worst case
# if the guard is broken is exit 4 (missing bench file) — never a real run.
PROBE=guard-probe-$$
: > "$HERE/bench/raw/gpu-evidence-$PROBE.txt"
bash "$HERE/bench/capture-evidence.sh" "$PROBE" >/dev/null 2>&1
RC=$?
rm -f "$HERE/bench/raw/gpu-evidence-$PROBE.txt"
[ "$RC" -eq 3 ] && ok "capture-evidence.sh refused an existing artifact (exit 3)" \
                || bad "capture-evidence.sh exited $RC for an existing artifact, expected 3"

echo
echo "########## 4. the kill switch still stops the phone getting OOM'd ##########"
# The real patterns, read out of agent.sh rather than copied.
DANGEROUS_PATTERNS=""
eval "$(grep -E '^[[:space:]]*DANGEROUS_PATTERNS=' "$HERE/agent.sh")"
if [ -z "$DANGEROUS_PATTERNS" ]; then
    bad "could not read DANGEROUS_PATTERNS out of agent.sh"
else
    blocked=0; allowed=0; wrong=0
    for c in 'rm -rf /' 'rm -rf ~' 'rm -rf /*' 'rm -rf $HOME' 'mkfs.ext4 /dev/block/x' \
             'dd if=/dev/zero of=/dev/block/x' 'dd of=/dev/block/x' 'chmod -R 777 /' \
             'chmod -R 777 ~' 'shutdown -h now' 'reboot'; do
        if printf '%s' "$c" | grep -qE "$DANGEROUS_PATTERNS"; then blocked=$((blocked + 1))
        else bad "should have been blocked: $c"; wrong=$((wrong + 1)); fi
    done
    for c in 'rm -rf /storage/emulated/0/Download/tmp' 'rm -rf ~/Documents/old' \
             'dd if=image.iso of=/sdcard/out.img' 'chmod -R 777 /storage/emulated/0/DL' \
             'find /storage/emulated/0/ -iname "*.jpg" -mtime -3' 'ls -la ~/Download' \
             'tar czf backup.tgz ~/Documents'; do
        if printf '%s' "$c" | grep -qE "$DANGEROUS_PATTERNS"; then
            bad "should NOT have been blocked: $c"; wrong=$((wrong + 1))
        else allowed=$((allowed + 1)); fi
    done
    [ "$wrong" -eq 0 ] && ok "11 destructive commands blocked, 7 legitimate ones allowed" \
                       || bad "$wrong misclassification(s)"
fi

echo
echo "########## 5. the kernel line stays redacted ##########"
# The real sed expression, read out of run-bench.sh. Re-running the bench used to
# write the vendor build hash back into a tracked file.
REDACT=$(grep -oE "sed -E '[^']*'" "$HERE/bench/run-bench.sh" | head -1)
if [ -z "$REDACT" ]; then
    bad "could not read the redaction expression out of run-bench.sh"
else
    got=$(printf '%s' '6.6.118-android15-8-gf17133276a57-abogki518694926-4k' | eval "$REDACT")
    [ "$got" = "6.6.118-android15" ] && ok "vendor build hash stripped: -> $got" \
                                     || bad "redaction produced '$got', expected '6.6.118-android15'"
    got=$(printf '%s' '6.6.118-android15' | eval "$REDACT")
    [ "$got" = "6.6.118-android15" ] && ok "a clean release is left alone" \
                                     || bad "clean release mangled to '$got'"
fi

echo
echo "########## 6. server control is safe when nothing is running ##########"
if bash "$HERE/start-llama-server.sh" --status >/dev/null 2>&1; then
    printf '  --    server is up; skipping the not-running assertions\n'
else
    ok "--status exits non-zero when no server is up"
    bash "$HERE/start-llama-server.sh" --stop >/dev/null 2>&1
    [ $? -eq 0 ] && ok "--stop is a no-op and exits 0 when no server is up" \
                 || bad "--stop exited non-zero with no server running"
fi

echo
echo "########## 7. llama-server is told apart from anything else on the port ##########"
# HTTP 200 on /health proves nothing — an unrelated model server on the same port
# answers 200 as well, and mistaking it for llama-server makes --status lie, stops
# the launcher from starting, and makes run-bench.sh refuse to run. Both scripts
# must therefore require llama.cpp's body. This is a canary: reverting either one
# to a bare HTTP-200 check removes the string and fails here.
for f in agent.sh start-llama-server.sh; do
    if grep -q '"status":"ok"' "$HERE/$f"; then
        ok "$f requires llama.cpp's health body"
    else
        bad "$f accepts any HTTP 200 on /health"
    fi
done

echo
echo "=================================================="
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

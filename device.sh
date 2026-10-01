# device.sh — read what the phone is doing, from a Termux app with no root.
#
# This repository's whole argument is that on a phone the scarce resource is not
# FLOPs but thermal headroom: "the ability to coexist with the foreground".
# MEASUREMENTS.md could not read GPU utilisation and said so rather than inventing
# a number. Thermal headroom, unlike GPU utilisation, *is* readable without root —
# so there is no excuse for a harness that runs commands on someone's phone and
# reports nothing about what they cost.
#
# Everything here comes from world-readable files. No root. No termux-api. Where a
# source is missing this returns non-zero rather than a plausible-looking zero, so
# callers can say "unknown" instead of lying.
#
# Sourced by agent.sh. Not executable on its own.

# ---- thermals ---------------------------------------------------------------
# Zone names are vendor-specific. On the test device (SM8750) the CPU cluster is
# "cpu-0-2-1"; other vendors use "cpu-0-0-0", "cpu-therm", "soc_thermal", and so
# on. Match on the "cpu" prefix and take the first hit; fall back to nothing.

_device_zone_by_type() {  # _device_zone_by_type <case-pattern>
    local z t
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/type" ] || continue
        t=$(cat "$z/type" 2>/dev/null) || continue
        case "$t" in
            $1) printf '%s' "$z"; return 0 ;;
        esac
    done
    return 1
}

# Millidegrees Celsius, as the kernel reports them. Empty if unreadable.
device_temp_mc() {  # device_temp_mc <case-pattern>
    local z
    z=$(_device_zone_by_type "$1") || return 1
    cat "$z/temp" 2>/dev/null
}

device_cpu_temp_mc()     { device_temp_mc 'cpu*'; }
device_battery_temp_mc() { device_temp_mc 'battery*' || device_temp_mc 'Battery*'; }
device_skin_temp_mc()    { device_temp_mc '*shell*'; }

# ---- cpu frequency ----------------------------------------------------------
# scaling_cur_freq is the frequency the governor has actually selected, which is
# what makes it useful: under load it moves, and that movement is the signal.
#
# Which core to read is not arbitrary, and getting it wrong produces a number
# that looks fine and says nothing. On the test device (SM8750) cpu0-5 are held
# near 2400 MHz by the governor whether or not anything is running, so "the
# highest frequency across all cores" reads 2400 MHz under an eight-core load and
# 2400 MHz at idle. It distinguishes nothing. cpu6-7 (cpuinfo_max_freq 4.32 GHz,
# against 3.53 for the rest) move from ~1017 MHz idle to ~1958 MHz under load.
#
# So: read the core with the highest cpuinfo_max_freq. That is the prime core on a
# big.LITTLE part and cpu0 on a uniform one. Measured over five samples each way:
# 1017 idle / 1958 load / 1017 after.
#
# (Same lesson as CORRECTIONS.md §7 — an indicator that does not vary with the
# thing you are trying to detect is not evidence, however precise it looks.)

_device_big_core() {
    [ -n "${_DEV_BIG_CORE:-}" ] && { printf '%s' "$_DEV_BIG_CORE"; return 0; }
    local n m best="" bestmax=0
    for n in /sys/devices/system/cpu/cpu[0-9]*; do
        m=$(cat "$n/cpufreq/cpuinfo_max_freq" 2>/dev/null) || continue
        if [ -z "$best" ] || [ "$m" -gt "$bestmax" ] 2>/dev/null; then
            best="${n##*/}"; bestmax=$m
        fi
    done
    [ -n "$best" ] || return 1
    _DEV_BIG_CORE="$best"
    printf '%s' "$_DEV_BIG_CORE"
}

# Current frequency of the performance core, in kHz.
device_freq_khz() {
    local n
    n=$(_device_big_core) || return 1
    cat "/sys/devices/system/cpu/$n/cpufreq/scaling_cur_freq" 2>/dev/null
}

# Its ceiling, in kHz — the denominator that turns the reading into a percentage.
device_freq_max_khz() {
    local n
    n=$(_device_big_core) || return 1
    cat "/sys/devices/system/cpu/$n/cpufreq/cpuinfo_max_freq" 2>/dev/null
}

# ---- wake lock --------------------------------------------------------------
# Ships with the Termux app, not with termux-api. Holding it keeps Android from
# reaping the process when the screen goes off — the failure mode documented in
# docs/TERMUX-GOTCHAS.md §4, which otherwise looks exactly like an OOM kill.
device_has_wakelock() { command -v termux-wake-lock >/dev/null 2>&1; }

# ---- formatting -------------------------------------------------------------
_mc_to_c() {  # 30800 -> "30.8"
    [ -n "${1:-}" ] || return 1
    printf '%s.%s' "$(( $1 / 1000 ))" "$(( ( $1 % 1000 ) / 100 ))"
}

_khz_to_mhz() {  # 2227200 -> 2227
    [ -n "${1:-}" ] || return 1
    printf '%s' "$(( $1 / 1000 ))"
}

# One line describing the machine right now. Used by `agent.sh --device`.
device_state_line() {
    local t f fm pct=""
    t=$(device_cpu_temp_mc) && t="$(_mc_to_c "$t")°C" || t="?"
    f=$(device_freq_khz)
    fm=$(device_freq_max_khz)
    if [ -n "$f" ]; then
        [ -n "$fm" ] && pct=" ($(( f * 100 / fm ))%)"
        f="$(_khz_to_mhz "$f")MHz"
    else
        f="?"
    fi
    printf 'cpu %s | prime %s%s' "$t" "$f" "$pct"
}

# ---- before/after sampling --------------------------------------------------
# A command's cost is not one number taken afterwards — the interesting parts are
# the peaks that only exist while it runs. So sample alongside it.
#
# The sample file must live under $HOME: Termux's /tmp is noexec and, on the test
# device, not writable at all (docs/TERMUX-GOTCHAS.md §2).

device_sample_once() {
    printf '%s %s %s\n' \
        "$(device_cpu_temp_mc 2>/dev/null || echo '')" \
        "$(device_freq_khz 2>/dev/null || echo '')" \
        "$(date +%s 2>/dev/null)"
}

device_sampler_start() {  # device_sampler_start <file> [interval]
    local file="$1" iv="${2:-1}"
    : > "$file" || return 1
    # The redirection is load-bearing, and it was found the hard way.
    #
    # The obvious way to call this is `pid=$(device_sampler_start "$f")`. That is
    # a command substitution, i.e. a pipe. A background process inherits the
    # caller's stdout, so without `>/dev/null 2>&1` the sampler holds that pipe
    # open for as long as it lives — the substitution never returns, and the
    # shell hangs producing *no output at all*, which reads like a dead device
    # rather than a shell bug.
    #
    # `disown` covers the other call path: called directly rather than in a
    # substitution, the sampler would otherwise be a job of the caller, and any
    # later bare `wait` would block on an infinite loop.
    (
        while :; do
            device_sample_once >> "$file"
            sleep "$iv"
        done
    ) >/dev/null 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null || disown 2>/dev/null
    printf '%s' "$pid"
}

device_sampler_stop() {  # device_sampler_stop <pid>
    [ -n "${1:-}" ] || return 0
    kill "$1" 2>/dev/null
    wait "$1" 2>/dev/null
}

# device_cost_summary <sample-file> <wall-seconds>
# Prints a single line: what the command cost, from the samples taken during it.
device_cost_summary() {
    local file="$1" wall="$2" t f
    [ -s "$file" ] || { printf 'wall %ss | (no samples)' "$wall"; return; }

    local tmax=0 fmin="" fmax=0
    while read -r t f _; do
        [ -n "$t" ] && [ "$t" -gt "$tmax" ] 2>/dev/null && tmax=$t
        if [ -n "$f" ]; then
            [ "$f" -gt "$fmax" ] 2>/dev/null && fmax=$f
            if [ -z "$fmin" ] || [ "$f" -lt "$fmin" ]; then fmin=$f; fi
        fi
    done < "$file"

    # The ceiling the prime core reached is the interesting end of the range:
    # that is how hard the command actually pushed. The floor is just where it
    # sits when nothing is happening.
    local max_khz pct=""
    max_khz=$(device_freq_max_khz)
    [ -n "$max_khz" ] && [ "$fmax" -gt 0 ] 2>/dev/null && \
        pct=$(( fmax * 100 / max_khz ))

    printf 'wall %ss | peak cpu %s°C' "$wall" "$(_mc_to_c "$tmax")"
    if [ -n "$fmin" ]; then
        printf ' | prime %s–%s MHz' "$(_khz_to_mhz "$fmin")" "$(_khz_to_mhz "$fmax")"
        [ -n "$pct" ] && printf ' (topped at %s%% of max)' "$pct"
    fi
}

# ---- termux-api, only if the user has it ------------------------------------
# termux-api is a separate package and a separate app. Most devices do not have
# it, and nothing here may depend on it — but if it is installed, a job that
# finishes while the phone is in your pocket should say so.
device_notify() {  # device_notify <title> <body>
    command -v termux-notification >/dev/null 2>&1 || return 1
    termux-notification --title "$1" --content "$2" >/dev/null 2>&1
}

#!/data/data/com.termux/files/usr/bin/bash
# validate-checkers.sh —— 拿"已知正确的命令"去考判定器。
#
# 判定器是用来判模型的，但它自己也可能错。错得很安静：t08 / t09 / t12 三条
# 曾经把正确答案判成 FAIL，而 25/30 这个分数看起来完全正常，没人会怀疑。
#
# 这个脚本堵的就是这一类：对每条任务跑 refs.tsv 里的参考命令，断言判定器
# 判它 PASS。参考命令连自己都过不了，说明判定器坏了，不是命令坏了。
#
# 不需要模型、不需要联网、几秒钟跑完。改完 tasks.tsv 或 fixtures 之后跑一遍。
#
# 用法：
#   bash validate-checkers.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="${LAB:-/storage/emulated/0/bench-lab}"

[ -f "$HERE/refs.tsv" ] || { echo "缺少 refs.tsv" >&2; exit 2; }

# 任务判定器：id -> 表达式
declare -A CHECKS
while IFS=$'\t' read -r tid _req check; do
    case "$tid" in ''|'#'*) continue ;; esac
    CHECKS["$tid"]="$check"
done < "$HERE/tasks.tsv"

OK=0; BAD=0
BAD_IDS=()

while IFS=$'\t' read -r tid ref; do
    case "$tid" in ''|'#'*) continue ;; esac

    if [ -z "${CHECKS[$tid]:-}" ]; then
        printf '  %-5s  ??     tasks.tsv 里没有这条任务\n' "$tid"
        BAD=$((BAD+1)); BAD_IDS+=("$tid"); continue
    fi

    bash "$HERE/setup-fixtures.sh" >/dev/null 2>&1

    # 参考命令里的 $LAB 展开成真实路径
    ref_expanded="${ref//\$LAB/$LAB}"
    OUT="$(eval "$ref_expanded" </dev/null 2>&1)"
    export OUT LAB

    if eval "${CHECKS[$tid]}" >/dev/null 2>&1; then
        printf '  %-5s  ok\n' "$tid"
        OK=$((OK+1))
    else
        printf '  %-5s  BAD    参考命令被判 FAIL —— 判定器错了\n' "$tid"
        printf '        参考命令 : %s\n' "$ref_expanded"
        printf '        输出     : %s\n' "$(printf '%s' "$OUT" | head -5 | tr '\n' '|')"
        BAD=$((BAD+1)); BAD_IDS+=("$tid")
    fi
done < "$HERE/refs.tsv"

echo
if [ "$BAD" -eq 0 ]; then
    echo "=== 判定器全部自洽：$OK 条参考命令都被判 PASS ==="
    exit 0
fi
echo "=== $BAD 条判定器有问题：${BAD_IDS[*]} ==="
echo "    判定器把已知正确的命令判成失败，说明坏的是判定器。"
echo "    先跑一次夹具看真实值：bash setup-fixtures.sh && ls -la $LAB"
exit 1

#!/bin/sh
# 一条命令装完 siboot，全程不需要梯子。
#
#   wget -qO- https://gitee.com/TeMaTou1145/siboot-mirror/raw/master/go.sh | sh
#
# 它做两件事，然后交给官方的 install.sh：
#   1. 把 SideInstaller.ipa 存进 siboot 的缓存目录（全流程唯一需要 GitHub
#      的地方，用公共加速代理取一次，之后永久不再联网）
#   2. 下载官方 install.sh 并执行（二进制来自 Gitee 镜像，6 秒）
#
# 为什么要缓存 IPA：siboot 第一步会从 github.com 取 SideInstaller.ipa，
# 那个地址跳转到 objects.githubusercontent.com，国内是断的。siboot 本身
# 有本地缓存，只要有 SideInstaller.ipa + SideInstaller.json 且版本对得上，
# 它就不再下载。

set -u

GITEE="https://gitee.com/TeMaTou1145/siboot-mirror/raw/master"
DL="$HOME/.siboot/downloads"
IPA="$DL/SideInstaller.ipa"
INFO="$DL/SideInstaller.json"
GH="https://github.com/FrizzleM/SideInstaller/releases/latest/download/SideInstaller.ipa"
IPA_SIZE=11642855

mb() { t=$(($1 * 10 / 1048576)); printf '%d.%d' $((t / 10)) $((t % 10)); }

# 有终端就画进度，没有就一行一行说
FANCY=
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then FANCY=1; fi

ok() { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
info() { printf '  %s\n' "$1"; }
warn() { printf '  \033[1;33m▲\033[0m %s\n' "$1"; }

# 下载一个文件，边下边报进度
fetch() {
  url=$1
  out=$2
  rm -f "$out"
  if command -v curl > /dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --retry 2 \
         --speed-limit 1024 --speed-time 120 --max-time 900 \
         "$url" -o "$out" > /dev/null 2>&1 &
  else
    wget -q -T 60 -O "$out" "$url" > /dev/null 2>&1 &
  fi
  pid=$!
  if [ -n "$FANCY" ]; then
    while kill -0 "$pid" 2> /dev/null; do
      have=$({ wc -c < "$out"; } 2> /dev/null || echo 0)
      pct=$((have * 100 / IPA_SIZE))
      [ "$pct" -gt 99 ] && pct=99
      printf '\r  \033[36m↓\033[0m 下载 SideInstaller \033[36m%3d%%\033[0m %s/%s MB   ' \
        "$pct" "$(mb "$have")" "$(mb "$IPA_SIZE")"
      sleep 1
    done
    printf '\r\033[2K'
  fi
  wait "$pid"
}

is_zip() { [ "$(head -c 2 "$1" 2> /dev/null)" = "PK" ]; }

say_step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── 1. SideInstaller 缓存 ──────────────────────────────────────────────
say_step "① SideInstaller（一次性，之后不再下载）"

mkdir -p "$DL" || { warn "无法创建 $DL"; exit 1; }

if [ -s "$IPA" ] && [ -s "$INFO" ]; then
  ok "已缓存过，跳过（$(mb "$(wc -c < "$IPA")") MB）"
else
  got=
  for src in "https://ghfast.top/$GH" "https://gh-proxy.com/$GH" "$GH"; do
    host=$(printf '%s' "$src" | cut -d / -f 3)
    if [ -z "$FANCY" ]; then info "从 $host 下载（约 11 MB）…"; fi
    if fetch "$src" "$IPA.part" && [ -s "$IPA.part" ] && is_zip "$IPA.part"; then
      got=$src
      break
    fi
    warn "$host 不行，换下一个"
    rm -f "$IPA.part"
  done

  if [ -z "$got" ]; then
    rm -f "$IPA.part"
    warn "SideInstaller 没下成功，先把 siboot 装上；装完再重跑本命令即可补齐"
  else
    mv "$IPA.part" "$IPA"
    size=$(wc -c < "$IPA")
    tag=$(curl -sI --max-time 20 "https://github.com/FrizzleM/SideInstaller/releases/latest" 2> /dev/null \
          | tr -d '\r' | sed -n 's|.*/tag/\(v[0-9][0-9.]*\).*|\1|p' | head -1)
    [ -z "$tag" ] && tag="v2.2.0"
    sha=$( (sha256sum "$IPA" 2> /dev/null || echo "") | cut -d ' ' -f 1)
    printf '{"release":"%s","size":%s,"sha256":"%s"}\n' "$tag" "$size" "$sha" > "$INFO"
    ok "已缓存 $tag（$(mb "$size") MB），来源 $(printf '%s' "$got" | cut -d / -f 3)"
  fi
fi

# ── 2. 装 siboot 并运行 ───────────────────────────────────────────────
say_step "② siboot（12.2 MB，来自 Gitee）"

TMP="${TMPDIR:-/tmp}/.siboot-install.$$"
script=
for base in "$GITEE" \
            "https://fastly.jsdelivr.net/gh/FrizzleM/siboot@main/minis" \
            "https://gcore.jsdelivr.net/gh/FrizzleM/siboot@main/minis"; do
  if command -v curl > /dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --max-time 90 "$base/install.sh" -o "$TMP" 2> /dev/null && script=1
  else
    wget -q -T 30 -O "$TMP" "$base/install.sh" 2> /dev/null && script=1
  fi
  [ -n "$script" ] && break
  rm -f "$TMP"
done

if [ -z "$script" ]; then
  warn "拿不到 install.sh，三个源都不通。检查网络后重跑。"
  exit 1
fi

# install.sh 自己会选源、校验 SHA256、装到 ~/.siboot/bin，然后 exec siboot。
# stdin 已经给不了它（那是本脚本的正文），它会自己用 /dev/tty。
sh "$TMP" "$@"
rc=$?
rm -f "$TMP"
exit $rc

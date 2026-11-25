#!/bin/sh
# 一条命令装完 siboot，全程不需要梯子。
#
#   wget -qO- https://gitee.com/TeMaTou1145/siboot-mirror/raw/master/go.sh | sh
#
# 它做两件事，然后交给官方的 install.sh：
#   1. 把 SideInstaller.ipa 存进 siboot 的缓存目录（全流程唯一原本需要
#      GitHub 的地方。现在优先从 Gitee 镜像取，取不到再走公共加速代理；
#      存好之后永久不再联网）
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
# Gitee 上的固定地址：release tag 恒为 ipa，文件名恒定，换版本只换附件
# （sync.py 会先删旧附件再传新的），所以这个 URL 永远有效。
IPA_GITEE="https://gitee.com/TeMaTou1145/siboot-mirror/releases/download/ipa/SideInstaller.ipa"
IPA_SIZE=11642855

# 进度条用的总大小：作者发新版时 IPA 会变大变小，写死会导致百分比算错，
# 所以从镜像仓库的 ipa.txt 读准确值（格式：版本 字节数 sha256）。
# 读不到就用上面的默认值 —— 只影响百分比显示，不影响下载与校验。
_sz=$(curl -fsSL --max-time 10 "$GITEE/ipa.txt" 2> /dev/null | awk 'NR==1{print $2}')
FRESH=
case "$_sz" in
  '' | *[!0-9]*) ;;
  *) [ "$_sz" -gt 1000000 ] && IPA_SIZE=$_sz && FRESH=1 ;;
esac

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

mkdir -p "$DL" 2> /dev/null

# 自愈：~/.siboot 有时会变成"名字还占着、内容已经没了"的坏目录
#（下载途中 App 被系统挂起，写盘写了一半）。这时候 mkdir 报
# File exists 或 No such file，ls 又看得见，rm -rf 还删不掉。
# 重命名只改父目录里的一条记录，不遍历目录内容，正好绕开这个坏点。
if [ ! -d "$DL" ]; then
  warn "缓存目录异常，自动修复中…"
  bad="$HOME/.siboot.broken.$$"
  mv "$HOME/.siboot" "$bad" 2> /dev/null
  rm -rf "$bad" 2> /dev/null
  mkdir -p "$DL" 2> /dev/null
fi

if [ ! -d "$DL" ]; then
  warn "无法创建 $DL"
  warn "请完全退出 Open Minis 再重新打开，然后重跑本命令"
  exit 1
fi

# 缓存能不能直接用，要跟镜像仓库登记的版本对一下：
# 只有「本地有文件」且「字节数跟 ipa.txt 一致」才算命中。否则说明作者
# 发了新版，必须重下 —— 否则老用户永远停在旧版本上。
cached_size=$(sed -n 's/.*"size": *\([0-9]*\).*/\1/p' "$INFO" 2> /dev/null | head -1)
need_fetch=
if [ -s "$IPA" ] && [ -s "$INFO" ]; then
  if [ -z "$FRESH" ] || [ "$cached_size" = "$IPA_SIZE" ]; then
    ok "已缓存过，跳过（$(mb "$(wc -c < "$IPA")") MB）"
  else
    warn "检测到新版，重新下载（$(mb "${cached_size:-0}") → $(mb "$IPA_SIZE") MB）"
    rm -f "$IPA" "$INFO"
    need_fetch=1
  fi
else
  need_fetch=1
fi

if [ -n "$need_fetch" ]; then
  got=
  for src in "$IPA_GITEE" "https://ghfast.top/$GH" "https://gh-proxy.com/$GH" "$GH"; do
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

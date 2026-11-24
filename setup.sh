#!/bin/sh
# 一次性准备：把 SideInstaller.ipa 存到 siboot 的缓存目录。
#
# 为什么要这一步：
#   siboot 第一步要去 github.com 下载 SideInstaller.ipa，而那个下载地址
#   会跳转到 objects.githubusercontent.com —— 国内是断的。全流程只有这
#   一步必须连 GitHub，作者自己在 README 里也写了"这一步挂梯子"。
#
#   但 siboot 有本地缓存：只要 ~/.siboot/downloads/ 里已经有
#   SideInstaller.ipa 和 SideInstaller.json，且版本对得上，它就不再下载。
#   这个脚本就是用公共加速代理把这个文件放进去，之后永久不再联网。
#
# 用法（Open Minis › 设置 › 终端）：
#   wget -qO- https://gitee.com/TeMaTou1145/siboot-mirror/raw/master/setup.sh | sh

set -u

DL="$HOME/.siboot/downloads"
IPA="$DL/SideInstaller.ipa"
INFO="$DL/SideInstaller.json"
GH="https://github.com/FrizzleM/SideInstaller/releases/latest/download/SideInstaller.ipa"

say() { printf '%s\n' "$1"; }

mkdir -p "$DL" || { echo "!! 无法创建 $DL"; exit 1; }

# 已经有可用的缓存就不再折腾
if [ -s "$IPA" ] && [ -s "$INFO" ]; then
  say "✓ 已缓存过，跳过下载：$IPA ($(wc -c < "$IPA") 字节)"
  say ""
  say "现在运行这条安装 siboot："
  say "  wget -qO- https://gitee.com/TeMaTou1145/siboot-mirror/raw/master/install.sh | sh"
  exit 0
fi

# 下载：优先 curl（能容忍低速），没有就用 busybox wget
fetch() {
  rm -f "$IPA.part"
  if command -v curl > /dev/null 2>&1; then
    curl -fL --connect-timeout 20 --retry 2 \
         --speed-limit 1024 --speed-time 120 --max-time 900 \
         "$1" -o "$IPA.part"
  else
    wget -q -T 60 -O "$IPA.part" "$1"
  fi
}

is_zip() {
  [ "$(head -c 2 "$1" 2> /dev/null)" = "PK" ]
}

got=
for src in \
  "https://ghfast.top/$GH" \
  "https://gh-proxy.com/$GH" \
  "$GH"
do
  host=$(printf '%s' "$src" | cut -d / -f 3)
  say "· 从 $host 下载 SideInstaller（约 11 MB，8 秒到 1 分钟）…"
  if fetch "$src" && [ -s "$IPA.part" ] && is_zip "$IPA.part"; then
    got=$src
    break
  fi
  say "  这个源不行，换下一个"
  rm -f "$IPA.part"
done

if [ -z "$got" ]; then
  rm -f "$IPA.part"
  say ""
  say "✗ 三个源都没下成功。"
  say "  1) 确认网络正常，然后重跑本脚本"
  say "  2) 或者在能连 GitHub 的网络下，把 SideInstaller.ipa 放到："
  say "     $IPA"
  say "     再重跑一次本脚本（它会自己补上版本信息）"
  exit 1
fi

mv "$IPA.part" "$IPA"
size=$(wc -c < "$IPA")

# 问 GitHub 要当前版本号。HEAD 只读响应头，不下载文件本体，
# 所以不需要访问被阻断的 objects.githubusercontent.com。
tag=$(curl -sI --max-time 20 "https://github.com/FrizzleM/SideInstaller/releases/latest" 2> /dev/null \
      | tr -d '\r' | sed -n 's|.*/tag/\(v[0-9][0-9.]*\).*|\1|p' | head -1)
[ -z "$tag" ] && tag="v2.2.0"

sha=$( (sha256sum "$IPA" 2> /dev/null || echo "") | cut -d ' ' -f 1)

printf '{"release":"%s","size":%s,"sha256":"%s"}\n' "$tag" "$size" "$sha" > "$INFO"

say ""
say "✓ 已缓存 $tag（$size 字节）"
say "  来源：$(printf '%s' "$got" | cut -d / -f 3)"
say ""
say "现在运行这条安装 siboot："
say "  wget -qO- https://gitee.com/TeMaTou1145/siboot-mirror/raw/master/install.sh | sh"

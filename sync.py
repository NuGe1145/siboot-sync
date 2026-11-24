#!/usr/bin/env python3
"""把上游 FrizzleM/siboot 的 install.sh + 二进制同步到 Gitee，
并把 SideInstaller.ipa（经作者授权）也镜像过去。

靠得住的三条设计：
1. 两个文件来自同一次下载，先校验 SHA256 再上传，绝不发布自相矛盾的版本。
2. 用二进制哈希前 8 位做 tag，天然幂等：同一版本重复运行只做必要的补全。
3. 先建 release 传附件，最后才改 install.sh；中途失败下次能自愈，不会卡死。

IPA 用的是另一套规则：tag 恒为 "ipa"，文件名恒定，换版本时先删旧附件
再上传新的。这样 go.sh 里的下载地址可以写死，永远不用改。
"""

import base64
import hashlib
import os
import re
import subprocess
import sys
import time

import requests

OWNER = os.environ["GITEE_OWNER"]
REPO = os.environ["GITEE_REPO"]
TOKEN = os.environ["GITEE_TOKEN"]
API = "https://gitee.com/api/v5"
UP = "https://raw.githubusercontent.com/FrizzleM/siboot/main/minis"
ASSET = "siboot-aarch64"
FALLBACK = """https://fastly.jsdelivr.net/gh/FrizzleM/siboot@main/minis
https://gcore.jsdelivr.net/gh/FrizzleM/siboot@main/minis"""

# SideInstaller（IPA）的镜像参数
GH_IPA_API = "https://api.github.com/repos/FrizzleM/SideInstaller/releases/latest"
GH_IPA_DL = "https://github.com/FrizzleM/SideInstaller/releases/latest/download/SideInstaller.ipa"
IPA_NAME = "SideInstaller.ipa"
IPA_TAG = "ipa"          # 固定 tag，URL 才能固定

S = requests.Session()
S.headers["User-Agent"] = "siboot-mirror-sync"


def log(msg):
    print(msg, flush=True)


def fetch(url, binary=False):
    r = S.get(url, timeout=90)
    r.raise_for_status()
    return r.content if binary else r.text


def api(method, path, **params):
    params["access_token"] = TOKEN
    if method == "GET":
        r = S.get(f"{API}{path}", params=params, timeout=90)
    elif method == "DELETE":
        r = S.request("DELETE", f"{API}{path}", params=params, timeout=120)
    else:
        r = S.request(method, f"{API}{path}", data=params, timeout=120)
    if r.status_code >= 400:
        log(f"!! {method} {path} -> {r.status_code} {r.text[:400]}")
        r.raise_for_status()
    return r.json() if r.text.strip() else {}


def find_release(tag):
    r = S.get(f"{API}/repos/{OWNER}/{REPO}/releases",
              params={"access_token": TOKEN, "per_page": 100, "page": 1},
              timeout=60)
    if r.status_code != 200:
        log(f"!! 查 releases 失败 {r.status_code}")
        return None
    try:
        for rel in r.json() or []:
            if rel.get("tag_name") == tag:
                return rel
    except ValueError:
        pass
    return None


def remote_script():
    r = S.get(f"{API}/repos/{OWNER}/{REPO}/contents/install.sh",
              params={"access_token": TOKEN}, timeout=60)
    if r.status_code != 200:
        return ""
    try:
        return base64.b64decode(r.json().get("content", "")).decode()
    except Exception:
        return ""


def default_branch():
    try:
        return api("GET", f"/repos/{OWNER}/{REPO}").get("default_branch") or "master"
    except requests.HTTPError:
        return "master"


def seed_if_empty():
    """空仓库没有分支，创建 release 会失败；先放一个 README 把分支建出来。"""
    r = S.get(f"{API}/repos/{OWNER}/{REPO}/contents/",
              params={"access_token": TOKEN}, timeout=60)
    if r.status_code == 200:
        try:
            if r.json():
                return
        except ValueError:
            pass
    log("  空仓库，先建 README 建立默认分支")
    api("POST", f"/repos/{OWNER}/{REPO}/contents/README.md",
        content=base64.b64encode(
            "# siboot mirror\n\n自动同步自 github.com/FrizzleM/siboot（MIT 协议）。\n".encode()
        ).decode(),
        message="init: 建立默认分支")


def put_file(name, text, message):
    # 注意：Gitee 的 contents 接口在文件不存在时可能返回 200 + []（数组），
    # 而不是 404。所以不能直接 .get()，必须先判断类型。
    cur = {}
    try:
        got = api("GET", f"/repos/{OWNER}/{REPO}/contents/{name}")
        if isinstance(got, dict):
            cur = got
    except requests.HTTPError:
        cur = {}

    if cur.get("sha"):
        try:
            if base64.b64decode(cur.get("content") or "").decode() == text:
                log(f"  {name} 已是最新，跳过提交")
                return
        except Exception:
            pass
        api("PUT", f"/repos/{OWNER}/{REPO}/contents/{name}",
            content=base64.b64encode(text.encode()).decode(),
            message=message,
            sha=cur["sha"])
        log(f"  {name} 已更新")
    else:
        api("POST", f"/repos/{OWNER}/{REPO}/contents/{name}",
            content=base64.b64encode(text.encode()).decode(),
            message=message)
        log(f"  {name} 已新建")


def put_script(text, tag):
    put_file("install.sh", text, f"sync: siboot {tag}")


def push_setup():
    """setup.sh / go.sh 跟着仓库一起发到 Gitee。"""
    here = os.path.dirname(os.path.abspath(__file__))
    for name in ("go.sh", "setup.sh"):
        path = os.path.join(here, name)
        if not os.path.exists(path):
            log(f"  仓库里没有 {name}，跳过")
            continue
        with open(path, encoding="utf-8") as f:
            text = f.read()
        put_file(name, text, f"chore: update {name}")


def upload_asset(rel_id, path, name):
    """Gitee 的 release 响应里没有 upload_url（那是 GitHub 的格式），
    附件要用 release id 拼地址。

    用 curl 而不是 requests：从 GitHub 机房往境内传 10 MB 以上是跨境上行，
    带宽很窄，requests 的写超时撑不住。curl 可以容忍低速长时间传。
    """
    url = f"{API}/repos/{OWNER}/{REPO}/releases/{rel_id}/attach_files"
    log(f"  上传 {name} -> release {rel_id}")
    t0 = time.time()
    p = subprocess.run(
        ["curl", "-sS", "--connect-timeout", "20",
         "--max-time", "2400",
         "--speed-limit", "1024", "--speed-time", "120",
         "-w", "\nHTTP %{http_code} sent=%{size_upload} speed=%{speed_upload}B/s time=%{time_total}s",
         "-F", f"access_token={TOKEN}",
         "-F", f"file=@{path};filename={name}",
         f"{url}?access_token={TOKEN}"],
        capture_output=True, text=True,
    )
    out = (p.stdout or "").strip()
    err = (p.stderr or "").strip()
    log(f"  curl exit={p.returncode} 用时 {time.time() - t0:.1f}s")
    if out:
        log(f"  {out[-300:]}")
    if err:
        log(f"  stderr: {err[-300:]}")
    if p.returncode != 0 or "HTTP 2" not in out:
        log("!! 上传附件失败")
        return False
    log(f"  附件已上传 {os.path.getsize(path)} 字节")
    return True


def upstream_ipa():
    """拿上游 SideInstaller 最新 IPA 的 (tag, size, 下载地址)。

    先走 API（带上 GITHUB_TOKEN 时额度 5000/小时）；没 token 或被限流
    （未认证只有 60/小时，Actions 共享出口 IP 基本必然超）就退回 HEAD
    跟随重定向，从最终 URL 的 /download/v2.2.0/ 里解析版本号。
    两条路都不通才放弃，绝不因为限流就误判成"已同步"。
    """
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    hdrs = {"Accept": "application/vnd.github+json"}
    if tok:
        hdrs["Authorization"] = f"Bearer {tok}"
    try:
        r = S.get(GH_IPA_API, timeout=60, headers=hdrs)
        if r.status_code == 200:
            rel = r.json()
            ipa = next((a for a in (rel.get("assets") or [])
                        if a.get("name") == IPA_NAME), None)
            if ipa:
                return rel.get("tag_name", ""), int(ipa["size"]), ipa["browser_download_url"]
            log("!! 上游 release 里没有 SideInstaller.ipa 资产")
        else:
            log(f"  API 返回 {r.status_code}（限流），改用 HEAD 探测")
    except Exception as e:
        log(f"  API 异常 {type(e).__name__}，改用 HEAD 探测")

    r = S.head(GH_IPA_DL, allow_redirects=True, timeout=90)
    r.raise_for_status()
    size = int(r.headers.get("Content-Length") or 0)
    m = re.search(r"/download/([^/]+)/", r.url or "")
    return (m.group(1) if m else ""), size, GH_IPA_DL


def sync_ipa():
    """镜像 SideInstaller.ipa（经原作者授权）。

    只在「上游有新版」或「Gitee 上还没有」时才下载 + 上传，
    否则一行就退出，不浪费 20 分钟跨境上行。
    """
    try:
        ver, want_size, dl_url = upstream_ipa()
    except Exception as e:
        log(f"!! 探测上游 SideInstaller 失败：{type(e).__name__} {e}")
        return

    if not want_size:
        log("!! 拿不到上游文件大小，本次跳过")
        return

    rel = find_release(IPA_TAG)
    if rel:
        for a in (rel.get("assets") or []):
            if a.get("name") == IPA_NAME and int(a.get("size") or 0) == want_size:
                log(f"== IPA {ver}（{want_size} 字节）已同步，跳过")
                return

    log(f"== 同步 IPA {ver}：{want_size} 字节")
    blob = fetch(dl_url, binary=True)
    if len(blob) != want_size:
        log(f"!! 下载不完整（{len(blob)}/{want_size}），本次跳过")
        return

    if rel is None:
        seed_if_empty()
        rel = api("POST", f"/repos/{OWNER}/{REPO}/releases",
                  tag_name=IPA_TAG,
                  name="SideInstaller（经原作者授权镜像）",
                  body="Mirrored with the author's permission. "
                       "Upstream: github.com/FrizzleM/SideInstaller",
                  target_commitish=default_branch())
        log(f"  建立 release {rel.get('id')} (tag={IPA_TAG})")

    # tag 固定 → 必须先删旧附件，否则同一个 release 会堆一串同名文件，
    # 而且 go.sh 里写死的地址会指向旧的。
    for a in (rel.get("assets") or []):
        if a.get("name") == IPA_NAME:
            try:
                api("DELETE",
                    f"/repos/{OWNER}/{REPO}/releases/{rel['id']}/attach_files/{a['id']}")
                log(f"  已删除旧附件 {a['id']}")
            except Exception as e:
                log(f"  !! 删旧附件失败（继续尝试上传）：{type(e).__name__} {e}")

    tmp = "/tmp/" + IPA_NAME
    with open(tmp, "wb") as f:
        f.write(blob)
    if upload_asset(rel["id"], tmp, IPA_NAME):
        log(f"== IPA 完成 https://gitee.com/{OWNER}/{REPO}/releases/download/{IPA_TAG}/{IPA_NAME}")


def main():
    # 0. 附带文件先对齐：即使 siboot 版本没变，也要保证 setup.sh 在
    try:
        push_setup()
    except Exception as e:
        log(f"!! setup.sh 推送失败（不影响主流程）: {type(e).__name__} {e}")

    # 0.5 IPA 独立于 siboot 版本：单独对齐，失败也不拖累主线
    try:
        sync_ipa()
    except Exception as e:
        log(f"!! IPA 同步失败（不影响 siboot）: {type(e).__name__} {e}")

    # 1. 取上游两个文件
    script = fetch(f"{UP}/install.sh")
    m_sha = re.search(r'^SHA256="([0-9a-f]{64})"', script, re.M)
    m_size = re.search(r"^SIZE=(\d+)", script, re.M)
    if not m_sha or not m_size:
        log("!! 上游 install.sh 里找不到 SHA256/SIZE，格式可能变了，停止")
        return 1

    want_sha, want_size = m_sha.group(1), int(m_size.group(1))
    tag = "v" + want_sha[:8]

    # 2. 先判断要不要动：只拉了 6 KB 的脚本就已经知道版本，
    #    没变就直接退出，不下载那 12 MB。省流量，也不给 GitHub 添无谓的负担。
    rel = find_release(tag)
    if rel and f"releases/download/{tag}" in remote_script():
        log(f"== {tag} 已同步，脚本已指向它，无需下载二进制")
        return 0

    # 3. 下载并校验
    blob = fetch(f"{UP}/bin/{ASSET}", binary=True)
    got_sha = hashlib.sha256(blob).hexdigest()
    log(f"上游 SHA256={want_sha} SIZE={want_size}")
    log(f"实下 {len(blob)} 字节 SHA256={got_sha}")

    if got_sha != want_sha or len(blob) != want_size:
        log("!! 上游正在发版（二进制与脚本暂时不同步），本次跳过，等下一次定时")
        return 0

    log(f"== 同步 {tag}")

    # 4. release 与附件
    if rel is None:
        seed_if_empty()
        rel = api("POST", f"/repos/{OWNER}/{REPO}/releases",
                  tag_name=tag,
                  name=f"siboot {tag}",
                  body="Mirror of github.com/FrizzleM/siboot (MIT). Auto-synced.",
                  target_commitish=default_branch())
        log(f"  建立 release {rel.get('id')}")
    else:
        log(f"  release 已存在（{rel.get('id')}），检查附件")

    names = [a.get("name") for a in (rel.get("assets") or [])]
    if ASSET in names:
        log("  附件已在，不重传")
    else:
        tmp = "/tmp/" + ASSET
        with open(tmp, "wb") as f:
            f.write(blob)
        if not upload_asset(rel["id"], tmp, ASSET):
            return 1

    # 5. 改写 install.sh
    new_script = re.sub(
        r'(?m)^SOURCES="[^"]*"',
        'SOURCES="https://gitee.com/%s/%s/releases/download/%s\n%s"' % (OWNER, REPO, tag, FALLBACK),
        script,
        count=1,
    )
    new_script = new_script.replace('"$1/bin/siboot-aarch64"', '"$1/siboot-aarch64"')
    if new_script == script:
        log("!! 改写未生效，SOURCES 结构可能变了，停止（避免发布指向 GitHub 的脚本）")
        return 1

    # 6. 最后才更新脚本，保证任何时刻脚本指向的附件都已存在
    put_script(new_script, tag)

    log(f"== 完成 https://gitee.com/{OWNER}/{REPO}  ->  {tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

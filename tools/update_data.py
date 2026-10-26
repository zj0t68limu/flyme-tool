# -*- coding: utf-8 -*-
"""
Flyme 固件数据维护脚本
------------------------------------------------
1) 读 data/firmware.json（没有就用根目录的 firmware.json 作为初始种子）
2) 读 data/manual-urls.txt：每行一条链接（官网签名链接 / 抓包链接都行），
   自动去掉 auth_key、拆出 机型/版本/区域/构建时间/Hash、拼成永久直链，加入数据
3) 抓 https://www.flyme.com/firmwarelist-<id>.html ，用官网的 版本/MD5/大小/发布日期
   补齐数据里 md5 / size / releaseDate 为空的条目（同机型同版本匹配）
4) 写回 data/firmware.json
用法：
   python tools/update_data.py             # 只补数据，不抓官网
   python tools/update_data.py --scrape    # 同时抓官网补元数据
"""
import io, json, os, re, sys, time, urllib.request, datetime, ssl

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT, "data")
FW = os.path.join(DATA_DIR, "firmware.json")
SEED = os.path.join(ROOT, "firmware.json")
MANUAL = os.path.join(DATA_DIR, "manual-urls.txt")

URL_RE = re.compile(
    r"/Flyme/([^/]+)/([^/]+)/([^/]+)/(\d{14}(?:-\d{14})?)/([0-9a-fA-F]{8})/update\.zip", re.I)


def load_data():
    src = FW if os.path.exists(FW) else SEED
    if not os.path.exists(src):
        return {"schema": 1, "updated": "", "phones": {}}
    with io.open(src, encoding="utf-8") as f:
        j = json.load(f)
    if "phones" not in j:
        j = {"schema": 1, "updated": "", "phones": j}
    return j


URL_ALIAS = [
    ("/Firmware/Flyme/meizu2_Pro/12.25.5.16/cn_daily/20250512191421-20250516022243/03fdf276/update.zip",
     "https://download.meizu.com/Firmware/Flyme/meizu20_Pro/12.25.5.16/cn_daily/20250512191421-20250516022243/03fdf276/update.zip"),
    ("/Firmware/Flyme/PRO7_Plus/6.1.2.3//20180111121511/736521af/update.zip",
     "https://download.meizu.com/Firmware/Flyme/PRO7_Plus/6.1.2.3/20180111121511/736521af/update.zip"),
]


def apply_alias(u):
    s = str(u or "").strip()
    path = s.split("://", 1)[-1]
    path = "/" + path.split("/", 1)[1] if "/" in path else path
    for bad, good in URL_ALIAS:
        if path == bad or path.replace("//", "/") == bad.replace("//", "/"):
            return good
    return s


def dedupe_key(model, ts, h):
    m = str(model or "").lower()
    if h:
        return "K1:%s|%s" % (m, str(h).lower())
    if ts:
        return "K2:%s|%s" % (m, ts)
    return ""


def parse_url(u):
    m = URL_RE.search(apply_alias(u))
    if not m:
        return None
    model, ver, region, ts_raw, h = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5).lower()
    # 内测构建的时间戳是 "开始-结束" 区间；现有数据约定 ts 留空、URL 保留区间
    ts = "" if "-" in ts_raw else ts_raw
    return {
        "model": model, "ver": ver, "region": region, "ts": ts, "hash": h,
        "url": "https://download.meizu.com/Firmware/Flyme/%s/%s/%s/%s/%s/update.zip"
               % (model, ver, region, ts_raw, h),
    }



def head_md5(url, tries=3):
    """HEAD 取 Content-MD5 -> base64 解码为 32 位 md5；取不到返回空串"""
    import base64
    for i in range(tries):
        try:
            req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "Mozilla/5.0"})
            r = urllib.request.urlopen(req, timeout=25, context=ssl._create_unverified_context())
            v = r.headers.get("Content-MD5")
            return base64.b64decode(v).hex() if v else ""
        except Exception as e:
            if getattr(e, "code", 0) in (429, 403, 503):
                time.sleep(3 * (i + 1)); continue
            return ""
    return ""

def find_phone(phones, model):
    for pid, m in phones.items():
        cdn = m.get("cdn") or []
        if model in cdn or m.get("internal") == model or str(m.get("id")) == model:
            return pid
    return None


def add_url(data, u):
    p = parse_url(u)
    if not p:
        return "无法识别", u
    phones = data["phones"]
    pid = find_phone(phones, p["model"])
    if pid is None:
        # 未知机型：按“新建”策略建一个机型条目（名称待补充）
        nid = max([int(k) for k in phones if str(k).isdigit()] + [0]) + 1
        pid = str(nid)
        phones[pid] = {
            "id": nid,
            "name": p["model"] + "（新机型·待补名称）",
            "code": p["model"].upper(),
            "internal": p["model"],
            "cdn": [p["model"]],
            "groups": [],
        }
    phone = phones[pid]
    groups = phone.setdefault("groups", [])
    g = None
    for x in groups:
        if x.get("ver") == p["ver"]:
            g = x
            break
    if g is None:
        g = {"ver": p["ver"], "isVariant": False, "builds": []}
        if p["region"] in ("cn_daily", "cn_beta", "beta", "intl_beta"):
            g["isBeta"] = True
        groups.append(g)
    want = dedupe_key(p["model"], p["ts"], p["hash"])
    for grp in groups:
        for b in grp.get("builds") or []:
            if dedupe_key(b.get("model"), b.get("ts"), b.get("hash")) == want:
                return "已存在", "%s %s" % (p["model"], p["ver"])
    region = p["region"]
    if region in ("cn_daily", "cn_beta", "beta", "intl_beta"):
        kind, channel, label = "beta", "beta", "内测版"
    elif region in ("intl", "intl_stable"):
        kind, channel, label = "hidden", "global", "国际版"
    else:
        kind, channel, label = "hidden", "cn", "公开版"
    # 同版本已有 official 构建 -> multi
    if kind == "hidden" and any(b.get("kind") == "official" for b in g["builds"]):
        kind, note = "multi", ""
    else:
        note = "" if kind != "hidden" else "官网隐藏·文档收录正式版"

    g["builds"].append({
        "phone": int(pid) if str(pid).isdigit() else pid,
        "model": p["model"], "ver": p["ver"], "ts": p["ts"], "hash": p["hash"],
        "size": 0, "code": "206" if region in ("cn", "cn_stable") else "",
        "md5": head_md5(p["url"]), "releaseDate": "",
        "kind": kind, "url": p["url"], "region": region,
        "src": "manual", "isDiff": False, "note": note,
        "dead": False, "channel": channel, "channelLabel": label,
        "suf": "A" if region in ("cn", "cn_stable") else "",
    })
    g["builds"].sort(key=lambda b: str(b.get("ts", "")), reverse=True)
    return "已添加", "%s %s" % (p["model"], p["ver"])


def ver_key(v):
    return [int(x) if x.isdigit() else 0 for x in re.split(r"[.\-]", str(v))]


def sort_groups(phone):
    """稳定版在前按版本升序，内测/联名在后按版本升序（与现有数据排布一致）"""
    groups = phone.get("groups") or []
    normal = [g for g in groups if not g.get("isBeta") and not g.get("isVariant")]
    other = [g for g in groups if g.get("isBeta") or g.get("isVariant")]
    normal.sort(key=lambda g: ver_key(g.get("ver")))
    other.sort(key=lambda g: ver_key(g.get("ver")))
    phone["groups"] = normal + other


def fetch(url, timeout=25):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return r.read().decode("utf-8", "replace")


def scrape_page(phone_id):
    """返回 {版本号: {md5, size, date}}"""
    html = fetch("https://www.flyme.com/firmwarelist-%s.html" % phone_id)
    out = {}
    # 每张卡片大致是：版本：Flyme 12.6.0.0A / MD5：xxx / 文件大小：6700 MB / 发布时间：2026-06-30
    for m in re.finditer(r"Flyme\s*(\d+(?:\.\d+){3})A?", html):
        ver = m.group(1)
        seg = html[m.start(): m.start() + 1200]
        md5 = re.search(r"\b([0-9a-f]{32})\b", seg)
        size = re.search(r"(\d+)\s*MB", seg)
        date = re.search(r"(20\d\d-\d\d-\d\d)", seg)
        if ver not in out:
            out[ver] = {
                "md5": md5.group(1) if md5 else "",
                "size": int(size.group(1)) * 1024 * 1024 if size else 0,
                "date": date.group(1) if date else "",
            }
    return out


def check_sort(data):
    """校验每个组的 builds 是否按 ts 倒序；返回不合规列表"""
    bad = []
    for pid, m in data["phones"].items():
        for g in m.get("groups", []):
            ts = [str(b.get("ts", "")) for b in g["builds"]]
            if ts != sorted(ts, reverse=True):
                bad.append((pid, m.get("name", ""), g.get("ver", ""), ts))
    return bad


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    if "--check-sort" in sys.argv:
        d = load_data()
        bad = check_sort(d)
        total = sum(len(m.get("groups", [])) for m in d["phones"].values())
        print("组总数 %d | 排序不合规 %d" % (total, len(bad)))
        for pid, name, ver, ts in bad[:20]:
            print("   %-5s %-14s ver=%-12s %s" % (pid, name, ver, ts[:4]))
        if bad:
            print("请运行 python tools/update_data.py 修复（或本地 6-工具脚本\\8-sort_builds.py）")
            sys.exit(1)
        return
    do_scrape = "--scrape" in sys.argv
    data = load_data()
    phones = data["phones"]
    log = []
    # 处理前指纹：只有数据真的变了才更新时间戳
    before = json.dumps(phones, sort_keys=True, ensure_ascii=False)

    # 2) 手动链接
    if os.path.exists(MANUAL):
        with io.open(MANUAL, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                st, info = add_url(data, line)
                log.append("[manual] %s -> %s" % (st, info))

    # 3) 官网补元数据
    meta_by_pid = {}
    if do_scrape and phones:
        for pid in sorted(phones.keys(), key=lambda x: int(x) if str(x).isdigit() else 0):
            try:
                meta = scrape_page(pid)
                filled = 0
                for g in phones[pid].get("groups", []):
                    mm = meta.get(g.get("ver"))
                    if not mm:
                        continue
                    for b in g.get("builds", []):
                        if not b.get("md5") and mm.get("md5"):
                            b["md5"] = mm["md5"]; filled += 1
                        if not b.get("releaseDate") and mm.get("date"):
                            b["releaseDate"] = mm["date"]
                        if not b.get("size") and mm.get("size"):
                            b["size"] = mm["size"]
                meta_by_pid[pid] = meta
                log.append("[scrape] %s -> %d 条补全" % (pid, filled))
                time.sleep(0.4)
            except Exception as e:
                log.append("[scrape] %s 失败: %s" % (pid, e))

    # 用官网数据判定 kind：md5 与官网一致 -> official，同版本其余 -> multi
    for pid, meta in meta_by_pid.items():
        for g in phones[pid].get("groups", []):
            mm = meta.get(g.get("ver"))
            if not mm or not mm.get("md5"):
                continue
            official_md5 = mm["md5"].lower()
            has_official = False
            for b in g.get("builds", []):
                if (b.get("md5") or "").lower() == official_md5:
                    has_official = True
                    if b.get("kind") != "official":
                        b["kind"] = "official"
                        b["note"] = "官网·当前稳定版"
                    if not b.get("releaseDate") and mm.get("date"):
                        b["releaseDate"] = mm["date"]
                    if mm.get("size"):
                        b["size"] = mm["size"]
            if has_official:
                for b in g.get("builds", []):
                    if b.get("kind") == "hidden":
                        b["kind"] = "multi"
                        b["note"] = "同版本多构建·文档收录"

    # 全库统一：每个组内的 builds 按 ts 倒序（不只是本次改动过的组）
    for pid in phones:
        for g in phones[pid].get("groups", []):
            g["builds"].sort(key=lambda b: str(b.get("ts", "")), reverse=True)
        sort_groups(phones[pid])

    after = json.dumps(phones, sort_keys=True, ensure_ascii=False)
    data["schema"] = 1
    if before != after:
        data["updated"] = datetime.datetime.now(
            datetime.timezone(datetime.timedelta(hours=8))).isoformat(timespec="seconds")
        log.append("[updated] 数据有变化，时间戳已更新")
    else:
        log.append("[updated] 数据无变化，保留原时间戳")
    os.makedirs(DATA_DIR, exist_ok=True)
    with io.open(FW, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    print("\n".join(log) if log else "(no change)")
    print("written:", FW, os.path.getsize(FW), "bytes; phones", len(phones))


if __name__ == "__main__":
    main()


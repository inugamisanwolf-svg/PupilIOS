import re, json, struct, sys, subprocess

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.81 Safari/537.36"
DOMAIN = "ltn.gold-usergeneratedcontent.net"

def get(url, rng=None, referer="https://hitomi.la/"):
    cmd = ["curl.exe", "-s", "--max-time", "30", "-H", f"Referer: {referer}", "-H", f"User-Agent: {UA}"]
    if rng:
        cmd += ["-r", rng]
    cmd.append(url)
    return subprocess.run(cmd, capture_output=True).stdout

gg = get(f"https://{DOMAIN}/gg.js").decode()
m_default = int(re.search(r"var o = (\d)", gg).group(1))
o_val = int(re.search(r"o = (\d); break;", gg).group(1))
cases = {}
for c in re.findall(r"case (\d+):", gg):
    cases[int(c)] = o_val
b = re.search(r"b: '(.+)'", gg).group(1)
print("gg: default=", m_default, "o=", o_val, "cases=", len(cases), "b=", repr(b))

def m_of(g): return cases.get(g, m_default)

def s_of(h):
    mm = re.search(r"(..)(.)$", h)
    return int(mm.group(2) + mm.group(1), 16)

def full_path(h): return f"{b}{s_of(h)}/{h}"

def subdomain(url, base=None, d=None):
    retval = ""
    if not base:
        if d == "webp": retval = "w"
        elif d == "avif": retval = "a"
    mm = re.search(r"/[0-9a-f]{61}([0-9a-f]{2})([0-9a-f])", url)
    if not mm: return ""
    g = int(mm.group(2) + mm.group(1), 16)
    if not base:
        retval = retval + str(1 + m_of(g))
    else:
        retval = chr(97 + m_of(g)) + base
    return retval

def url_from_url(url, base=None, d=None):
    return re.sub(r"//..?\.(?:gold-usergeneratedcontent\.net|hitomi\.la)/",
                  f"//{subdomain(url, base, d)}.gold-usergeneratedcontent.net/", url)

def url_from_hash(gid, image, d=None, ext=None):
    ext = ext or d or image["name"].rsplit(".", 1)[-1]
    out = "https://a.gold-usergeneratedcontent.net/"
    if d not in ("webp", "avif"):
        out += d + "/"
    out += full_path(image["hash"]) + "." + ext
    return out

def url_from_url_from_hash(gid, image, d=None, ext=None, base=None):
    if base == "tn":
        real = re.sub(r"^.*(..)(.)$", r"\2/\1/" + image["hash"], image["hash"])
        return url_from_url(f"https://a.gold-usergeneratedcontent.net/{d}/{real}.{ext}", base)
    return url_from_url(url_from_hash(gid, image, d, ext), base, d)

def image_url(gid, image): return url_from_url_from_hash(gid, image, "webp")

# --- first ids from nozomi
raw = get(f"https://{DOMAIN}/n/index-all.nozomi", "0-15")
ids = struct.unpack(f">{len(raw)//4}i", raw)
print("nozomi head ids:", ids)

gid = ids[0]
info_txt = get(f"https://{DOMAIN}/galleries/{gid}.js").decode("utf-8", "replace")
info = json.loads(info_txt.replace("var galleryinfo = ", ""))
print("gallery", gid, "title:", info["title"][:60], "files:", len(info["files"]))
f = info["files"][0]
print("first file:", f["hash"], f["name"], f["width"], f["height"], "webp:", f.get("haswebp"))

thumb = url_from_url_from_hash(gid, f, "webpbigtn", "webp", "tn")
page = image_url(gid, f)
small = url_from_url_from_hash(gid, f, "webpsmalltn", "webp", "tn")
print("bigtn :", thumb)
print("page  :", page)
print("smalltn:", small)

for name, u in (("bigtn", thumb), ("page", page), ("smalltn", small)):
    head = subprocess.run(["curl.exe", "-s", "-o", "NUL", "-w", "%{http_code} %{content_type} %{size_download}", "--max-time", "30",
                           "-H", "Referer: https://hitomi.la/", "-H", f"User-Agent: {UA}", u], capture_output=True).stdout.decode()
    print(f"  {name}: {head}")

# tag index + b-tree text search for "nakadashi"
import hashlib
def hash_term(t): return hashlib.sha256(t.encode()).digest()[:4]
ver = get(f"https://{DOMAIN}/galleriesindex/version?_=1").decode().strip()
print("galleriesindex version:", ver)

def node_at(field, addr, data_dir, version):
    d = get(f"https://{DOMAIN}/{data_dir}/{field}.{version}.index", f"{addr}-{addr+464-1}")
    pos = 0
    nk = struct.unpack_from(">i", d, pos)[0]; pos += 4
    keys = []
    for _ in range(nk):
        ks = struct.unpack_from(">i", d, pos)[0]; pos += 4
        keys.append(d[pos:pos+ks]); pos += ks
    nd = struct.unpack_from(">i", d, pos)[0]; pos += 4
    datas = []
    for _ in range(nd):
        off = struct.unpack_from(">q", d, pos)[0]; pos += 8
        ln = struct.unpack_from(">i", d, pos)[0]; pos += 4
        datas.append((off, ln))
    subs = list(struct.unpack_from(">17q", d, pos))
    return keys, datas, subs

def bsearch(field, key, data_dir, version):
    n = node_at(field, 0, data_dir, version)
    while True:
        keys, datas, subs = n
        if not keys: return None
        where = len(keys)
        found = False
        for i, k in enumerate(keys):
            if key <= k:
                where = i
                found = key == k
                break
        if found: return datas[where]
        if all(x == 0 for x in subs): return None
        n = node_at(field, subs[where], data_dir, version)

term = "nakadashi"
data = bsearch("galleries", hash_term(term), "galleriesindex", ver)
print("term", term, "-> data", data)
if data:
    off, ln = data
    buf = get(f"https://{DOMAIN}/galleriesindex/galleries.{ver}.data", f"{off}-{off+ln-1}")
    cnt = struct.unpack_from(">i", buf, 0)[0]
    got = struct.unpack(f">{cnt}i", buf[4:4+cnt*4])
    print("count:", cnt, "first:", got[:5], "expected len:", cnt*4+4, "actual:", len(buf))

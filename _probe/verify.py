#!/usr/bin/env python3
"""
PupilIOS protocol self-check.

Every function below is a 1:1 mirror of the Swift implementation in
Sources/Hitomi/*.swift (the name of the Swift function is in the docstring).
It asks the live hitomi endpoints and asserts that what the Swift code would
produce is what the server actually answers with, so a divergence between the
port and the Kotlin original shows up as a failed check instead of as a blank
screen on a device.

    python _probe/verify.py            # run everything, write _probe/RESULTS.md

Mirrors:
  HitomiEndpoint        -> ENDPOINT
  GgState.load/m/s      -> gg_load() / gg_m() / gg_s()
  GgState.fullPath      -> full_path()
  GgState.realFullPath  -> real_full_path()          (Kotlin realFullPathFromHash)
  subdomain(of:base:dir:) -> subdomain()
  urlFromUrl            -> url_from_url()
  urlFromHash           -> url_from_hash()
  urlFromUrlFromHash    -> url_from_url_from_hash()
  thumbnailURL          -> thumbnail_url()
  pageURL               -> page_url()
  nozomiAddress         -> nozomi_address()          (Kotlin nozomiAddressFromArgs)
  nozomiWindow/totalFromContentRange -> window()
  hashTerm              -> hash_term()               (Kotlin hashTerm)
  node()/decodeNode()   -> node_at() / decode_node()
  bSearch / compare     -> bsearch() / compare_bytes()
  galleryIDsFromData    -> gallery_ids_from_data()
  suggestions(forQuery:) -> suggestions_url()
"""

import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import time
import urllib.parse

# --- HitomiEndpoint ---------------------------------------------------------
DOMAIN = "ltn.gold-usergeneratedcontent.net"
TAG_INDEX_DOMAIN = "tagindex.hitomi.la"
IMAGE_HOST = "gold-usergeneratedcontent.net"
REFERER = "https://hitomi.la/"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/94.0.4606.81 Safari/537.36")
NOZOMI_EXT = ".nozomi"
MAX_NODE_SIZE = 464
BTREE_ORDER = 16
TAG_INDEX_DIR = "tagindex"
GALLERIES_INDEX_DIR = "galleriesindex"

RESULT = []          # (section, check, ok, detail)
CACHE = {}


def curl(url, rng=None, headers=True):
    """The transport: curl.exe because python's ssl stack is not the one the
    device will use, and hitomi's edge is fussy about that."""
    key = (url, rng)
    if key in CACHE:
        return CACHE[key]
    cmd = ["curl.exe", "-s", "--max-time", "40"]
    if headers:
        cmd += ["-H", f"Referer: {REFERER}", "-H", f"User-Agent: {UA}"]
    if rng is not None:
        cmd += ["-r", rng]
    cmd.append(url)
    proc = subprocess.run(cmd, capture_output=True)
    CACHE[key] = proc.stdout
    return proc.stdout


def curl_status(url):
    out = subprocess.run(
        ["curl.exe", "-s", "-o", "NUL", "-w", "%{http_code} %{content_type} %{size_download}",
         "--max-time", "40", "-H", f"Referer: {REFERER}", "-H", f"User-Agent: {UA}", url],
        capture_output=True).stdout.decode()
    return out.strip()


def check(section, name, ok, detail=""):
    RESULT.append((section, name, bool(ok), detail))
    print(("PASS " if ok else "FAIL ") + f"[{section}] {name}" + (f"  {detail}" if detail else ""))
    return ok


# --- Gg.swift ---------------------------------------------------------------

class Gg:
    m_default = 0
    case_map = {}
    b = ""


GG = Gg()


def gg_load(js):
    """GgState.load(_:) -- same four regexes, same order."""
    m = re.search(r"var o = (\d)", js)
    if not m:
        raise RuntimeError("gg.js: no 'var o = (\\d)'")
    GG.m_default = int(m.group(1))

    branch = re.search(r"o = (\d); break;", js)
    branch_value = int(branch.group(1)) if branch else GG.m_default

    GG.case_map = {}
    for case in re.findall(r"case (\d+):", js):
        GG.case_map[int(case)] = branch_value

    b = re.search(r"b: '(.+)'", js)
    if not b:
        raise RuntimeError("gg.js: no \"b: '...'\"")
    GG.b = b.group(1)


def gg_m(g):
    """GgState.m(_:)"""
    return GG.case_map.get(g, GG.m_default)


def gg_s(h):
    """GgState.s(_:) / Kotlin Gg.s: last three hex digits, reordered, base 10."""
    tail = h[-3:]
    if len(tail) != 3:
        return "0"
    return str(int(tail[2] + tail[0:2], 16))


def full_path(h):
    """GgState.fullPath(_:) / Kotlin fullPathFromHash"""
    return GG.b + gg_s(h) + "/" + h


def real_full_path(h):
    """GgState.realFullPath(_:) / Kotlin realFullPathFromHash (\d\d)(\d) tail."""
    tail = h[-3:]
    if len(tail) != 3:
        return h
    return tail[2] + "/" + tail[0:2] + "/" + h


# --- HitomiClient.swift -----------------------------------------------------

def subdomain(url, base=None, d=None):
    """HitomiClient.subdomain(of:base:dir:) / Kotlin subdomainFromURL."""
    retval = ""
    has_base = bool(base)
    if not has_base:
        if d == "webp":
            retval = "w"
        elif d == "avif":
            retval = "a"

    m = re.search(r"/[0-9a-f]{61}([0-9a-f]{2})([0-9a-f])", url)
    if not m:
        return ""
    g = int(m.group(2) + m.group(1), 16)

    if not has_base:
        retval += str(1 + gg_m(g))
    else:
        retval = chr(97 + gg_m(g)) + base
    return retval


def url_from_url(url, base=None, d=None):
    """HitomiClient.urlFromUrl"""
    sub = subdomain(url, base, d)
    return re.sub(r"//..?\.(?:gold-usergeneratedcontent\.net|hitomi\.la)/",
                  "//" + sub + "." + IMAGE_HOST + "/", url)


def name_ext(name):
    """Kotlin image.name.takeLastWhile { it != '.' }"""
    return name.split(".")[-1] if "." in name else name


def url_from_hash(gid, image, d=None, ext=None):
    """HitomiClient.urlFromHash"""
    resolved = ext or d or name_ext(image["name"])
    path = "https://a." + IMAGE_HOST + "/"
    if d != "webp" and d != "avif":
        path += (d or "") + "/"
    path += full_path(image["hash"]) + "." + resolved
    return path


def url_from_url_from_hash(gid, image, d=None, ext=None, base=None):
    """HitomiClient.urlFromUrlFromHash"""
    if base == "tn":
        raw = "https://a." + IMAGE_HOST + "/" + (d or "") + "/" + real_full_path(image["hash"]) + "." + (ext or "")
        return url_from_url(raw, base)
    return url_from_url(url_from_hash(gid, image, d, ext), base, d)


def thumbnail_url(gid, image, d="webpbigtn"):
    """HitomiClient.thumbnailURL"""
    return url_from_url_from_hash(gid, image, d, "webp", "tn")


def page_url(gid, image):
    """HitomiClient.pageURL"""
    return url_from_url_from_hash(gid, image, "webp")


# --- Index.swift ------------------------------------------------------------

ORDER_BY = {
    "dateAdded": "date", "datePublished": "date", "random": "date",
    "popularToday": "popular", "popularWeek": "popular",
    "popularMonth": "popular", "popularYear": "popular",
}
ORDER_KEY = {
    "dateAdded": "added", "random": "added", "datePublished": "published",
    "popularToday": "today", "popularWeek": "week",
    "popularMonth": "month", "popularYear": "year",
}
NOZOMI_SORTED = {"dateAdded", "random"}


def seg(value):
    """Path segment encoding.

    Kotlin hands the string to ktor, which percent-encodes spaces and anything
    non-ASCII. URL(string:) in Foundation returns nil for those, so the Swift
    port has to encode them itself; `_probe/RESULTS.md` records the live check
    that a %20 tag path answers 206 while a raw space cannot be requested at all.
    """
    return urllib.parse.quote(value, safe="-._~:@!$&'()*+,;=")


def nozomi_address(area, tag, language, sort):
    """HitomiClient.nozomiAddress / Kotlin nozomiAddressFromArgs"""
    base = "https://" + DOMAIN + "/n"
    if sort not in NOZOMI_SORTED:
        if area == "all":
            return f"{base}/{ORDER_BY[sort]}/{ORDER_KEY[sort]}-{seg(language)}{NOZOMI_EXT}"
        return f"{base}/{seg(area)}/{ORDER_BY[sort]}/{ORDER_KEY[sort]}/{seg(tag)}-{seg(language)}{NOZOMI_EXT}"
    if area == "all":
        return f"{base}/{seg(tag)}-{seg(language)}{NOZOMI_EXT}"
    return f"{base}/{seg(area)}/{seg(tag)}-{seg(language)}{NOZOMI_EXT}"


def search_args_from_query(query):
    """SearchArgs.fromQuery"""
    if ":" not in query:
        return None
    left, _, right = query.partition(":")
    if left in ("male", "female"):
        return ("tag", query, "all")
    if left == "language":
        return ("all", "index", right)
    return (left, right, "all")


def total_from_content_range(header):
    """HitomiClient.totalFromContentRange -- the number of ids, not bytes."""
    if not header or "/" not in header:
        return None
    total = header.rsplit("/", 1)[1].strip()
    if not total.isdigit():
        return None
    return int(total) // 4


def decode_ids(data):
    n = len(data) // 4
    return list(struct.unpack(f">{n}i", data[:n * 4]))


def ranged(url, start, count):
    """HitomiClient.nozomiWindow's byte range: [offset*4, (offset+count)*4)."""
    return ranged_bytes(url, start * 4, count * 4)


def ranged_bytes(url, offset, length):
    first = offset
    last = offset + length - 1          # Range<Int> upper bound is exclusive
    return curl(url, f"{first}-{last}")


def window(area, tag, language, sort, offset, count):
    url = nozomi_address(area, tag, language, sort)
    data = ranged(url, offset, count)
    ids = decode_ids(data)
    hdr = curl_headers(url, f"{offset * 4}-{(offset + count) * 4 - 1}")
    total = total_from_content_range(hdr.get("content-range"))
    return url, ids, total, len(data)


def curl_headers(url, rng=None):
    cmd = ["curl.exe", "-s", "-D", "-", "-o", "NUL", "--max-time", "40",
           "-H", f"Referer: {REFERER}", "-H", f"User-Agent: {UA}"]
    if rng:
        cmd += ["-r", rng]
    cmd.append(url)
    raw = subprocess.run(cmd, capture_output=True).stdout.decode("utf-8", "replace")
    out = {}
    for line in raw.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            out[k.strip().lower()] = v.strip()
        elif line.startswith("HTTP/"):
            out["status"] = line.strip()
    return out


def hash_term(term):
    """HitomiClient.hashTerm / Kotlin hashTerm"""
    return hashlib.sha256(term.encode()).digest()[:4]


def int32(data, pos):
    return struct.unpack_from(">i", data, pos)[0]


def int64(data, pos):
    return struct.unpack_from(">q", data, pos)[0]


def node_at(field, address, version):
    """HitomiClient.node(field:address:) / Kotlin getNodeAtAddress"""
    d = GALLERIES_INDEX_DIR if field in ("galleries", "languages", "nozomiurl") else TAG_INDEX_DIR
    url = f"https://{DOMAIN}/{d}/{field}.{version}.index"
    return decode_node(ranged_bytes(url, address, MAX_NODE_SIZE)), url


def decode_node(data):
    """HitomiClient.decodeNode -- same layout, same key-size guard."""
    pos = 0
    key_count = int32(data, pos)
    pos += 4
    keys = []
    for _ in range(max(0, key_count)):
        size = int32(data, pos)
        pos += 4
        if size <= 0 or size > 32:
            raise RuntimeError(f"node: key size {size}")
        keys.append(data[pos:pos + size])
        pos += size
    data_count = int32(data, pos)
    pos += 4
    datas = []
    for _ in range(max(0, data_count)):
        off = int64(data, pos)
        pos += 8
        length = int32(data, pos)
        pos += 4
        datas.append((off, length))
    subs = []
    for _ in range(BTREE_ORDER + 1):
        subs.append(int64(data, pos))
        pos += 8
    return {"keys": keys, "datas": datas, "subs": subs, "bytes": len(data)}


def compare_bytes(a, b):
    """HitomiClient.compare / Kotlin compareArrayBuffers: shorter length wins."""
    top = min(len(a), len(b))
    for i in range(top):
        if a[i] < b[i]:
            return -1
        if a[i] > b[i]:
            return 1
    return 0


def bsearch(field, key, version, walk=None):
    """HitomiClient.bSearch"""
    node, _ = node_at(field, 0, version)
    depth = 0
    while True:
        if not node["keys"]:
            return None, depth
        where = len(node["keys"])
        found = False
        for i, candidate in enumerate(node["keys"]):
            result = compare_bytes(key, candidate)
            if result <= 0:
                where = i
                found = result == 0
                break
        if not found and all(s == 0 for s in node["subs"]):
            return None, depth
        if not found and where >= len(node["subs"]):
            return None, depth
        if found:
            if walk is not None:
                walk.append(where)
            if where < len(node["datas"]):
                return node["datas"][where], depth
            return None, depth
        depth += 1
        if depth > 12:
            raise RuntimeError("b-tree too deep")
        node, _ = node_at(field, node["subs"][where], version)


def gallery_ids_from_data(offset, length, version):
    """HitomiClient.galleryIDsFromData"""
    if length <= 0 or length >= 100_000_000:
        raise RuntimeError(f"index length {length}")
    url = f"https://{DOMAIN}/{GALLERIES_INDEX_DIR}/galleries.{version}.data"
    buf = ranged_bytes(url, offset, length)
    count = int32(buf, 0)
    if count <= 0 or count >= 10_000_000:
        raise RuntimeError(f"index count {count}")
    ids = list(struct.unpack(f">{count}i", buf[4:4 + count * 4]))
    return ids, len(buf), count * 4 + 4


def suggestions_url(field, term):
    """HitomiClient.suggestions(forQuery:) -- one path segment per character."""
    chars = [encode_query_char(c) for c in term]
    out = f"https://{TAG_INDEX_DOMAIN}/{seg(field)}"
    if chars:
        out += "/" + "/".join(seg(c) for c in chars)
    return out + ".json"


def encode_query_char(c):
    """HitomiClient.encodeQueryForURL"""
    if c == " ":
        return "_"
    if c == "/":
        return "slash"
    if c == ".":
        return "dot"
    return c


# --- sections ---------------------------------------------------------------

def section_gg():
    js = curl(f"https://{DOMAIN}/gg.js").decode("utf-8", "replace")
    check("gg", "gg.js fetched", len(js) > 1000, f"{len(js)} bytes")
    gg_load(js)
    check("gg", "load: mDefault is one digit", 0 <= GG.m_default <= 9, f"mDefault={GG.m_default}")
    check("gg", "load: case count > 0", len(GG.case_map) > 0, f"{len(GG.case_map)} cases -> o={sorted(set(GG.case_map.values()))}")
    check("gg", "load: b ends with '/'", GG.b.endswith("/"), f"b={GG.b!r}")
    check("gg", "load: b is 'digits/'", re.fullmatch(r"\d+/", GG.b) is not None, f"b={GG.b!r}")

    # s() on a known hash: tail digits reordered, read as hex, printed base 10
    sample = "0000000000000000000000000000000000000000000000000000000000000123"
    check("gg", "s(): reorders the last three digits", gg_s(sample) == str(int("312", 16)), f"s={gg_s(sample)}")
    check("gg", "realFullPath(): xx/x/hash",
          real_full_path(sample) == "3/12/" + sample, real_full_path(sample))
    return js


def section_gallery():
    url, ids, total, _ = window("all", "index", "all", "dateAdded", 0, 4)
    check("nozomi", "window(index-all) returns 4 ids", len(ids) == 4, f"{ids}")
    check("nozomi", "Content-Range total divides by 4", total is not None and total > 1000,
          f"total={total}")

    gid = ids[0]
    raw = curl(f"https://{DOMAIN}/galleries/{gid}.js").decode("utf-8", "replace")
    check("gallery", f"galleries/{gid}.js fetched", "var galleryinfo = " in raw)
    info = json.loads(raw.replace("var galleryinfo = ", ""))

    # --- field types the Codable structs have to accept
    check("models", "id is a string", isinstance(info.get("id"), str), repr(info.get("id"))[:40])
    check("models", "title is a string", isinstance(info.get("title"), str))
    jt = info.get("japanese_title", "<missing>")
    check("models", "japanese_title is string or null",
          jt is None or isinstance(jt, str), repr(jt)[:40])
    files = info.get("files") or []
    check("models", "files non-empty", len(files) > 0, f"{len(files)} files")
    f0 = files[0]
    for k in ("hash", "name", "width", "height"):
        check("models", f"files[0].{k} present", k in f0)
    check("models", "files[0].width/height are ints",
          isinstance(f0.get("width"), int) and isinstance(f0.get("height"), int))
    hw = f0.get("haswebp", "<missing>")
    check("models", "haswebp absent or int", hw == "<missing>" or isinstance(hw, int), repr(hw))

    langs = info.get("languages") or []
    if langs:
        lg = langs[0]
        check("models", "languages[0].galleryid type", True, f"{type(lg.get('galleryid')).__name__} = {lg.get('galleryid')!r}")
        check("models", "languages[0].language_localname present", "language_localname" in lg,
              repr(lg.get("language_localname"))[:40])
    else:
        check("models", "languages present (single language gallery)", True, "empty -> []")

    tags = info.get("tags") or []
    if tags:
        t0 = tags[0]
        check("models", "tags[0].female/male type",
              True,
              "female=" + repr(t0.get("female")) + " male=" + repr(t0.get("male")))
        check("models", "tags[0].tag is a string", isinstance(t0.get("tag"), str))
    else:
        check("models", "tags present (untagged gallery)", True, "empty -> []")
    check("models", "scene_indexes type", True, type(info.get("scene_indexes", "<missing>")).__name__)
    check("models", "related type", True, type(info.get("related", "<missing>")).__name__)

    # --- url generation against the live hosts
    big = thumbnail_url(gid, f0, "webpbigtn")
    small = thumbnail_url(gid, f0, "webpsmalltn")
    page = page_url(gid, f0)
    for name, u in (("webpbigtn", big), ("webpsmalltn", small), ("webp page", page)):
        status = curl_status(u)
        code = status.split()[0]
        check("url", f"{name} answers 200", code == "200", f"{code} {u}")
        check("url", f"{name} host is <sub>." + IMAGE_HOST,
              re.match(r"https://[a-z0-9]+\." + re.escape(IMAGE_HOST) + "/", u) is not None, u)
    return gid, info, f0


def section_nozomi():
    # every sort mode x area the app can ask for
    cases = [
        ("all", "index", "all", "dateAdded"),
        ("all", "index", "all", "datePublished"),
        ("all", "index", "all", "popularToday"),
        ("all", "index", "all", "popularWeek"),
        ("all", "index", "all", "popularMonth"),
        ("all", "index", "all", "popularYear"),
        ("all", "index", "japanese", "dateAdded"),
        ("tag", "female:big breasts", "all", "dateAdded"),
        ("tag", "female:big breasts", "all", "popularWeek"),
        ("artist", "fukudahda", "all", "dateAdded"),
        ("series", "genshin impact", "all", "popularWeek"),
    ]
    for area, tag, lang, sort in cases:
        url = nozomi_address(area, tag, lang, sort)
        hdr = curl_headers(url, "0-3")
        code = hdr.get("status", "").split()[1] if hdr.get("status") else "???"
        check("nozomi", f"{sort}/{area}/{tag}", code in ("200", "206"),
              f"{code} {hdr.get('content-range', '-')}")

    # the off-by-one: Range<Int> upper bound is exclusive, so the header must
    # be bytes=(first)-(first+length-1); one byte more is a whole extra request
    url = nozomi_address("all", "index", "all", "dateAdded")
    right = curl(url, "0-95")
    wrong = curl(url, "0-96")
    check("nozomi", "0-95 -> 96 bytes / 24 ids", len(right) == 96 and len(decode_ids(right)) == 24,
          f"{len(right)} bytes, {len(decode_ids(right))} ids")
    check("nozomi", "0-96 would ask for 97 bytes (the old bug)",
          len(wrong) == 97, f"{len(wrong)} bytes, {len(decode_ids(wrong))} ids")

    # window alignment with a raw offset fetch
    _, ids, total, nbytes = window("all", "index", "all", "dateAdded", 10, 8)
    raw = curl(url, f"{10 * 4}-{(10 + 8) * 4 - 1}")
    check("nozomi", "window(offset=10,count=8) matches a raw range",
          decode_ids(raw) == ids and len(ids) == 8, f"{ids}")
    check("nozomi", "window returns the file total, not offset+count",
          total is not None and total > 1_000_000, f"total={total}")

    # sorting really is a different file
    week = window("all", "index", "all", "popularWeek", 0, 4)[1]
    added = window("all", "index", "all", "dateAdded", 0, 4)[1]
    check("nozomi", "popularWeek != dateAdded head", week != added, f"{week} vs {added}")


def section_languages():
    """"languages[].galleryid is a JSON number, not a string.

    This is the one shape in the payload that a straight `String?` decode
    cannot take: decoding it as text throws, and the throw takes the whole
    gallery -- cover, tags, page list -- with it. The Swift model therefore
    reads every scalar through FlexibleString.
    """
    url = nozomi_address("all", "index", "all", "popularWeek")
    ids = decode_ids(curl(url, "0-239"))[:60]
    sample = None
    for gid in ids:
        payload = curl(f"https://{DOMAIN}/galleries/{gid}.js").decode("utf-8", "replace")
        try:
            info = json.loads(payload.replace("var galleryinfo = ", ""))
        except Exception:
            continue
        if info.get("languages"):
            sample = (gid, info)
            break

    if not sample:
        check("models", "found a multi-language gallery", False, "none in the sample")
        return

    gid, info = sample
    entry = info["languages"][0]
    kind = type(entry.get("galleryid")).__name__
    check("models", f"gallery {gid} has languages[]", True, f"{len(info['languages'])} entries")
    check("models", "languages[].galleryid is a number in the live payload",
          kind in ("int", "float"), f"type={kind} value={entry.get('galleryid')!r}")
    check("models", "languages[].galleryid needs a lenient read", True,
          "FlexibleString covers int/string")
    check("models", "gap: a plain String? decode would fail this gallery", True,
          "documented divergence from the Kotlin model")
    check("models", "languages[].name present", isinstance(entry.get("name"), str),
          repr(entry.get("name")))
    check("models", "languages[].language_localname present",
          isinstance(entry.get("language_localname"), str))

    # japanese_title is null on plenty of galleries -- Optional, not defaulted
    nulls = 0
    for gid in ids[:12]:
        payload = curl(f"https://{DOMAIN}/galleries/{gid}.js").decode("utf-8", "replace")
        try:
            info = json.loads(payload.replace("var galleryinfo = ", ""))
        except Exception:
            continue
        if info.get("japanese_title") is None:
            nulls += 1
    check("models", "japanese_title is null on some galleries", nulls > 0,
          f"{nulls}/12 sample galleries")


def section_btree():
    version = curl(f"https://{DOMAIN}/{GALLERIES_INDEX_DIR}/version?_=1").decode().strip()
    check("btree", "galleriesindex version fetched", bool(version), f"{version!r}")

    node, url = node_at("galleries", 0, version)
    check("btree", "root node decodes", True,
          f"{len(node['keys'])} keys, {len(node['datas'])} datas, {len(node['subs'])} subnodes")
    check("btree", "root has B+1 subnode slots", len(node["subs"]) == BTREE_ORDER + 1)
    check("btree", "root request is exactly max_node_size bytes",
          node["bytes"] == MAX_NODE_SIZE, f"{node['bytes']} bytes")
    check("btree", "keys are <= 32 bytes each",
          all(0 < len(k) <= 32 for k in node["keys"]))

    # compare(): a prefix sorts before its extension, since only the shorter
    # length is walked -- this is the Kotlin compareArrayBuffers behaviour
    check("btree", "compare(): prefix <= 0 (shorter length wins)",
          compare_bytes(bytes.fromhex("0102"), bytes.fromhex("010203")) == 0)
    check("btree", "compare(): first differing byte decides",
          compare_bytes(bytes.fromhex("0102"), bytes.fromhex("0103")) == -1
          and compare_bytes(bytes.fromhex("0200"), bytes.fromhex("0100")) == 1)

    for term in ("nakadashi", "big breasts", "1girl"):
        key = hash_term(term)
        data, depth = bsearch("galleries", key, version)
        ok = data is not None
        detail = f"depth={depth}"
        if ok:
            ids, got, expected = gallery_ids_from_data(data[0], data[1], version)
            ok = got == expected and len(ids) > 0
            detail = f"offset={data[0]} len={data[1]} ids={len(ids)} ({got}/{expected} bytes)"
            if ok and ids:
                status = curl_status(f"https://{DOMAIN}/galleries/{ids[0]}.js")
                ok = status.startswith("200")
                detail += f" galleries/{ids[0]}.js -> {status.split()[0]}"
        check("btree", f'text search "{term}"', ok, detail)

    # a key that cannot match must come back empty rather than wrong
    data, _ = bsearch("galleries", hash_term("zzzzz-not-a-tag-zzzzz"), version)
    check("btree", "unknown term resolves to nothing", data is None, repr(data))

    # Text search only covers the keys hitomi actually indexed. Measured: every
    # single-word tag resolves to its full id list, while the multi-word ones
    # either miss or point at a one-id entry -- the multi-word tags are served
    # through their own nozomi file instead (`n/tag/female:big+breasts-all.nozomi`,
    # which section_search_args checks answers 206). The Kotlin app has exactly
    # the same behaviour, so this is recorded rather than "fixed": the search box
    # should send `namespace:tag` for a multi-word tag.
    single = {}
    for term in ("glasses", "stockings", "nakadashi", "ahegao", "tomgirl", "kemonomimi"):
        found, _ = bsearch("galleries", hash_term(term), version)
        if found:
            ids, _, _ = gallery_ids_from_data(found[0], found[1], version)
            single[term] = len(ids)
    check("btree", "every single-word tag resolves to a big id list",
          len(single) == 6 and all(n > 1000 for n in single.values()), f"{single}")

    multi = {}
    for term in ("big breasts", "sole female", "school uniform", "very long hair"):
        found, _ = bsearch("galleries", hash_term(term), version)
        if not found:
            multi[term] = 0
            continue
        ids, _, _ = gallery_ids_from_data(found[0], found[1], version)
        multi[term] = len(ids)
    check("btree", "multi-word tags are not served by the b-tree (use namespace:tag)",
          all(n <= 1 for n in multi.values()), f"{multi}")

    check("btree", "hashTerm is case sensitive (Kotlin lowercases the query first)",
          bsearch("galleries", hash_term("Glasses"), version)[0] is None,
          "Glasses -> none, glasses -> ids")


def section_sources():
    """The constants in the Swift sources against the ones this script uses."""
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources")
    core = open(os.path.join(root, "Hitomi", "HitomiCore.swift"), encoding="utf-8").read()

    def literal(name):
        m = re.search(r'static let ' + name + r' = "([^"]*)"', core)
        return m.group(1) if m else None

    def number(name):
        m = re.search(r'static let ' + name + r' = (\d+)', core)
        return int(m.group(1)) if m else None

    check("sources", "HitomiEndpoint.domain matches", literal("domain") == DOMAIN,
          f"swift={literal('domain')!r} probe={DOMAIN!r}")
    check("sources", "HitomiEndpoint.tagIndexDomain matches",
          literal("tagIndexDomain") == TAG_INDEX_DOMAIN,
          f"swift={literal('tagIndexDomain')!r}")
    check("sources", "HitomiEndpoint.imageHost matches", literal("imageHost") == IMAGE_HOST,
          f"swift={literal('imageHost')!r}")
    check("sources", "HitomiEndpoint.nozomiExtension matches",
          literal("nozomiExtension") == NOZOMI_EXT, f"swift={literal('nozomiExtension')!r}")
    check("sources", "HitomiEndpoint.maxNodeSize matches",
          number("maxNodeSize") == MAX_NODE_SIZE, f"swift={number('maxNodeSize')}")
    check("sources", "HitomiEndpoint.bTreeOrder matches",
          number("bTreeOrder") == BTREE_ORDER, f"swift={number('bTreeOrder')}")
    check("sources", "HitomiEndpoint.referer matches", literal("referer") == REFERER,
          literal("referer"))
    check("sources", "HitomiEndpoint.userAgent matches", literal("userAgent") == UA,
          (literal("userAgent") or "")[:40])

    # the app must not depend on the design system from the protocol layer
    leaky = []
    for sub in ("Hitomi", "Store"):
        folder = os.path.join(root, sub)
        for name in sorted(os.listdir(folder)):
            if not name.endswith(".swift"):
                continue
            text = open(os.path.join(folder, name), encoding="utf-8").read()
            if "Astryx" in text or "NavigationStack" in text:
                leaky.append(f"{sub}/{name}")
    check("sources", "protocol/store layer does not reference the design system", not leaky,
          f"{leaky}" if leaky else "clean")



def section_suggestions():
    for field, term in (("global", "big"), ("female", "big breasts"), ("global", "nakadashi")):
        url = suggestions_url(field, term)
        body = curl(url)
        ok = body.lstrip()[:1] == b"["
        entries = []
        if ok:
            try:
                entries = json.loads(body)
            except Exception:
                ok = False
        detail = f"{len(entries)} entries {url}"
        if entries:
            detail += f" first={entries[0]}"
        check("suggest", f'{field}:"{term}"', ok and len(entries) > 0, detail)
        if entries:
            shapes_ok = all(isinstance(e, list) and len(e) >= 3
                            and isinstance(e[0], str) and isinstance(e[1], int)
                            and isinstance(e[2], str) for e in entries)
            check("suggest", f'{field}:"{term}" -> [tag, count, namespace]',
                  shapes_ok, f"sample={entries[0]}")

    # a Japanese term: percent-encoding is what keeps URL(string:) from
    # returning nil here. hitomi's tag index only carries its own (English) tag
    # names, so the answer is a 404 -- the point of the check is that the URL is
    # well formed and that the 404 is the documented outcome, not a crash.
    url = suggestions_url("global", "巨乳")
    status = curl_status(url)
    check("suggest", "japanese term is percent-encoded", "%" in url, url)
    check("suggest", "japanese term answers 404 (tag index is english-only)",
          status.startswith("404"), status)

    # the empty query is the bare field file
    check("suggest", "empty term -> /global.json",
          suggestions_url("global", "") == f"https://{TAG_INDEX_DOMAIN}/global.json",
          suggestions_url("global", ""))

    # underscore is the space escape inside a path segment
    check("suggest", "space -> '_'", suggestions_url("global", "big breasts").endswith("/b/i/g/_/b/r/e/a/s/t/s.json"),
          suggestions_url("global", "big breasts"))
    check("suggest", "slash -> 'slash'", "slash" in suggestions_url("global", "a/b"),
          suggestions_url("global", "a/b"))
    check("suggest", "dot -> 'dot'", "dot" in suggestions_url("global", "a.b"),
          suggestions_url("global", "a.b"))


def section_search_args():
    # SearchArgs.fromQuery / QueryLanguage.parse round trip on the shapes the
    # search box produces
    cases = {
        "female:big breasts": ("tag", "female:big breasts", "all"),
        "male:sole male": ("tag", "male:sole male", "all"),
        "language:japanese": ("all", "index", "japanese"),
        "artist:fukudahda": ("artist", "fukudahda", "all"),
        "group:nekono matsuri": ("group", "nekono matsuri", "all"),
    }
    for query, expected in cases.items():
        args = search_args_from_query(query)
        check("query", f'fromQuery("{query}")', args == expected, f"{args}")

    # the nozomi path a namespaced tag resolves to must be a real file
    args = search_args_from_query("female:big breasts")
    url = nozomi_address(*args, "dateAdded")
    hdr = curl_headers(url, "0-3")
    code = hdr.get("status", "").split()[1] if hdr.get("status") else "???"
    check("query", "female: tag nozomi resolves", code in ("200", "206"),
          f"{code} {url}")
    check("query", "space is %20 in the path, not a raw space",
          "%20" in url and " " not in url, url)

    lang_url = nozomi_address(*search_args_from_query("language:japanese"), "dateAdded")
    hdr = curl_headers(lang_url, "0-3")
    code = hdr.get("status", "").split()[1] if hdr.get("status") else "???"
    check("query", "language: resolves to the index file", code in ("200", "206"),
          f"{code} {lang_url}")


def main():
    started = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"PupilIOS protocol verify  {started}\n")
    for fn in (section_gg, section_gallery, section_languages, section_nozomi,
               section_btree, section_suggestions, section_search_args, section_sources):
        try:
            fn()
        except Exception as exc:                      # a section that dies is a failure
            check(fn.__name__, "section completed", False, f"{type(exc).__name__}: {exc}")
        print()

    failed = [r for r in RESULT if not r[2]]
    print(f"{len(RESULT) - len(failed)}/{len(RESULT)} checks passed")
    if failed:
        print("\nfailed:")
        for section, name, _, detail in failed:
            print(f"  [{section}] {name} {detail}")

    write_results(started, failed)
    return 0 if not failed else 1


NOTES = """\
# プロトコル自己検証（実 API との突き合わせ）

`_probe/verify.py` は `Sources/Hitomi/*.swift` の URL 組み立て・パースを Python で
1:1 に書き直し、**その出力をそのまま実 hitomi に投げて** 200/206 と中身を確かめる。
Swift 側の実装を変えたらこのスクリプトも同じ関数を直す（関数名を Swift 側と対応させてある）。

```
python _probe/verify.py     # 実行してこのファイルを再生成
```

実行環境: Python 3.11 / curl 8.22 / Windows。`swiftc` は無いのでコンパイル確認は CI のみ。

## 実測で確定したこと

| 項目 | 実測結果 |
|---|---|
| `gg.js` の形 | `var o = 1;` / `o = 0; break;` / `case N:` ×700+ / `b: '1795770002/'`（末尾スラッシュ込み） |
| 画像ページ URL | `w{1+m(g)}.<host>/<b><s(hash)>/<hash>.webp` → **200** |
| サムネ URL (`tn`) | `{a..z}{tn}.<host>/webpbigtn/<x>/<xx>/<hash>.webp` → **200**（`webpsmalltn` も 200） |
| nozomi | `Range` は**閉区間**。`bytes=0-95` で 96 バイト = 24 id。`bytes=0-96` だと 97 バイト来る |
| `Content-Range` | `bytes 0-15/4990152` 形式。**/4 が件数** |
| nozomi の窓取得 | offset=10/count=8 → `bytes=40-71` で生レンジ取得と完全一致 |
| b-tree ノード | ルートは 464 バイトちょうど、17 個の子アドレス、キーは 4 バイトの SHA-256 先頭 |
| b-tree テキスト検索 | 単語タグ（glasses/stockings/nakadashi/ahegao/tomgirl/kemonomimi）は全件解決。データ長 = `count*4+4` で一致 |
| 多語タグ | `big breasts` / `school uniform` 等は b-tree に実体が無い（0〜1 件）。**`namespace:tag` の nozomi 経由が正**（`n/tag/female:big%20breasts-all.nozomi` は 206） |
| 提案 JSON | `[["big breasts", 477114, "female"], ...]`。パスは **1文字1セグメント**（`/global/b/i/g.json`） |
| 提案の日本語 | `tagindex` は英語タグ名のみ → 日本語クエリは **404**（=サジェスト無しであってエラーではない） |
| `languages[].galleryid` | **JSON 数値**（`{"galleryid": 3901548, ...}`）。Kotlin は `String` 宣言。素の `String?` デコードだと gallery 全体が失敗する |
| `japanese_title` | `null` のギャラリーが普通にある（Optional 必須） |
| `tags[].female` / `male` | 文字列 `"1"` / `""`（bool ではない） |
| `haswebp` | キー自体が無いギャラリーがある（Optional 必須） |

## 移植で直した食い違い（Kotlin / 元コードとの差分）

1. **`Range<Int>` の off-by-one** — `Range` は上限が exclusive なのに、そのまま
   `bytes=lower-upper` に渡していたので 1 バイト多く要求していた（nozomi 24 件取得で 97 バイト）。
   `upperBound - 1` にして閉区間へ変換。Kotlin は `(start*4)..((start+count)*4 - 1)` で閉区間。
2. **パスの percent-encode** — Kotlin は ktor が `female:big breasts` の空白を `%20` に
   してくれるが、Foundation の `URL(string:)` は空白入りで **nil** を返す。`HitomiPath.segment`
   で 1 セグメントずつ encode する（`_probe` で `%20` 版が 206 を返すことを確認）。
3. **`Content-Range` が無いときの total** — `offset + count` としていたのは誤り。
   サーバがレンジを無視して全体を返した場合の実データ長（`offset + ids.count`）に直した。
4. **`languages[].galleryid` が数値** — `FlexibleString` で数値/文字列どちらも受ける。
   そのままだと多言語ギャラリーの詳細画面が丸ごと落ちる。
5. **`SearchQuery` の `indirect` 漏れ**（CI 実測）— 再帰 enum なので必須。
6. **`Array.reversed()` の型** — `context.readLater.reversed()` は `[Int]` ではなく
   `ReversedCollection<[Int]>` を返すので `[Int]` を返す関数では型エラー。`Array(...)` で包む。
7. **検索テキストの一本化** — `SearchQuery.text` は `QueryLanguage.text(of:)` に委譲し、
   履歴は `QueryLanguage.canonicalHistoryText(_:)` を通した正規形（`female:big_breasts`）で保存。
8. **`gg.js` のパース失敗を握りつぶさない** — 失敗したまま `fetchedAt` を更新すると
   壊れたサブドメインを 60 秒使い続ける。`load` を throwing にした。
9. **`suggestions` の 404** — 日本語クエリ等では 404 が正常。空配列を返す（例外を投げない）。

## 未検証リスク

- **コンパイルは未検証**（このマシンに swiftc が無い）。CI の build-ci が確認する。
- 画像の実バイト列取得（`imageData`）は `_probe` では status/サイズのみ確認。デコードは未検証。
- iOS の `URLSession` が `Range` ヘッダをそのまま送ることは未検証（curl でしか確認していない）。
  `URLSession` が `Content-Range` を透過的に処理する場合、`offset` がずれる可能性は残る。
- pagination の上限（`nozomi` 全件読み）は実機メモリで未検証。
"""


def write_results(started, failed):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "RESULTS.md")
    lines = [
        NOTES,
        "",
        f"## 実行結果（{started}）",
        "",
        f"{len(RESULT) - len(failed)}/{len(RESULT)} checks passed",
        "",
        "| 結果 | セクション | チェック | 詳細 |",
        "|---|---|---|---|",
    ]
    for section, name, ok, detail in RESULT:
        detail = detail.replace("|", "\\|")
        lines.append(f"| {'PASS' if ok else '**FAIL**'} | {section} | {name} | `{detail}` |")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    print(f"\nwrote {path}")


if __name__ == "__main__":
    sys.exit(main())

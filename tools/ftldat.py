#!/usr/bin/env python3
"""ftldat.py - dependency-free tool for FTL's ftl.dat (PKG) archives and .ftl mods.

Run with:  python3 -I tools/ftldat.py <command> ...

Commands
  list <dat> [--long]
  extract <dat> <outdir> [paths...]
  pack-ftl <moddir> <out.ftl>
  patch --base <vanilla.dat> --out <out.dat> <mod1.ftl> [mod2.ftl ...]
  verify <dat> [--full]

PKG format (big-endian), cross-checked against Slipstream Mod Manager's PkgPack.java:
  header : b"PKG\\n", u16 header_size(16), u16 entry_size(20), u32 entry_count,
           u32 names_region_size
  entry  : u32 name_hash, u32 name_offset_and_flags, u32 data_offset,
           u32 data_size, u32 unpacked_size
           name offset = field & 0x00FFFFFF (relative to start of names region)
           flag bit 24 (0x01000000) = data is zlib/deflate compressed
  names  : NUL-terminated ASCII strings, directly after the entry table
  hash   : h = 0; for each byte b: h = rotr32(h, 5) ^ tolower(b)
           (entries are stored sorted by hash)

patch semantics (Slipstream):
  X.append / X.rawappend : content appended (after a newline) to existing file X
  X.rawclobber           : replaces X
  anything else          : replaces or adds the file
  mod-appendix/ is ignored.  Base archive is never modified.
  Minimal support for Slipstream's XML find/modify tags (<mod:findName>,
  <mod:findLike>, <mod:selector>, <mod:setValue>, <mod:removeTag>), which
  Hyperspace.ftl itself uses in its *.xml.append files.
"""
import argparse
import os
import re
import struct
import sys
import tempfile
import zipfile
import zlib

MAGIC = b"PKG\n"
HEADER_SIZE = 16
ENTRY_SIZE = 20
FLAG_DEFLATE = 0x01000000
NAME_MASK = 0x00FFFFFF

TEXT_EXTS = {".xml", ".txt", ".lua", ".json", ".csv", ".ini", ".html", ".htm",
             ".frag", ".vert", ".glsl", ".md"}
STORE_EXTS = {".png", ".ogg", ".wav", ".mp3", ".jpg", ".jpeg", ".ttf", ".otf"}


def path_hash(path):
    h = 0
    for b in path.encode("ascii"):
        if 65 <= b <= 90:
            b += 32
        h = ((h << 27) | (h >> 5)) & 0xFFFFFFFF
        h ^= b
    return h


class Entry:
    __slots__ = ("path", "hash", "deflated", "offset", "size", "unpacked")


class Pkg:
    """Read-only view of a PKG archive."""

    def __init__(self, filename):
        self.filename = filename
        self.f = open(filename, "rb")
        self.f.seek(0, 2)
        self.filesize = self.f.tell()
        self.f.seek(0)
        hdr = self.f.read(HEADER_SIZE)
        if len(hdr) < HEADER_SIZE or hdr[:4] != MAGIC:
            raise ValueError("%s: not a PKG archive (bad magic)" % filename)
        hsize, esize, count, nsize = struct.unpack(">HHII", hdr[4:])
        if hsize != HEADER_SIZE or esize != ENTRY_SIZE:
            raise ValueError("%s: unexpected header/entry size %d/%d" % (filename, hsize, esize))
        if count * esize > self.filesize or nsize > self.filesize:
            raise ValueError("%s: corrupt header (sizes exceed file)" % filename)
        raw = self.f.read(count * esize)
        names = self.f.read(nsize)
        if len(raw) != count * esize or len(names) != nsize:
            raise ValueError("%s: truncated archive" % filename)
        self.names_region_size = nsize
        self.entries = []
        self.by_path = {}
        for i in range(count):
            h, nf, off, size, unp = struct.unpack_from(">IIIII", raw, i * esize)
            if off == 0:
                continue  # null entry (non-repacked Slipstream archive)
            noff = nf & NAME_MASK
            end = names.find(b"\0", noff)
            if end < 0:
                raise ValueError("%s: entry %d has unterminated name" % (filename, i))
            e = Entry()
            e.path = names[noff:end].decode("ascii")
            e.hash = h
            e.deflated = bool(nf & FLAG_DEFLATE)
            e.offset, e.size, e.unpacked = off, size, unp
            self.entries.append(e)
            self.by_path[e.path] = e

    def read_raw(self, e):
        self.f.seek(e.offset)
        data = self.f.read(e.size)
        if len(data) != e.size:
            raise ValueError("%s: truncated data for %s" % (self.filename, e.path))
        return data

    def read(self, e):
        data = self.read_raw(e)
        if e.deflated:
            data = zlib.decompress(data)
        if len(data) != e.unpacked:
            raise ValueError("%s: size mismatch for %s (%d != %d)"
                             % (self.filename, e.path, len(data), e.unpacked))
        return data

    def close(self):
        self.f.close()


# --------------------------------------------------------------------------
# writing
# --------------------------------------------------------------------------

def want_compress(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in STORE_EXTS:
        return False
    return ext in TEXT_EXTS


def write_pkg(out_path, items):
    """items: dict path -> ('raw', Pkg, Entry) | ('data', bytes).
    Writes a fresh archive to out_path."""
    for p in items:
        try:
            p.encode("ascii")
        except UnicodeEncodeError:
            raise ValueError("PKG does not support non-ASCII path: %r" % p)
    prepared = []  # (path, hash, deflated, size, unpacked, src)
    for p, src in items.items():
        if src[0] == "raw":
            _, pkg, e = src
            prepared.append([p, path_hash(p), e.deflated, e.size, e.unpacked, src])
        else:
            data = src[1]
            if want_compress(p) and len(data) > 0:
                packed = zlib.compress(data, 9)
                if len(packed) < len(data):
                    prepared.append([p, path_hash(p), True, len(packed), len(data), ("data", packed)])
                    continue
            prepared.append([p, path_hash(p), False, len(data), len(data), ("data", data)])
    prepared.sort(key=lambda r: (r[1], r[0].lower(), r[0]))

    names = bytearray()
    name_offs = []
    for r in prepared:
        name_offs.append(len(names))
        names += r[0].encode("ascii") + b"\0"
    if len(names) > NAME_MASK:
        raise ValueError("names region too large")
    data_start = HEADER_SIZE + ENTRY_SIZE * len(prepared) + len(names)
    off = data_start
    table = bytearray()
    for r, no in zip(prepared, name_offs):
        table += struct.pack(">IIIII", r[1], no | (FLAG_DEFLATE if r[2] else 0), off, r[3], r[4])
        off += r[3]
    if off > 0xFFFFFFFF:
        raise ValueError("archive would exceed 4 GiB")
    with open(out_path, "wb") as out:
        out.write(MAGIC + struct.pack(">HHII", HEADER_SIZE, ENTRY_SIZE, len(prepared), len(names)))
        out.write(table)
        out.write(names)
        for r in prepared:
            src = r[5]
            if src[0] == "raw":
                out.write(src[1].read_raw(src[2]))
            else:
                out.write(src[1])


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_list(a):
    pkg = Pkg(a.dat)
    for e in sorted(pkg.entries, key=lambda e: e.path):
        if a.long:
            print("%10d %10d %s %s" % (e.unpacked, e.size, "deflate" if e.deflated else "stored ", e.path))
        else:
            print(e.path)
    return 0


def safe_join(root, rel):
    dest = os.path.normpath(os.path.join(root, rel))
    if os.path.commonpath([os.path.abspath(root), os.path.abspath(dest)]) != os.path.abspath(root):
        raise ValueError("unsafe path: %s" % rel)
    return dest


def cmd_extract(a):
    pkg = Pkg(a.dat)
    if a.paths:
        todo, missing = [], []
        for p in a.paths:
            e = pkg.by_path.get(p.lstrip("/"))
            (todo if e else missing).append(e or p)
        for p in missing:
            print("error: %s: not present in %s" % (p, a.dat), file=sys.stderr)
    else:
        todo, missing = sorted(pkg.entries, key=lambda e: e.path), []
    os.makedirs(a.outdir, exist_ok=True)
    for e in todo:
        dest = safe_join(a.outdir, e.path)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(pkg.read(e))
    print("extracted %d file(s)" % len(todo), file=sys.stderr)
    return 1 if missing else 0


def iter_dir_files(root):
    out = []
    for dp, dns, fns in os.walk(root):
        dns.sort()
        for fn in sorted(fns):
            if fn in (".gitkeep", ".DS_Store"):
                continue
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            out.append((rel, full))
    out.sort()
    return out


def cmd_pack_ftl(a):
    if not os.path.isdir(a.moddir):
        print("error: %s is not a directory" % a.moddir, file=sys.stderr)
        return 1
    tmp = a.out + ".tmp"
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    n = 0
    with zipfile.ZipFile(tmp, "w") as z:
        for rel, full in iter_dir_files(a.moddir):
            ext = os.path.splitext(rel)[1].lower()
            zi = zipfile.ZipInfo(rel, (1980, 1, 1, 0, 0, 0))
            zi.external_attr = 0o644 << 16
            zi.create_system = 3
            zi.compress_type = zipfile.ZIP_STORED if ext in (".png", ".ogg") else zipfile.ZIP_DEFLATED
            with open(full, "rb") as f:
                z.writestr(zi, f.read(), compress_type=zi.compress_type, compresslevel=9)
            n += 1
    os.replace(tmp, a.out)
    print("packed %d file(s) -> %s" % (n, a.out), file=sys.stderr)
    return 0


# --- Slipstream-style XML modification tags (minimal subset) ---------------

_MOD_BLOCK = re.compile(r"<mod:(findName|findLike)\b([^>]*)>(.*?)</mod:\1\s*>", re.S)
_ATTR = re.compile(r'([\w:.-]+)\s*=\s*(?:"([^"]*)"|\'([^\']*)\')')


def _attrs(s):
    return {m.group(1): (m.group(2) if m.group(2) is not None else m.group(3)) for m in _ATTR.finditer(s)}


def _apply_mod_block(text, kind, attr_s, body, label):
    attrs = _attrs(attr_s)
    tag = attrs.get("type")
    if not tag:
        raise ValueError("%s: <mod:%s> without type" % (label, kind))
    want = {}
    if kind == "findName":
        if "name" not in attrs:
            raise ValueError("%s: <mod:findName> without name" % label)
        want["name"] = attrs["name"]
    for m in re.finditer(r"<mod:selector\b([^>]*?)/?>", body):
        want.update(_attrs(m.group(1)))
    body_cmds = re.sub(r"<mod:selector\b[^>]*?/?>", "", body)
    set_value = re.search(r"<mod:setValue\s*>(.*?)</mod:setValue\s*>", body_cmds, re.S)
    set_attrs = re.search(r"<mod:setAttributes\b([^>]*?)/?>", body_cmds)
    remove = re.search(r"<mod:removeTag\b[^>]*?/?>", body_cmds)
    leftover = re.sub(r"<mod:setValue\s*>.*?</mod:setValue\s*>|<mod:setAttributes\b[^>]*?/?>|<mod:removeTag\b[^>]*?/?>", "", body_cmds, flags=re.S)
    if "<mod:" in leftover:
        raise ValueError("%s: unsupported <mod:...> command in %r block" % (label, kind))
    elem = re.compile(r"<%s\b([^>]*?)(/?)>" % re.escape(tag))
    out, pos, hits = [], 0, 0
    while True:
        m = elem.search(text, pos)
        if not m:
            break
        have = _attrs(m.group(1))
        if any(have.get(k) != v for k, v in want.items()):
            out.append(text[pos:m.end()])
            pos = m.end()
            continue
        end = m.end()
        if not m.group(2):
            close = re.compile(r"</%s\s*>" % re.escape(tag)).search(text, m.end())
            if not close:
                raise ValueError("%s: unterminated <%s> in target" % (label, tag))
            end = close.end()
        hits += 1
        out.append(text[pos:m.start()])
        if remove:
            pass
        else:
            open_tag, inner, close_tag = m.group(0), "", "</%s>" % tag
            if not m.group(2):
                inner = text[m.end():close.start()]
            if set_attrs:
                new = _attrs(set_attrs.group(1))
                have.update(new)
                a_s = "".join(' %s="%s"' % (k, v) for k, v in have.items())
                open_tag = "<%s%s%s>" % (tag, a_s, "/" if m.group(2) else "")
            if set_value:
                inner = set_value.group(1)
                if m.group(2):
                    open_tag = open_tag[:-2] + ">"
            if m.group(2) and not set_value:
                out.append(open_tag)
            else:
                out.append(open_tag + inner + close_tag)
        pos = end
        if kind == "findName":
            break
    out.append(text[pos:])
    return "".join(out), hits


def apply_append(base_text, add_text, label, warn):
    """Return new text for a .append of add_text onto base_text."""
    if add_text.startswith("﻿"):
        add_text = add_text[1:]
    text = base_text
    plain_parts, pos = [], 0
    for m in _MOD_BLOCK.finditer(add_text):
        plain_parts.append(add_text[pos:m.start()])
        text, hits = _apply_mod_block(text, m.group(1), m.group(2), m.group(3), label)
        if hits == 0:
            warn("%s: <mod:%s%s> matched nothing" % (label, m.group(1), m.group(2).rstrip()))
        pos = m.end()
    plain_parts.append(add_text[pos:])
    plain = "".join(plain_parts)
    if "<mod:" in plain:
        warn("%s: unsupported <mod:...> tag left in appended text" % label)
    if plain.strip() == "":
        return text
    if not text.strip():
        return plain
    # Slipstream semantics: appended XML goes INSIDE the root element, so insert it
    # right before the root's closing tag when the file has one (e.g. </FTL>).
    m_root = re.search(r"<([A-Za-z_][\w.:-]*)[\s>]", text)
    if m_root:
        close = "</%s>" % m_root.group(1)
        idx = text.rfind(close)
        if idx >= 0:
            return text[:idx].rstrip("\n") + "\n" + plain.strip("\n") + "\n" + text[idx:]
    if not text.endswith("\n"):
        text += "\n"
    return text + plain.lstrip("\n")


def cmd_patch(a):
    base_abs = os.path.realpath(a.base)
    out_abs = os.path.realpath(a.out)
    if base_abs == out_abs:
        print("error: --out must differ from --base (base is never modified)", file=sys.stderr)
        return 1
    pkg = Pkg(a.base)
    items = {e.path: ("raw", pkg, e) for e in pkg.entries}
    warnings = []

    def warn(msg):
        warnings.append(msg)
        print("warning: " + msg, file=sys.stderr)

    def current_bytes(p):
        src = items[p]
        return pkg.read(src[2]) if src[0] == "raw" else src[1]

    for modpath in a.mods:
        with zipfile.ZipFile(modpath) as z:
            names = sorted(i.filename for i in z.infolist() if not i.is_dir())
            n_app = n_rep = n_new = 0
            for name in names:
                norm = name.replace("\\", "/")
                while norm.startswith("./"):
                    norm = norm[2:]
                parts = norm.split("/")
                if ".." in parts or norm.startswith("/"):
                    warn("%s: skipping unsafe path %r" % (modpath, name))
                    continue
                if parts[0] == "mod-appendix" or parts[-1] in (".DS_Store", "Thumbs.db"):
                    continue
                data = z.read(name)
                m = re.match(r"^(.*)\.(append|rawappend|rawclobber)$", norm)
                if m and m.group(2) in ("append", "rawappend"):
                    target = m.group(1)
                    if target in items:
                        old = current_bytes(target).decode("utf-8", "surrogateescape")
                        add = data.decode("utf-8", "surrogateescape")
                        if m.group(2) == "append":
                            new = apply_append(old, add, "%s:%s" % (os.path.basename(modpath), norm), warn)
                        else:
                            new = old + ("" if old.endswith("\n") else "\n") + add
                        items[target] = ("data", new.encode("utf-8", "surrogateescape"))
                    else:
                        warn("%s: %s has no base file %s; creating it" % (modpath, norm, target))
                        items[target] = ("data", data)
                    n_app += 1
                    continue
                if m:  # rawclobber
                    norm = m.group(1)
                if norm in items:
                    n_rep += 1
                else:
                    n_new += 1
                items[norm] = ("data", data)
        print("applied %s: %d appended, %d replaced, %d added"
              % (os.path.basename(modpath), n_app, n_rep, n_new), file=sys.stderr)

    outdir = os.path.dirname(out_abs) or "."
    os.makedirs(outdir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".ftldat-", suffix=".tmp", dir=outdir)
    os.close(fd)
    try:
        write_pkg(tmp, items)
        os.replace(tmp, a.out)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    print("wrote %s (%d entries)" % (a.out, len(items)), file=sys.stderr)
    return 0


def cmd_verify(a):
    errs = []
    try:
        pkg = Pkg(a.dat)
    except Exception as ex:
        print("FAIL: %s" % ex)
        return 1
    seen = set()
    ents = pkg.entries
    prev = None
    for e in ents:
        if e.path in seen:
            errs.append("duplicate path %s" % e.path)
        seen.add(e.path)
        if e.offset + e.size > pkg.filesize:
            errs.append("%s: data extends past end of file" % e.path)
        if path_hash(e.path) != e.hash:
            errs.append("%s: hash mismatch (stored %08x, computed %08x)" % (e.path, e.hash, path_hash(e.path)))
        if not e.deflated and e.size != e.unpacked:
            errs.append("%s: stored but sizes differ" % e.path)
        if prev is not None and e.hash < prev:
            errs.append("entries not sorted by hash at %s" % e.path)
        prev = e.hash
    if a.full:
        sample = ents
    else:
        step = max(1, len(ents) // 64)
        sample = ents[::step]
    for e in sample:
        try:
            pkg.read(e)
        except Exception as ex:
            errs.append("%s: %s" % (e.path, ex))
    if errs:
        for x in errs[:50]:
            print("FAIL: " + x)
        print("%d problem(s)" % len(errs))
        return 1
    print("OK: %d entries, %d read back (%s)" % (len(ents), len(sample), "full" if a.full else "sample"))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="ftldat.py", description="FTL ftl.dat / .ftl tool")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list"); p.add_argument("dat"); p.add_argument("--long", action="store_true"); p.set_defaults(fn=cmd_list)
    p = sub.add_parser("extract"); p.add_argument("dat"); p.add_argument("outdir"); p.add_argument("paths", nargs="*"); p.set_defaults(fn=cmd_extract)
    p = sub.add_parser("pack-ftl"); p.add_argument("moddir"); p.add_argument("out"); p.set_defaults(fn=cmd_pack_ftl)
    p = sub.add_parser("patch"); p.add_argument("--base", required=True); p.add_argument("--out", required=True); p.add_argument("mods", nargs="*"); p.set_defaults(fn=cmd_patch)
    p = sub.add_parser("verify"); p.add_argument("dat"); p.add_argument("--full", action="store_true"); p.set_defaults(fn=cmd_verify)
    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except BrokenPipeError:
        return 0
    except (OSError, ValueError, zipfile.BadZipFile, zlib.error) as ex:
        print("error: %s" % ex, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

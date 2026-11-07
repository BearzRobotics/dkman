#!/usr/bin/env python3
"""Compare dkman's word content with groff's for a sample of installed pages."""
import gzip, os, random, re, subprocess, sys, collections, glob

dk = "/home/dakota/de/dkman/zig-out/bin/dkman"
ansi = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;[^\x1b]*\x1b\\")

def text_of(path):
    return gzip.open(path).read() if path.endswith(".gz") else open(path, "rb").read()

def words(s, is_groff=False):
    s = re.sub(r".\x08", "", s)  # backspace overstrikes
    s = ansi.sub("", s)
    if is_groff:
        lines = [l for l in s.split("\n")]
        nz = [i for i, l in enumerate(lines) if l.strip()]
        if len(nz) > 2:
            # drop the page header and footer lines groff adds
            lines[nz[0]] = ""
            lines[nz[-1]] = ""
        s = "\n".join(lines)
    s = re.sub(r"(\w)[-\u2010]\n\s*(\w)", r"\1\2", s)  # hyphenation at line ends
    return re.findall(r"[A-Za-z0-9]+", s.lower())

def groff(path, data):
    mac = "-mdoc" if re.search(rb"^\.Dd", data[:4000], re.M) else "-man"
    env = dict(os.environ, GROFF_NO_SGR="1", LC_ALL="C.UTF-8")
    p = subprocess.run(["groff", "-Tutf8", mac, "-rLL=80n", "-t"], input=data, capture_output=True, env=env, timeout=30)
    return p.stdout.decode("utf8", "replace")

def ours(path):
    p = subprocess.run(["script", "-qec", f"{dk} --no-pager --width 80 -l {path}", "/dev/null"], capture_output=True, timeout=30)
    return p.stdout.decode("utf8", "replace")

def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    pages = [f for d in "1358" for f in glob.glob(f"/usr/share/man/man{d}/*.gz")]
    random.Random(seed).shuffle(pages)
    rows = []
    for f in pages:
        if len(rows) >= n: break
        data = text_of(f)
        if re.match(rb"\s*\.so ", data): continue
        try:
            g = collections.Counter(words(groff(f, data), True))
            o = collections.Counter(words(ours(f)))
        except Exception as e:
            rows.append((f, -1, -1, -1, str(e))); continue
        total = sum(g.values()) or 1
        missing = g - o
        extra = o - g
        rows.append((f, total, sum(missing.values()), sum(extra.values()), " ".join(w for w, _ in missing.most_common(6)) + " | extra: " + " ".join(w for w, _ in extra.most_common(6))))
    rows.sort(key=lambda r: -(r[2] + r[3]) / max(r[1], 1))
    for f, t, m, e, note in rows:
        print(f"{os.path.basename(f):38} words={t:6} missing={m:5} extra={e:5}  {note}")
    tot = sum(r[1] for r in rows if r[1] > 0)
    print("TOTAL words", tot, "missing", sum(r[2] for r in rows if r[1] > 0), "extra", sum(r[3] for r in rows if r[1] > 0))
main()

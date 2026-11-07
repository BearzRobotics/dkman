#!/usr/bin/env python3
"""Layout check: for lines of groff's output, does dkman put the same text at the same indent?"""
import gzip, os, random, re, subprocess, sys, glob

dk = "/home/dakota/de/dkman/zig-out/bin/dkman"
ansi = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;[^\x1b]*\x1b\\")
box = re.compile(r"[│┌┐└┘├┤┬┴┼─]")

def groff(data):
    mac = "-mdoc" if re.search(rb"^\.Dd", data[:4000], re.M) else "-man"
    env = dict(os.environ, GROFF_NO_SGR="1", LC_ALL="C.UTF-8")
    p = subprocess.run(["groff", "-Tutf8", mac, "-rLL=80n", "-t"], input=data, capture_output=True, env=env, timeout=30)
    t = re.sub(r".\x08", "", p.stdout.decode("utf8", "replace"))
    lines = t.split("\n")
    nz = [i for i, l in enumerate(lines) if l.strip()]
    if len(nz) > 2:
        lines[nz[0]] = ""; lines[nz[-1]] = ""
    return lines

def ours(path):
    p = subprocess.run(["script", "-qec", f"{dk} --no-pager --width 80 -l {path}", "/dev/null"], capture_output=True, timeout=30)
    return ansi.sub("", p.stdout.decode("utf8", "replace")).replace("\r", "").split("\n")

def key(line):
    w = re.findall(r"[a-z0-9]+", line.lower())
    return " ".join(w[:3]) if len(w) >= 3 else None

def indent(l): return len(l) - len(l.lstrip(" "))

def main():
    seed = int(sys.argv[1]); n = int(sys.argv[2])
    pages = [f for d in "1358" for f in glob.glob(f"/usr/share/man/man{d}/*.gz")]
    pages += [l.strip() for l in open("/tmp/mdoc_list.txt")]
    random.Random(seed).shuffle(pages)
    seen = found = same = 0
    worst = []
    for f in pages[:n]:
        data = gzip.open(f).read()
        if re.match(rb"\s*\.so ", data): continue
        g = groff(data); o = ours(f)
        pos = {}
        for l in o:
            if box.search(l): continue
            k = key(l)
            if k: pos.setdefault(k, []).append(indent(l))
        s = fo = sm = 0
        for l in g:
            if box.search(l): continue
            k = key(l)
            if not k: continue
            s += 1
            if k in pos and pos[k]:
                fo += 1
                if pos[k].pop(0) == indent(l): sm += 1
        seen += s; found += fo; same += sm
        if fo: worst.append((sm / fo, os.path.basename(f), s, fo, sm))
    worst.sort()
    for r in worst[:5]: print(f"{r[1]:36} lines={r[2]:5} found={r[3]:5} same_indent={r[4]:5} ({100*r[0]:.0f}%)")
    print(f"TOTAL groff lines={seen} found in ours={found} ({100*found/max(seen,1):.0f}%) indent equal={same} ({100*same/max(found,1):.0f}% of found)")
main()

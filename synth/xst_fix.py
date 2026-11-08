import re
import sys

LOCAL = re.compile(r"^\s*localparam (\w+) = (_gv_\1_\d+);$")

for path in sys.argv[1:]:
    subs, out = {}, []
    for line in open(path).read().split("\n"):
        m = LOCAL.match(line)
        if m:
            subs[m.group(1)] = m.group(2)
            continue
        for name, genvar in subs.items():
            line = re.sub(rf"\b{name}\b", genvar, line)
        line = line.replace("function automatic", "function")
        line = re.sub(r"\breg signed \[31:0\] (\w+);", r"integer \1;", line)
        if "endgenerate" in line:
            subs = {}
        out.append(line)
    open(path, "w").write("\n".join(out))

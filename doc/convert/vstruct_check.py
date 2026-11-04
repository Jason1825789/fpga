#!/usr/bin/env python3
"""轻量 Verilog 结构自检:剥离注释/字符串后,检查关键字配平、括号配平、
以及**模块实例化里的端口重复连接**。

只做结构级检查(不替代真正的编译器),用于确认手工编辑没有漏掉 end/endcase、
也没有把同一个端口连两次(后者综合会报 HDL-8007 / HDI-8007)。
用法: python vstruct_check.py <file.v> [file2.v ...]
"""
import re
import sys
from pathlib import Path

PAIRS = [
    ("module", "endmodule"),
    ("function", "endfunction"),
    ("task", "endtask"),
    ("generate", "endgenerate"),
    ("case", "endcase"),
    ("begin", "end"),
    ("fork", "join"),
]


def strip_comments(text: str) -> str:
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))       # 用空格替换, 保留位置与换行
            i = j
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:j]))
            i = j
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:min(j + 1, n)]))
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def count_kw(text: str, kw: str) -> int:
    return len(re.findall(r"(?<![\w`$])" + re.escape(kw) + r"(?![\w$])", text))


def check_duplicate_ports(body: str):
    """检查每个模块实例化里是否有同名端口被连接两次。

    背景:2026-10-05 手工编辑时给 `.seg_data_1` 加了一行、顺手多写了一个
    `.seg_data_2`,括号与关键字全都配平,综合却直接报
    "HDL-8007 / HDI-8007: port 'seg_data_2' is already connected"。
    这里补上这个检查,避免同类错误只能靠综合器发现。
    """
    problems = []
    for m in re.finditer(r"(?m)^\s*([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*\(", body):
        mod_name, inst = m.group(1), m.group(2)
        if mod_name in ("module", "endmodule", "assign", "always", "if", "for"):
            continue
        i = m.end() - 1                       # 实例 "(" 的位置
        depth, j = 0, i
        while j < len(body):                  # 找到配对的 ")"
            if body[j] == "(":
                depth += 1
            elif body[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        chunk = body[i + 1:j]
        seen = set()
        for nm_m in re.finditer(r"\.(\w+)\s*\(", chunk):
            nm = nm_m.group(1)
            if nm in seen:
                line = body[:i + 1 + nm_m.start()].count("\n") + 1
                problems.append((inst, nm, line))
            seen.add(nm)
    return problems


def check(path: Path) -> bool:
    raw = path.read_text(encoding="utf-8", errors="replace")
    body = strip_comments(raw)

    print(f"== {path.name} ==")
    ok = True

    # 括号配平
    for open_c, close_c in (("(", ")"), ("[", "]"), ("{", "}")):
        a, b = body.count(open_c), body.count(close_c)
        flag = "OK " if a == b else "!! "
        if a != b:
            ok = False
        print(f"  {flag}{open_c}{close_c} : {a} / {b}")

    # 关键字配平(注意 case 会同时命中 casex/casez,单独处理)
    opens = {
        "module": count_kw(body, "module"),
        "function": count_kw(body, "function"),
        "task": count_kw(body, "task"),
        "generate": count_kw(body, "generate"),
        "case": len(re.findall(r"(?<![\w`$])case[xz]?(?![\w$])", body)),
        "begin": count_kw(body, "begin"),
        "fork": count_kw(body, "fork"),
    }
    closes = {
        "endmodule": count_kw(body, "endmodule"),
        "endfunction": count_kw(body, "endfunction"),
        "endtask": count_kw(body, "endtask"),
        "endgenerate": count_kw(body, "endgenerate"),
        "endcase": count_kw(body, "endcase"),
        "end": count_kw(body, "end"),
        "join": len(re.findall(r"(?<![\w`$])join(?:_any|_none)?(?![\w$])", body)),
    }
    for (o, c) in PAIRS:
        a, b = opens[o], closes[c]
        flag = "OK " if a == b else "!! "
        if a != b:
            ok = False
        print(f"  {flag}{o:12s} / {c:12s} : {a} / {b}")

    # 实例化端口重复连接(综合器会报 HDL-8007 / HDI-8007)
    dups = check_duplicate_ports(body)
    if dups:
        ok = False
        print("  !! 端口重复连接:")
        for inst, nm, line in dups:
            print(f"     !! 实例 {inst} 的 .{nm} 被连接了两次(第 {line} 行)")
    else:
        print("  OK  端口无重复连接")

    print(f"  -> {'结构配平通过' if ok else '存在配平问题,需人工确认'}")
    return ok


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    all_ok = True
    for arg in sys.argv[1:]:
        p = Path(arg)
        if not p.is_file():
            print(f"跳过(不是文件): {arg}")
            all_ok = False
            continue
        all_ok &= check(p)
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())

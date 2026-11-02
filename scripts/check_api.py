#!/usr/bin/env python3
"""
Статическая проверка кода против Roblox API dump:
  * свойства в Make("Class", { Prop = ... }) и в фабриках part/wedge/Ui.label/...
  * значения Enum.X.Y
  * имена сервисов в game:GetService("X")
Нужен API-Dump.json (Roblox-Client-Tracker). Запуск:
  python3 scripts/check_api.py path/to/API-Dump.json
"""
import json, re, sys, pathlib

dump = json.load(open(sys.argv[1]))
classes = {c["Name"]: c for c in dump["Classes"]}
enums = {e["Name"]: {i["Name"] for i in e["Items"]} for e in dump["Enums"]}

def props_of(cn):
    out = set()
    while cn in classes:
        for m in classes[cn]["Members"]:
            if m["MemberType"] in ("Property",):
                out.add(m["Name"])
        cn = classes[cn].get("Superclass")
    return out

FACTORIES = {
    r'\bpart\(\{': "Part",
    r'\bwedge\(\{': "WedgePart",
    r'\bUi\.label\(\{': "TextLabel",
    r'\bUi\.panel\(\{': "Frame",
    r'\bUi\.button\(\{': "TextButton",
}
SPECIAL = {"Parent", "Attributes", "Tags"}

def table_keys(src, start):
    """start — индекс '{'. Возвращает ключи верхнего уровня и конец таблицы."""
    depth, i, keys = 0, start, []
    line_start = True
    while i < len(src):
        ch = src[i]
        if ch in "{([":
            depth += 1
        elif ch in "})]":
            depth -= 1
            if depth == 0:
                return keys, i
        elif ch == '"':
            j = i + 1
            while j < len(src) and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            i = j
        elif depth == 1:
            m = re.match(r'(?:\{|,|\n)\s*([A-Za-z_]\w*)\s*=(?!=)', src[i - 1:i + 60]) if src[i - 1] in "{,\n" else None
            if m and m.start() == 0:
                keys.append(m.group(1))
        i += 1
    return keys, i

errors = []
files = list(pathlib.Path("src").rglob("*.luau"))
for f in files:
    src = f.read_text()
    lineof = lambda idx: src.count("\n", 0, idx) + 1
    for m in re.finditer(r'Make\("(\w+)",\s*\{', src):
        cn = m.group(1)
        if cn not in classes:
            errors.append(f"{f}:{lineof(m.start())}: unknown class {cn}")
            continue
        keys, _ = table_keys(src, m.end() - 1)
        valid = props_of(cn)
        for k in keys:
            if k not in valid and k not in SPECIAL:
                errors.append(f"{f}:{lineof(m.start())}: {cn} has no property {k}")
    for pat, cn in FACTORIES.items():
        for m in re.finditer(pat, src):
            keys, _ = table_keys(src, m.end() - 1)
            valid = props_of(cn)
            for k in keys:
                if k not in valid and k not in SPECIAL:
                    errors.append(f"{f}:{lineof(m.start())}: {cn} (factory) has no property {k}")
    for m in re.finditer(r'Enum\.(\w+)\.(\w+)', src):
        en, item = m.groups()
        if en not in enums:
            errors.append(f"{f}:{lineof(m.start())}: unknown enum {en}")
        elif item not in enums[en] and item not in ("Value", "Name"):
            errors.append(f"{f}:{lineof(m.start())}: Enum.{en} has no item {item}")
    for m in re.finditer(r'GetService\("(\w+)"\)', src):
        if m.group(1) not in classes:
            errors.append(f"{f}:{lineof(m.start())}: unknown service {m.group(1)}")

# Вызовы методов obj:Name(...) — метод должен существовать хоть у одного класса API,
# у типа данных (CFrame, Vector3, Random, ...) или быть объявлен в нашем коде.
api_methods = set()
for c in dump["Classes"]:
    for m in c["Members"]:
        if m["MemberType"] in ("Function", "Callback"):
            api_methods.add(m["Name"])
DATATYPE_METHODS = {
    "PointToObjectSpace", "PointToWorldSpace", "ToObjectSpace", "ToWorldSpace", "Inverse", "Lerp",
    "VectorToObjectSpace", "VectorToWorldSpace", "ExpandToGrid", "NextInteger", "NextNumber",
    "Connect", "Once", "Wait", "Disconnect", "Dot", "Cross", "FuzzyEq", "Abs", "Floor", "Ceil",
    "Max", "Min", "GetComponents", "ToEulerAnglesXYZ", "ToOrientation", "Orthonormalize",
}
own = set()
for f in files:
    for m in re.finditer(r'function\s+[\w.]+[:.](\w+)\s*\(', f.read_text()):
        own.add(m.group(1))
for f in files:
    src = f.read_text()
    code = re.sub(r'--\[\[.*?\]\]', lambda m: "\n" * m.group(0).count("\n"), src, flags=re.S)
    code = re.sub(r'--[^\n]*', '', code)
    code = re.sub(r'"(?:\\.|[^"\\])*"', '""', code)
    for m in re.finditer(r'[\w\)\]]:(\w+)\(', code):
        name = m.group(1)
        if name not in api_methods and name not in DATATYPE_METHODS and name not in own:
            errors.append(f"{f}:{code.count(chr(10), 0, m.start()) + 1}: unknown method :{name}()")

errors = list(dict.fromkeys(errors))
for e in errors:
    print("✗", e)
print(f"api check: {len(files)} files, {len(errors)} problems")
sys.exit(1 if errors else 0)

#!/usr/bin/env python3
"""Render architecture/workspace.dsl as Mermaid, for embedding in README.md.

GitHub renders Mermaid natively, so the README can carry the C4 component
view and a command flow without committing image files that go stale. The
source of truth stays workspace.dsl - this only projects it.

Usage:
    python3 architecture/dsl_to_mermaid.py component
    python3 architecture/dsl_to_mermaid.py flow GetCommandFlowCurrent
"""

import re
import sys
from pathlib import Path

DSL = Path(__file__).resolve().parent / "workspace.dsl"

# Presentation only: which box each component sits in, and in what order.
GROUPS = [
    ("Driving adapter", ["tcpListener"]),
    ("Composition root", ["dispatcher"]),
    ("Workflows - one per command", ["pingWorkflow", "echoWorkflow", "setWorkflow", "getWorkflow"]),
    ("Domain - pure", ["commandDto", "recordModel", "storePort"]),
    ("Driven adapters", ["keyValueStore", "expiryReaper"]),
    ("Protocol library - pure", ["respProtocol"]),
]


def components(text):
    """ident -> display name, for every `x = component "Name" ...` line."""
    out = {}
    for ident, name in re.findall(r'(\w+)\s*=\s*component\s+"([^"]+)"', text):
        out[ident] = name
    return out


def relationships(text):
    """(src, dst, description, tag) for each model relationship."""
    model = text.split("views {")[0]
    out = []
    for line in model.splitlines():
        m = re.match(r'\s*(\w+) -> (\w+) "([^"]*)"((?:\s+"[^"]*")*)\s*$', line)
        if not m:
            continue
        extras = re.findall(r'"([^"]*)"', m.group(4))
        tag = extras[1] if len(extras) > 1 else ""
        out.append((m.group(1), m.group(2), m.group(3), tag))
    return out


def component_diagram(text):
    names, rels = components(text), relationships(text)
    grouped = {i for _, idents in GROUPS for i in idents}
    lines = ["flowchart TB"]
    for title, idents in GROUPS:
        lines.append(f'    subgraph {title.split()[0].lower()}["{title}"]')
        for i in idents:
            if i in names:
                lines.append(f'        {i}["{names[i]}"]')
        lines.append("    end")
    for i, n in names.items():          # anything not placed above (e.g. Proposed)
        if i not in grouped:
            lines.append(f'    {i}["{n}"]')

    for src, dst, _desc, tag in rels:
        if src not in names or dst not in names:
            continue                     # client -> listener etc. is out of scope here
        if tag in ("Proposed", "Runtime"):
            lines.append(f"    {src} -.-> {dst}")
        else:
            lines.append(f"    {src} --> {dst}")

    lines += [
        "    classDef pure fill:#d8f0e0,stroke:#2d6a4f,color:#000",
        "    classDef adapter fill:#ffd9d9,stroke:#9d0208,color:#000",
        "    classDef proposed fill:#fff,stroke:#d35400,stroke-dasharray:4 3,color:#000",
        "    class pingWorkflow,echoWorkflow,respProtocol,recordModel,commandDto pure",
        "    class tcpListener,keyValueStore adapter",
        "    class expiryReaper proposed",
    ]
    return "\n".join(lines)


def flow_diagram(text, key):
    names = components(text)
    block = text.split(f'dynamic serverProcess "{key}"', 1)[1]
    block = block.split("autoLayout", 1)[0]
    lines = ["sequenceDiagram", "    autonumber"]
    seen, steps = [], []
    for line in block.splitlines():
        m = re.match(r'\s*(\w+) -> (\w+) "([^"]*)"', line)
        if not m:
            continue
        src, dst, desc = m.group(1), m.group(2), m.group(3)
        for p in (src, dst):
            if p not in seen:
                seen.append(p)
        steps.append((src, dst, desc))
    for p in seen:
        lines.append(f'    participant {p} as {names.get(p, "Redis Client")}')
    for src, dst, desc in steps:
        lines.append(f"    {src}->>{dst}: {desc}")
    return "\n".join(lines)


if __name__ == "__main__":
    text = DSL.read_text()
    what = sys.argv[1] if len(sys.argv) > 1 else "component"
    if what == "component":
        print(component_diagram(text))
    else:
        print(flow_diagram(text, sys.argv[2]))

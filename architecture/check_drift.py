#!/usr/bin/env python3
"""Check whether architecture/workspace.dsl's Current-state component graph
still matches the real module dependency graph, as seen by calligraphy
(https://github.com/smunix/calligraphy) reading GHC's own .hie files.

The component-to-module mapping is read from each component's `modules`
property in workspace.dsl, e.g.

    respProtocol = component "RESP Protocol" "..." "..." {
        properties {
            "modules" "Redis.RESP,Redis.RESP.Types,Redis.RESP.Parser"
        }
    }

Components are deliberately coarser than modules: they follow the library's
own encapsulation boundary (`exposed-modules` in the .cabal), so a single
component usually owns several internal modules. Calls *between* modules of
the same component are internal detail and are not checked.

Usage:
    stack build --ghc-options -fwrite-ide-info
    python3 architecture/check_drift.py

Two kinds of drift are reported:
  MISSING       - workspace.dsl documents a Current-state call between two
                   components that no real module dependency backs up.
  UNDOCUMENTED  - a real, direct module-to-module call exists between two
                   mapped components with no path between them in the
                   Current-state C4 graph.

UNDOCUMENTED findings use *transitive* reachability in the C4 graph (not
exact edge matching) - e.g. TCP Listener reaching the In-Memory Key-Value
Store via Command Dispatcher is enough to explain a direct Main -> Table
call at startup. That's a deliberate simplification: this script flags
things worth a human look, it doesn't prove the diagram is wrong.
"""

import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DSL_PATH = REPO_ROOT / "architecture" / "workspace.dsl"

# Build-generated modules that are not part of the architecture at all.
IGNORED_MODULES = {
    "Paths_codecrafters_redis",
}

# Component relationships that are real in the code but that calligraphy
# cannot see, with the reason. calligraphy reports *name resolution* edges,
# so two kinds of real dependency are invisible to it:
#
#   - a reference from inside an `instance` declaration. Every workflow
#     renders its reply through a `ToResp` instance and nothing else, so the
#     whole edge disappears. (The same blind spot is why `layers.dot` draws
#     its instance edges by hand - see architecture/callgraphs/README.md.)
#
# Keyed by DSL *identifier* (not display name), and each entry must carry a
# reason. Anything not listed here is still checked.
BLIND_SPOTS = {
    ("pingWorkflow", "respProtocol"):
        "toResp for Ping.Reply calls simpleString from inside an instance body",
}

# Relationship tags that are not claims about the *current compile-time*
# dependency graph, and so are not checked against calligraphy.
#   Proposed - does not exist yet (ADR-level intent).
#   Runtime  - exists only at runtime: the workflow calls a function value
#              handed to it in its Env, and never imports the adapter. The
#              absence of a compile-time edge here is the dependency
#              inversion working, not drift.
UNCHECKED_TAGS = ("Proposed", "Runtime")


def run_calligraphy():
    candidates = [
        ["calligraphy"],
        ["nix", "shell", "nixpkgs#haskell.packages.ghc984.calligraphy", "--command", "calligraphy"],
    ]
    hie_dirs = list(REPO_ROOT.glob(".stack-work/dist/*/ghc-*/build"))
    if not hie_dirs:
        sys.exit(
            "No .hie files found under .stack-work. Build with:\n"
            "  stack build --ghc-options -fwrite-ide-info"
        )
    args = ["-i", str(hie_dirs[0]), "--collapse-modules", "--stdout-mermaid"]

    last_err = None
    for base in candidates:
        try:
            result = subprocess.run(
                base + args, cwd=REPO_ROOT, capture_output=True, text=True, timeout=60
            )
            if result.returncode == 0:
                return result.stdout
            last_err = result.stderr
        except FileNotFoundError:
            continue
    sys.exit(
        "calligraphy failed (often a GHC/hie version mismatch between the "
        "installed calligraphy and the project's GHC - use a calligraphy "
        f"built against the same GHC version as stack.yaml).\n{last_err or ''}"
    )


def parse_mermaid(text):
    labels = {}
    edges = set()
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r"^(node_\d+)\[(.+)\]$", line)
        if m:
            labels[m.group(1)] = m.group(2)
            continue
        m = re.match(r"^(node_\d+)\s+-\.?->\s+(node_\d+)$", line)
        if m:
            edges.add((m.group(1), m.group(2)))
    module_edges = {(labels[a], labels[b]) for a, b in edges if a in labels and b in labels}
    return module_edges


def transitive_closure(edges):
    reach = {}
    nodes = {n for e in edges for n in e}
    for n in nodes:
        reach[n] = {b for a, b in edges if a == n}
    changed = True
    while changed:
        changed = False
        for n in nodes:
            new = set()
            for m in reach[n]:
                new |= reach.get(m, set())
            if not new <= reach[n]:
                reach[n] |= new
                changed = True
    return reach


def parse_dsl(text):
    model_block = text.split("views {")[0]

    # ident -> (name, [modules]). The module list comes from the component's
    # `modules` property, which may appear a few lines below the declaration.
    components = {}
    current = None
    for line in model_block.splitlines():
        m = re.match(r'^\s*(\w+)\s*=\s*component\s+(.+)$', line)
        if m:
            ident = m.group(1)
            quoted = re.findall(r'"([^"]*)"', m.group(2))
            components[ident] = (quoted[0] if quoted else ident, [])
            current = ident
            continue
        m = re.match(r'^\s*"modules"\s+"([^"]*)"\s*$', line)
        if m and current:
            mods = [x.strip() for x in m.group(1).split(",") if x.strip()]
            components[current] = (components[current][0], mods)
            current = None

    edges = []  # (src, dst, tags)
    ident_pattern = "|".join(re.escape(i) for i in components)
    rel_re = re.compile(rf'^\s*({ident_pattern})\s*->\s*({ident_pattern})\s+(.+)$')
    for line in model_block.splitlines():
        m = rel_re.match(line)
        if not m:
            continue
        src, dst, rest = m.group(1), m.group(2), m.group(3)
        quoted = re.findall(r'"([^"]*)"', rest)
        tags = quoted[2] if len(quoted) >= 3 else ""
        edges.append((src, dst, tags))

    return components, edges


def build_module_map(components):
    comp_modules = {}
    module_to_comp = {}
    for ident, (_, mods) in components.items():
        comp_modules[ident] = set(mods)
        for mod in mods:
            module_to_comp[mod] = ident
    return comp_modules, module_to_comp


def main():
    mermaid = run_calligraphy()
    real_edges = parse_mermaid(mermaid)
    real_reach = transitive_closure(real_edges)

    dsl_text = DSL_PATH.read_text()
    components, dsl_edges = parse_dsl(dsl_text)
    comp_modules, module_to_comp = build_module_map(components)

    current_edges = [
        (s, d)
        for s, d, tags in dsl_edges
        if not any(t in tags for t in UNCHECKED_TAGS)
    ]
    c4_reach = transitive_closure(set(current_edges))

    missing = []
    for src, dst in current_edges:
        src_mods, dst_mods = comp_modules.get(src, set()), comp_modules.get(dst, set())
        backed = any(
            m == n or n in real_reach.get(m, set())
            for m in src_mods
            for n in dst_mods
        )
        if not backed and (src, dst) not in BLIND_SPOTS:
            missing.append((src, dst))

    undocumented = []
    for mod_src, mod_dst in real_edges:
        if mod_src in IGNORED_MODULES or mod_dst in IGNORED_MODULES:
            continue
        comp_src, comp_dst = module_to_comp.get(mod_src), module_to_comp.get(mod_dst)
        if not comp_src or not comp_dst or comp_src == comp_dst:
            continue
        if comp_dst not in c4_reach.get(comp_src, set()):
            undocumented.append((mod_src, mod_dst, comp_src, comp_dst))

    if BLIND_SPOTS:
        print("ASSERTED BY HAND - real in the code, invisible to calligraphy:")
        for (src, dst), why in sorted(BLIND_SPOTS.items()):
            name = lambda i: components[i][0] if i in components else i
            print(f"  {name(src)} -> {name(dst)}")
            print(f"      {why}")
        print()

    ok = True
    if missing:
        ok = False
        print("MISSING - workspace.dsl documents these Current-state calls,")
        print("but no real module dependency backs them up:")
        for src, dst in missing:
            print(f"  {components[src][0]} -> {components[dst][0]}")
        print()

    if undocumented:
        ok = False
        print("UNDOCUMENTED - real module dependencies with no path between")
        print("the mapped components in the Current-state C4 graph:")
        seen = set()
        for mod_src, mod_dst, comp_src, comp_dst in undocumented:
            key = (comp_src, comp_dst)
            if key in seen:
                continue
            seen.add(key)
            print(
                f"  {mod_src} -> {mod_dst}  "
                f"({components[comp_src][0]} -> {components[comp_dst][0]})"
            )
        print()

    if ok:
        print("No drift detected between architecture/workspace.dsl and the real module graph.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())

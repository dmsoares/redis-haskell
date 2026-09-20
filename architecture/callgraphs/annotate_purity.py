#!/usr/bin/env python3
"""Overlay a purity classification onto calligraphy's DOT output.

Every top-level binding in the codebase is placed in exactly one bucket:

  pure       - total, IO-free function or value
  disguised  - pure logic that has been given an effectful type, or that is
               trapped inside an IO closure. These are the refactoring targets.
  effectful  - genuinely performs IO
  port       - a domain-level *declaration* of an effect (a record field whose
               type is an IO action). The effect boundary as data.
  type       - a data/class/constructor node, no code
"""

import re
import sys

PALETTE = {
    "pure":      ("#b7e4c7", "#2d6a4f"),
    "disguised": ("#ffd6a5", "#bc6c25"),
    "effectful": ("#ffadad", "#9d0208"),
    "port":      ("#d8b4fe", "#6d28d9"),
    "type":      ("#e9ecef", "#adb5bd"),
}

# (module, binding) -> bucket.  Anything unlisted defaults to "type".
# Keys are module NAMES, which is what calligraphy labels clusters with by
# default.  `--show-module-path` would give paths instead, but it also makes
# calligraphy match its MODULE arguments against paths, so the two don't mix.
PURITY = {
    "Main": {
        "main": "effectful", "fullQuery": "effectful", "processQuery": "effectful",
        "port": "pure", "segmentSize": "pure", "buffer'": "pure",
    },
    # The root is the ONLY place that names a concrete monad stack. SET and GET
    # now have the same effect shape, so one runner covers both.
    "Redis": {
        "reply": "effectful", "dispatch": "effectful",
        "runEffectful": "effectful", "runPure": "pure",
    },
    "Redis.Data.Command": {
        "fromResp": "pure", "parseInt": "pure", "parseSetOptions": "pure",
    },
    "Redis.Data.Store": {
        "RedisStore": "port", "redisGet": "port", "redisSet": "port",
    },
    # The one real business rule in the program, and it is total.
    "Redis.Data.Record": {
        "expiresAt": "pure", "isLive": "pure", "liveValue": "pure",
    },
    # A map and nothing else: no clock, no expiry decision.
    "Redis.Store": {
        "newRedisStore": "effectful", "get": "effectful", "set": "effectful",
    },
    # --- workflows: constrained, never naming a stack ---------------------
    "Redis.Workflows.Ping": {"workflow": "pure"},
    "Redis.Workflows.Echo": {
        "workflow": "pure", "execute": "pure", "deserializeInput": "pure",
    },
    "Redis.Workflows.Set": {
        "workflow": "effectful", "execute": "effectful",
        "deserializeInput": "pure",
    },
    "Redis.Workflows.Get": {
        "workflow": "effectful", "execute": "effectful",
        "deserializeInput": "pure", "handleResult": "pure",
    },
    "Redis.Workflows.Set.Data": {
        "deserializeOptions": "pure", "getExpiryTime": "pure", "f": "pure",
        "go": "pure", "msToDiff": "pure",
    },
    "Resp.Data": {
        "toResp": "pure", "array": "pure", "bulkString": "pure",
        "integer": "pure", "nullBulkString": "pure", "simpleString": "pure",
        "simpleError": "pure",
    },
    "Resp.Serialization": {
        "crlf": "pure", "fromBytes": "pure", "toBytes": "pure", "pLength": "pure",
        "pArray": "pure", "pBulkString": "pure", "pBulkStringLength": "pure",
        "pCRLF": "pure", "pInteger": "pure", "pNullBulkString": "pure",
        "pRedisValue": "pure", "pSimpleString": "pure", "pSimpleError": "pure",
    },
}

# Bindings worth calling out directly on the diagram.
NOTES = {
    ("Redis.Workflows.Set", "deserializeInput"): "MonadError only",
    ("Redis.Workflows.Get", "deserializeInput"): "no constraint at all",
    ("Redis.Workflows.Get", "handleResult"): "MonadError only",
    ("Redis.Store", "get"): "no clock, no expiry rule",
    ("Resp.Serialization", "pNullBulkString"): "unreachable",
    ("Resp.Serialization", "fromBytes"): "silently drops trailing bytes",
    ("Main", "fullQuery"): "buffer dies with each command",
}

# Module-name prefix -> cluster background.
LAYER_BG = {
    "Redis.Workflows": "#fff8e6",
    "Redis.Data": "#eef7ff",
    "Redis.Store": "#f6f0ff",
    "Resp": "#eefaf3",
    "Main": "#fdf0f0",
    "Redis": "#f0f0f0",
}


def layer_bg(module):
    for prefix, colour in LAYER_BG.items():
        if module == prefix or module.startswith(prefix + "."):
            return colour
    return "whitesmoke"


SEEN = set()


def annotate(lines):
    out = []
    module = None
    for line in lines:
        stripped = line.strip()

        m = re.match(r'label="([A-Z][A-Za-z0-9_.]*)";$', stripped)
        if m:
            module = m.group(1)
            out.append(line)
            continue

        if stripped == 'bgcolor="whitesmoke"' and module:
            out.append(line.replace("whitesmoke", layer_bg(module)))
            continue

        m = re.match(r'(node_\d+) \[label="([^"]+)",shape=(\w+),style="([^"]*)"\];$',
                     stripped)
        if m and module:
            node, label, shape, style = m.groups()
            bucket = PURITY.get(module, {}).get(label, "type")
            SEEN.add(bucket)
            fill, pen = PALETTE[bucket]
            note = NOTES.get((module, label))
            text = f"{label}\\n({note})" if note else label
            indent = line[: len(line) - len(line.lstrip())]
            out.append(
                f'{indent}{node} [label="{text}",shape={shape},style="{style}",'
                f'fillcolor="{fill}",color="{pen}",penwidth=2];\n'
            )
            continue

        out.append(line)
    return out


LEGEND_ROWS = [
    ("pure", "pure", "ellipse"),
    ("disguised", "pure logic,\\neffectful type", "ellipse"),
    ("effectful", "effectful (IO)", "ellipse"),
    ("port", "declared effect\\n(port)", "octagon"),
    ("type", "type / class", "octagon"),
]


def legend():
    rows = [r for r in LEGEND_ROWS if r[0] in SEEN]
    lines = ['    subgraph cluster_legend {',
             '        label="Purity overlay";',
             '        fontsize=18;',
             '        style=filled;',
             '        fillcolor="white";',
             '        color="#adb5bd";']
    for bucket, text, shape in rows:
        fill, pen = PALETTE[bucket]
        lines.append(
            f'        legend_{bucket} [label="{text}",shape={shape},style=filled,'
            f'fillcolor="{fill}",color="{pen}",penwidth=2];'
        )
    for a, b in zip(rows, rows[1:]):
        lines.append(f'        legend_{a[0]} -> legend_{b[0]} [style=invis];')
    lines.append("    }\n")
    return "\n".join(lines)


if __name__ == "__main__":
    src = open(sys.argv[1]).readlines()
    result = annotate(src)
    LEGEND = legend()
    # Insert the legend just before the closing brace.
    for i in range(len(result) - 1, -1, -1):
        if result[i].strip() == "}":
            result.insert(i, LEGEND)
            break
    open(sys.argv[2], "w").writelines(result)

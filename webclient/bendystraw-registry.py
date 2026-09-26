#!/usr/bin/env python3
"""Regenerate or check the Bendystraw operations serve.py may relay.

The browser sends an operation id, the SHA-256 of a GraphQL document, and serve.py forwards only
documents listed in bendystraw-operations.json. This collects every `query` template literal in the
page's scripts (the relay is read-only), so a new or edited document fails the check until the registry is
regenerated. Same format as juicebox.money's registry: {sha256 hex: document}, sorted by id.

    python3 bendystraw-registry.py          # rewrite bendystraw-operations.json
    python3 bendystraw-registry.py --check  # exit 1 when the registry is stale
"""

import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent
REGISTRY = ROOT / "bendystraw-operations.json"
DOCUMENT = re.compile(r"`(\s*query\b[^`]*)`")


def documents(root=ROOT):
    """Every GraphQL query in the page's scripts, by the file and line that holds it."""
    found = {}
    for script in sorted(root.glob("*.js")):
        source = script.read_text(encoding="utf-8").replace("\r\n", "\n")
        for match in DOCUMENT.finditer(source):
            where = f"{script.name}:{source.count(chr(10), 0, match.start()) + 1}"
            text = match[1]
            # The hash must be of the exact string the browser sends: no interpolation or escapes.
            if "${" in text or "\\" in text:
                raise ValueError(f"{where}: a GraphQL document must be a plain template literal")
            found.setdefault(text, where)
    return found


def operation_id(document):
    return hashlib.sha256(document.encode("utf-8")).hexdigest()


def registry_json(root=ROOT):
    registry = {operation_id(document): document for document in documents(root)}
    return json.dumps(dict(sorted(registry.items())), indent=2, ensure_ascii=False) + "\n"


def main(argv):
    expected = registry_json()
    count = len(json.loads(expected))
    if "--check" in argv:
        current = REGISTRY.read_text(encoding="utf-8") if REGISTRY.is_file() else None
        if current != expected:
            print("bendystraw-operations.json is stale; run python3 webclient/bendystraw-registry.py", file=sys.stderr)
            return 1
        print(f"Registry is current for {count} Bendystraw operations.")
        return 0
    REGISTRY.write_text(expected, encoding="utf-8")
    print(f"Wrote {count} Bendystraw operations to {REGISTRY.name}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

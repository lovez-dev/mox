"""Fail when any selected Autobahn case fails; never accept a missing report."""
import json
import sys
from collections import Counter
from pathlib import Path


def check(directory):
    index = json.loads((directory / "index.json").read_text())
    if not index or not all(index.values()):
        raise ValueError("Autobahn report contains no cases")
    failures = []
    counts = Counter()
    for agent, cases in index.items():
        for case, result in cases.items():
            behavior = result["behavior"]
            counts[behavior] += 1
            if behavior not in {"OK", "NON-STRICT", "INFORMATIONAL"}:
                failures.append((agent, case, behavior))
    print(dict(counts))
    for failure in failures:
        print("FAIL", *failure)
    return bool(failures)


if __name__ == "__main__":
    sys.exit(check(Path(sys.argv[1])))

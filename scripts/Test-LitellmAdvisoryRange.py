#!/usr/bin/env python3
"""Gate a pinned LiteLLM image tag against committed GHSA ranges (GW-02, GW-01).

Stdlib only; never touches the network (D-04). Ranges are half-open [lo, hi).
"""

import argparse
import json
from pathlib import Path
import re
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RANGES = ROOT / "config" / "litellm-advisory-ranges.json"
DEFAULT_PIN = ROOT / "envs" / "azure-eastus2" / "litellm-pin.auto.tfvars"

TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")

SELF_TEST_RANGES = [
    {
        "id": "GHSA-7hp6-4w63-5g45",
        "affected": [["1.91.0", "1.100.4"], ["1.101.0", "1.101.3"], ["1.102.0", "1.102.2"], ["1.103.0", "1.103.1"]],
    },
    {"id": "GHSA-g5ff-637f-6q2m", "affected": [["0.0.0", "1.95.0"]]},
]


def load_json(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def parse_tag(tag: str) -> tuple[int, int, int] | None:
    match = TAG_RE.match(tag)
    if not match:
        return None
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def _bound(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.split("."))


def affected_ids(version: tuple[int, int, int], ranges: list[dict]) -> list[str]:
    hits = []
    for entry in ranges:
        for lo, hi in entry["affected"]:
            if _bound(lo) <= version < _bound(hi):
                hits.append(entry["id"])
                break
    return hits


def read_pin(path: Path) -> tuple[str, str]:
    text = path.read_text(encoding="utf-8")
    tag = re.search(r'^\s*litellm_image_tag\s*=\s*"([^"]*)"', text, re.MULTILINE)
    digest = re.search(r'^\s*litellm_image_digest\s*=\s*"([^"]*)"', text, re.MULTILINE)
    return (tag.group(1) if tag else "", digest.group(1) if digest else "")


def check_pin(tag: str, digest: str, ranges: list[dict]) -> list[str]:
    errors = []
    version = parse_tag(tag)
    if version is None:
        errors.append(f"GW-02: tag malformed ({tag!r}); must match ^v<major>.<minor>.<patch>$")
    else:
        for ghsa in affected_ids(version, ranges):
            errors.append(f"GW-02: {tag} is inside {ghsa} range")
    if not DIGEST_RE.match(digest):
        errors.append("GW-01: litellm_image_digest must match ^sha256:[0-9a-f]{64}$")
    return errors


def self_test() -> int:
    good_digest = "sha256:" + "a" * 64
    failures = []
    cases = {
        "GW-02 rejects v1.100.3": ("v1.100.3", False),
        "GW-02 rejects v1.90.3": ("v1.90.3", False),
        "GW-02 rejects v1.91.0 (lower bound inclusive)": ("v1.91.0", False),
        "GW-02 rejects v1.101.2": ("v1.101.2", False),
        "GW-02 rejects v1.102.1": ("v1.102.1", False),
        "GW-02 rejects v1.103.0": ("v1.103.0", False),
        "GW-02 accepts v1.100.4 (upper bound exclusive)": ("v1.100.4", True),
        "GW-02 accepts v1.101.3": ("v1.101.3", True),
        "GW-02 accepts v1.106.2": ("v1.106.2", True),
        "GW-02 rejects rc tag": ("v1.104.0rc1", False),
        "GW-02 rejects -stable tag": ("v1.106.2-stable", False),
        "GW-02 rejects latest": ("latest", False),
        "GW-02 rejects empty tag": ("", False),
        "GW-02 rejects tag without v": ("1.106.2", False),
    }
    for name, (tag, expect_ok) in cases.items():
        ok = not check_pin(tag, good_digest, SELF_TEST_RANGES)
        if ok != expect_ok:
            failures.append(f"{name}: expected ok={expect_ok}")
        else:
            print(f"PASS: {name}")

    # The committed file must still flag the known-bad versions (T-01-02).
    committed = load_json(DEFAULT_RANGES)["ranges"]
    for tag in ("v1.100.3", "v1.90.3"):
        name = f"GW-02 committed ranges reject {tag}"
        if check_pin(tag, good_digest, committed):
            print(f"PASS: {name}")
        else:
            failures.append(f"{name}: committed range file no longer flags it")

    if check_pin("v1.106.2", "sha256:short", SELF_TEST_RANGES):
        print("PASS: GW-01 rejects malformed digest")
    else:
        failures.append("GW-01 rejects malformed digest: expected failure")

    # Pin-file mode.
    with tempfile.TemporaryDirectory() as tmp:
        pin = Path(tmp) / "pin.auto.tfvars"
        pin.write_text('litellm_image_tag = ""\n', encoding="utf-8")
        if check_pin(*read_pin(pin), SELF_TEST_RANGES):
            print("PASS: GW-02 pin file with empty tag fails")
        else:
            failures.append("GW-02 pin file with empty tag fails: expected failure")

        pin.write_text('litellm_image_tag = "v1.106.2"\n', encoding="utf-8")
        errs = check_pin(*read_pin(pin), SELF_TEST_RANGES)
        if errs and errs[0].startswith("GW-01:"):
            print("PASS: GW-01 pin file without digest fails")
        else:
            failures.append(f"GW-01 pin file without digest fails: got {errs}")

        pin.write_text(
            f'litellm_image_tag = "v1.106.2"\nlitellm_image_digest = "{good_digest}"\n',
            encoding="utf-8",
        )
        if not check_pin(*read_pin(pin), SELF_TEST_RANGES):
            print("PASS: GW-02 valid pin file passes")
        else:
            failures.append("GW-02 valid pin file passes: expected success")

    if failures:
        print("FAIL:\n" + "\n".join(failures), file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="run fixture cases and exit")
    parser.add_argument("--pin-file", type=Path, default=DEFAULT_PIN)
    parser.add_argument("--ranges", type=Path, default=DEFAULT_RANGES)
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    if not args.pin_file.is_file():
        print(f"FAIL:\nGW-02: pin file missing ({args.pin_file})", file=sys.stderr)
        return 1
    tag, digest = read_pin(args.pin_file)
    errors = check_pin(tag, digest, load_json(args.ranges)["ranges"])
    if errors:
        print("FAIL:\n" + "\n".join(errors), file=sys.stderr)
        return 1
    print(f"PASS: GW-02 {tag} is outside every advisory range; GW-01 digest well-formed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

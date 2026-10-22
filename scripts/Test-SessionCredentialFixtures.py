#!/usr/bin/env python3
"""Validate pre-review session-credential request fixtures (REQ-CRED-01)."""

import json
from pathlib import Path
import sys

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "contracts" / "schemas" / "session-credential-issuance-request-v0.1.schema.json"
FIXTURE_DIR = ROOT / "contracts" / "fixtures" / "session-credential-issuance"

SCHEMA_CASES = {
    "REQ-CRED-01 accepts a valid issuance request": ("valid-request.json", True),
    "REQ-CRED-01 rejects a non-agent principal_type": ("invalid-principal-type.json", False),
    "REQ-CRED-01 rejects a request without agent_id": ("invalid-missing-agent-id.json", False),
    "REQ-CRED-01 rejects a request without on_behalf_of": ("invalid-missing-on-behalf-of.json", False),
    "REQ-CRED-01 rejects a purpose outside the vocabulary": ("invalid-purpose.json", False),
    "REQ-CRED-01 rejects a non-canonical tenant_id": ("invalid-tenant-id.json", False),
    "REQ-CRED-01 rejects a non-integer requested_ttl_seconds": ("invalid-ttl-type.json", False),
}


def load_json(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def main() -> int:
    validator = Draft202012Validator(load_json(SCHEMA_PATH), format_checker=FormatChecker())
    failures = []

    for name, (filename, expected_valid) in SCHEMA_CASES.items():
        errors = list(validator.iter_errors(load_json(FIXTURE_DIR / filename)))
        actual_valid = not errors
        if actual_valid != expected_valid:
            failures.append(f"{name}: expected valid={expected_valid}; errors={errors}")
        else:
            print(f"PASS: {name}")

    # These are intentionally shape-valid. Their resolution, clamp, and caller
    # checks need an issuer implementation after joint review; keep the cases
    # executable as request fixtures without claiming that JSON Schema can do it.
    for case in load_json(FIXTURE_DIR / "issuer-runtime-cases.json"):
        errors = list(validator.iter_errors(case["request"]))
        if errors:
            failures.append(f"{case['name']}: runtime case must have a valid request shape; errors={errors}")
        else:
            print(f"PASS: {case['name']} (issuer-runtime case retained for post-review implementation)")

    if failures:
        print("FAIL:\n" + "\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

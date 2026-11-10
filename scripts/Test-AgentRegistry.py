#!/usr/bin/env python3
"""Check the popeye agent registry against the vendored program contracts.

POPEYE_v0.4.4 §3, REQ-AGT-26 (and REQ-VOC-12, REQ-VOC-14, the config side of
REQ-AGT-30). Checks:

- vendored files match the SHA-256 (over LF) recorded in VENDORED.md;
- every agent's grants are agent_grants in authz/roles.yaml;
- every agent's task_types match task_type_format and are in authz/task_types.yaml;
- every agent's purposes are in the vocabulary;
- every agent's tenants match tenant_id_format;
- introspection callers include sitcip and nexus, and neither is a relay;
- every registered task type has exactly one close rule, owned by its own system;
- no field outside the identity schema (no capabilities travel in the registry).

Then runs the negative fixtures in config/fixtures/agent-registry/, each of
which must fail with its expected error. Exit 0 on success, 1 on any failure.
"""

import argparse
import hashlib
from pathlib import Path
import re
import sys

import yaml


ROOT = Path(__file__).resolve().parent.parent
VENDORED = ROOT / "config" / "vendored"
DEFAULT_REGISTRY = ROOT / "config" / "agent-registry.example.yaml"
FIXTURES = ROOT / "config" / "fixtures" / "agent-registry"

AGENT_ID_RE = re.compile(r"^[a-z][a-z0-9_-]*$")
SERVICE_ID_RE = re.compile(r"^[a-z][a-z0-9_-]*$")
HASH_ROW_RE = re.compile(r"^\| `([^`]+)` \|.*\| `([0-9a-f]{64})` \|$")

AGENT_FIELDS = {"agent_id", "grants", "task_types", "purposes", "tenants"}
TOP_FIELDS = {"version", "agents", "introspection_callers", "relays", "task_close"}
READ_ONLY_CALLERS = ("sitcip", "nexus")  # D-4: registered callers, never relays

# Negative fixtures and the error each must raise.
NEGATIVE_FIXTURES = {
    "invalid-unregistered-task-type.yaml": "REQ-AGT-26: agents[liam].task_types",
    "invalid-malformed-task-type.yaml": "REQ-VOC-12: agents[liam].task_types",
    "invalid-purpose.yaml": "REQ-AGT-26: agents[liam].purposes",
    "invalid-grant.yaml": "REQ-AGT-26: agents[liam].grants",
    "invalid-tenant-format.yaml": "REQ-AGT-26: agents[liam].tenants",
    "invalid-capability-field.yaml": "REQ-VOC-14: agents[liam]",
    "invalid-sitcip-as-relay.yaml": "REQ-AGT-30: sitcip",
    "invalid-nexus-not-caller.yaml": "REQ-AGT-30: nexus",
    "invalid-close-wrong-owner.yaml": "REQ-AGT-27: task_close[sitcip.investigation]",
    "invalid-close-missing-rule.yaml": "REQ-AGT-27: task_close missing",
}


class RegistryError(Exception):
    pass


def load_yaml(path: Path):
    with path.open(encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def sha256_lf(path: Path) -> str:
    data = path.read_bytes().replace(b"\r\n", b"\n")
    return hashlib.sha256(data).hexdigest()


def check_vendored_hashes() -> list[str]:
    failures = []
    recorded = {}
    for line in (VENDORED / "VENDORED.md").read_text(encoding="utf-8").splitlines():
        match = HASH_ROW_RE.match(line.strip())
        if match:
            recorded[match.group(1)] = match.group(2)
    for name in ("vocabulary.yaml", "authz/task_types.yaml", "authz/roles.yaml"):
        if name not in recorded:
            failures.append(f"VENDORED.md has no hash row for {name}")
            continue
        actual = sha256_lf(VENDORED / name)
        if actual != recorded[name]:
            failures.append(f"{name} SHA-256 {actual} does not match VENDORED.md {recorded[name]}")
    return failures


def load_contracts() -> dict:
    vocabulary = load_yaml(VENDORED / "vocabulary.yaml")
    task_types = load_yaml(VENDORED / "authz" / "task_types.yaml")
    roles = load_yaml(VENDORED / "authz" / "roles.yaml")
    return {
        "purposes": set(vocabulary["purposes"]),
        "tenant_re": re.compile(vocabulary["tenant_id_format"]),
        "task_type_re": re.compile(vocabulary["task_type_format"]),
        "task_types": {t["name"]: t["system"] for t in task_types["task_types"]},
        "grants": {g["name"] for g in roles["agent_grants"]},
    }


def as_list(value, where: str) -> list:
    if not isinstance(value, list) or not value:
        raise RegistryError(f"REQ-AGT-26: {where} must be a non-empty list")
    return value


def check_registry(registry, contracts: dict) -> None:
    """Raise RegistryError on the first violation."""
    if not isinstance(registry, dict):
        raise RegistryError("REQ-AGT-26: registry must be a mapping")
    extra = set(registry) - TOP_FIELDS
    if extra:
        raise RegistryError(f"REQ-VOC-14: registry has unrecognised top-level fields {sorted(extra)}")

    seen_agents = set()
    for agent in as_list(registry.get("agents"), "agents"):
        agent_id = agent.get("agent_id") if isinstance(agent, dict) else None
        if not isinstance(agent_id, str) or not AGENT_ID_RE.match(agent_id):
            raise RegistryError(f"REQ-AGT-26: invalid agent_id {agent_id!r}")
        if agent_id in seen_agents:
            raise RegistryError(f"REQ-AGT-26: duplicate agent_id {agent_id}")
        seen_agents.add(agent_id)
        where = f"agents[{agent_id}]"

        extra = set(agent) - AGENT_FIELDS
        if extra:
            raise RegistryError(
                f"REQ-VOC-14: {where} has fields outside the identity schema {sorted(extra)}; "
                "what an agent may do lives in Cedar policy, not the registry"
            )
        missing = AGENT_FIELDS - set(agent)
        if missing:
            raise RegistryError(f"REQ-AGT-26: {where} is missing {sorted(missing)}")

        for grant in as_list(agent["grants"], f"{where}.grants"):
            if grant not in contracts["grants"]:
                raise RegistryError(f"REQ-AGT-26: {where}.grants: {grant!r} is not an agent_grant in authz/roles.yaml")
        for task_type in as_list(agent["task_types"], f"{where}.task_types"):
            if not isinstance(task_type, str) or not contracts["task_type_re"].match(task_type):
                raise RegistryError(f"REQ-VOC-12: {where}.task_types: {task_type!r} does not match task_type_format")
            if task_type not in contracts["task_types"]:
                raise RegistryError(f"REQ-AGT-26: {where}.task_types: {task_type!r} is not in authz/task_types.yaml")
        for purpose in as_list(agent["purposes"], f"{where}.purposes"):
            if purpose not in contracts["purposes"]:
                raise RegistryError(f"REQ-AGT-26: {where}.purposes: {purpose!r} is not a vocabulary purpose")
        for tenant in as_list(agent["tenants"], f"{where}.tenants"):
            if not isinstance(tenant, str) or not contracts["tenant_re"].match(tenant):
                raise RegistryError(f"REQ-AGT-26: {where}.tenants: {tenant!r} does not match tenant_id_format")

    callers = []
    for entry in as_list(registry.get("introspection_callers"), "introspection_callers"):
        if not isinstance(entry, dict) or set(entry) != {"caller_id"} or not SERVICE_ID_RE.match(str(entry["caller_id"])):
            raise RegistryError(f"REQ-AGT-26: invalid introspection caller entry {entry!r}")
        callers.append(entry["caller_id"])
    if len(callers) != len(set(callers)):
        raise RegistryError("REQ-AGT-26: duplicate introspection caller")

    relays = []
    for entry in registry.get("relays") or []:
        if not isinstance(entry, dict) or set(entry) != {"relay_id"} or not SERVICE_ID_RE.match(str(entry["relay_id"])):
            raise RegistryError(f"REQ-AGT-26: invalid relay entry {entry!r}")
        relays.append(entry["relay_id"])
    if len(relays) != len(set(relays)):
        raise RegistryError("REQ-AGT-26: duplicate relay")

    for service in READ_ONLY_CALLERS:
        if service not in callers:
            raise RegistryError(f"REQ-AGT-30: {service} must be a registered introspection caller (D-4)")
        if service in relays:
            raise RegistryError(f"REQ-AGT-30: {service} is a read-only introspection caller and must not be a relay")

    rules = {}
    for rule in as_list(registry.get("task_close"), "task_close"):
        task_type = rule.get("task_type") if isinstance(rule, dict) else None
        if task_type not in contracts["task_types"]:
            raise RegistryError(f"REQ-AGT-27: task_close entry for unregistered task type {task_type!r}")
        if task_type in rules:
            raise RegistryError(f"REQ-AGT-27: task_close[{task_type}] is defined twice")
        rules[task_type] = rule
        system = contracts["task_types"][task_type]
        where = f"task_close[{task_type}]"
        if rule.get("closed_by") == "session_end_revocation":
            if set(rule) != {"task_type", "closed_by"} or system != "nono":
                raise RegistryError(f"REQ-AGT-27: {where}: only nono tasks close by session-end revocation, with no owner caller")
        elif rule.get("closed_by") == "caller":
            owner = rule.get("owner_caller")
            if set(rule) != {"task_type", "closed_by", "owner_caller"}:
                raise RegistryError(f"REQ-AGT-27: {where} must have exactly task_type, closed_by, owner_caller")
            if owner != system:
                raise RegistryError(f"REQ-AGT-27: {where}: owner_caller {owner!r} is not the owning system {system!r}")
            if owner not in callers:
                raise RegistryError(f"REQ-AGT-27: {where}: owner_caller {owner!r} is not a registered introspection caller")
        else:
            raise RegistryError(f"REQ-AGT-27: {where}: closed_by must be 'caller' or 'session_end_revocation'")
    missing = set(contracts["task_types"]) - set(rules)
    if missing:
        raise RegistryError(f"REQ-AGT-27: task_close missing a rule for {sorted(missing)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    args = parser.parse_args()

    failures = check_vendored_hashes()
    contracts = load_contracts()

    try:
        check_registry(load_yaml(args.registry), contracts)
        print(f"PASS: {args.registry.relative_to(ROOT) if args.registry.is_relative_to(ROOT) else args.registry}")
    except RegistryError as error:
        failures.append(f"{args.registry.name}: {error}")

    present = {p.name for p in FIXTURES.glob("invalid-*.yaml")}
    for name in sorted(present - set(NEGATIVE_FIXTURES)):
        failures.append(f"{name}: negative fixture has no expected error in NEGATIVE_FIXTURES")
    for name, expected in NEGATIVE_FIXTURES.items():
        path = FIXTURES / name
        if not path.exists():
            failures.append(f"{name}: negative fixture is missing")
            continue
        try:
            check_registry(load_yaml(path), contracts)
            failures.append(f"{name}: unexpectedly passed validation")
        except RegistryError as error:
            if not str(error).startswith(expected):
                failures.append(f"{name}: failed with {error!s}, expected {expected}")
            else:
                print(f"PASS: {name} rejected ({error})")

    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

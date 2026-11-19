#!/usr/bin/env python3
"""Validate Nimbus JSON schemas and golden fixtures."""

import json
import re
import sys
from pathlib import Path

SPEC_DIR = Path(__file__).resolve().parent
SCHEMAS_DIR = SPEC_DIR / "schemas"
FIXTURES_DIR = SPEC_DIR / "fixtures"


def check_type(val, expected_type):
    if isinstance(expected_type, list):
        return any(check_type(val, t) for t in expected_type)
    if expected_type == "object":
        return isinstance(val, dict)
    if expected_type == "array":
        return isinstance(val, list)
    if expected_type == "string":
        return isinstance(val, str)
    if expected_type == "integer":
        return isinstance(val, int) and not isinstance(val, bool)
    if expected_type == "number":
        return isinstance(val, (int, float)) and not isinstance(val, bool)
    if expected_type == "boolean":
        return isinstance(val, bool)
    if expected_type == "null":
        return val is None
    return True


def validate_node(data, schema, path="$"):
    errors = []
    if "const" in schema and data != schema["const"]:
        errors.append(f"{path}: expected const {schema['const']!r}, got {data!r}")
    if "type" in schema and not check_type(data, schema["type"]):
        errors.append(f"{path}: expected type {schema['type']}, got {type(data).__name__}")
        return errors
    if "enum" in schema and data not in schema["enum"]:
        errors.append(f"{path}: value {data!r} not in enum {schema['enum']}")
    if isinstance(data, str):
        if "minLength" in schema and len(data) < schema["minLength"]:
            errors.append(f"{path}: string shorter than {schema['minLength']}")
        if "pattern" in schema and not re.match(schema["pattern"], data):
            errors.append(f"{path}: string {data!r} does not match pattern {schema['pattern']}")
    if isinstance(data, (int, float)) and not isinstance(data, bool):
        if "minimum" in schema and data < schema["minimum"]:
            errors.append(f"{path}: {data} < minimum {schema['minimum']}")
        if "maximum" in schema and data > schema["maximum"]:
            errors.append(f"{path}: {data} > maximum {schema['maximum']}")
    if isinstance(data, dict):
        for req in schema.get("required", []):
            if req not in data:
                errors.append(f"{path}: missing required key {req!r}")
        props = schema.get("properties", {})
        add_props = schema.get("additionalProperties")
        for k, v in data.items():
            if k in props:
                errors.extend(validate_node(v, props[k], f"{path}.{k}"))
            elif isinstance(add_props, dict):
                errors.extend(validate_node(v, add_props, f"{path}.{k}"))
    if isinstance(data, list) and "items" in schema:
        for idx, item in enumerate(data):
            errors.extend(validate_node(item, schema["items"], f"{path}[{idx}]"))
    return errors


def main():
    schema_files = sorted(SCHEMAS_DIR.glob("*.schema.json"))
    if not schema_files:
        print("No schema files found!", file=sys.stderr)
        return 1

    schemas = {}
    for sf in schema_files:
        schemas[sf.name] = json.loads(sf.read_text(encoding="utf-8"))
        print(f"Loaded schema: {sf.name}")

    fixture_map = {
        "catalog.json": "catalog.schema.json",
        "device_a_progress.json": "progress.schema.json",
        "device_b_progress.json": "progress.schema.json",
        "device_a_annotations.json": "annotations.schema.json",
        "device_b_annotations.json": "annotations.schema.json",
        "device_a_sessions.json": "sessions.schema.json",
        "device_b_sessions.json": "sessions.schema.json",
    }

    all_errors = []
    for fname, sname in fixture_map.items():
        data = json.loads((FIXTURES_DIR / fname).read_text(encoding="utf-8"))
        errs = validate_node(data, schemas[sname], fname)
        if errs:
            all_errors.extend(errs)
        else:
            print(f"OK: {fname} -> {sname}")

    # Also verify expected_merged.json parses cleanly
    expected = json.loads((FIXTURES_DIR / "expected_merged.json").read_text(encoding="utf-8"))
    assert "progress" in expected and "annotations" in expected and "sessions" in expected
    print("OK: expected_merged.json")

    if all_errors:
        for err in all_errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1
    print("All schemas and fixtures validated successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

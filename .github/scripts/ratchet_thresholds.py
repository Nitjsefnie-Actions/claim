#!/usr/bin/env python3
"""Stage a strictly higher Python coverage floor for the separate ratchet push.

A missing artifact means no raise is justified, so invalid measurements and
records must refuse loudly instead of looking like an ordinary no-op. Only the
ubuntu-latest record is measured here; another schema or cell needs a deliberate
change to the measuring job before it can produce data for the privileged push.
The input record stays untouched, and a lower measurement never loosens it.
"""
import argparse
import json
import math
from pathlib import Path
import sys


def record_number(value, field):
    """Read a finite JSON number, excluding booleans and numeric strings."""
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError(f'{field} must be a finite number')
    return value


def stage(measured, thresholds, out_dir):
    """Validate the record and stage only an improvement at gate precision."""
    record = json.loads(thresholds.read_text(encoding='utf-8'))
    if type(record['schema_version']) is not int or record['schema_version'] != 1:
        raise ValueError('schema_version must be exactly 1')
    python = record['coverage']['python']
    if python['cell'] != 'ubuntu-latest':
        raise ValueError('coverage.python.cell must be exactly "ubuntu-latest"')
    floor = record_number(python['floor'], 'coverage.python.floor')
    record_number(python['measured'], 'coverage.python.measured')
    total = float(measured)
    if not math.isfinite(total):
        raise ValueError('--measured must be a finite number')
    # coverage's fail-under comparison rounds the total at this precision,
    # so a raw improvement inside the same tenth cannot justify a raise.
    ratcheted = round(total, 1)
    if ratcheted > floor:
        python['floor'] = ratcheted
        python['measured'] = ratcheted
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / 'ci-thresholds.json').write_text(
            json.dumps(record, indent=2) + '\n', encoding='utf-8')
        print(f'Coverage floor: {floor} -> {ratcheted}')
    else:
        print(f'No raise justified by this run: {ratcheted} <= {floor}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--measured', required=True)
    parser.add_argument('--thresholds', required=True, type=Path)
    parser.add_argument('--out-dir', required=True, type=Path)
    args = parser.parse_args()
    try:
        stage(args.measured, args.thresholds, args.out_dir)
    except (OSError, ValueError, KeyError, TypeError, OverflowError) as error:
        print(f'{args.thresholds}: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

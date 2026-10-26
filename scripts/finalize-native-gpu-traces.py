#!/usr/bin/env python3
"""Inventory Metal trace files only after the native capture process has exited."""
import hashlib
import json
from pathlib import Path
import sys
import time


def report_digest(report):
    return hashlib.sha256(json.dumps(report, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def finalize(report, directory):
    result = {'schema': 1, 'reportSHA256': report_digest(report),
              'producerSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'stage': 'after-capture-process-exit', 'files': []}
    if not report['supported']:
        result['status'] = 'unsupported'
        return result
    if report['status'] != 'captured':
        raise ValueError('Native capture did not complete')
    previous = None
    stable = 0
    for _ in range(50):
        paths = sorted(p for p in directory.rglob('*') if p.is_file())
        state = [(str(p.relative_to(directory)), p.stat().st_size, p.stat().st_mtime_ns) for p in paths]
        stable = stable + 1 if state and state == previous else 0
        previous = state
        if stable >= 4:
            break
        time.sleep(0.1)
    else:
        raise ValueError('GPU trace files did not settle after capture process exit')
    for path in paths:
        data = path.read_bytes()
        result['files'].append({'path': str(path.relative_to(directory)), 'bytes': len(data),
                                'sha256': hashlib.sha256(data).hexdigest()})
    result['status'] = 'finalized'
    return result


if __name__ == '__main__':
    report, directory, output = map(Path, sys.argv[1:])
    inventory = finalize(json.loads(report.read_text()), directory)
    output.write_text(json.dumps(inventory, indent=2) + '\n')
    print('GPU trace inventory:', inventory['status'], len(inventory['files']), 'files')

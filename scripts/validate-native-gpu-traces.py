#!/usr/bin/env python3
"""Check GPU trace provenance, complete artifact inventory and unchanged native reference pixels."""
import base64
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
from importlib.util import module_from_spec, spec_from_file_location

FINALIZER = Path(__file__).with_name('finalize-native-gpu-traces.py')
_spec = spec_from_file_location('trace_finalizer', FINALIZER)
_finalizer = module_from_spec(_spec)
_spec.loader.exec_module(_finalizer)


def validate(report, reference, directory, script, receipt=None):
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    require(report['schema'] == 1 and report['platform'] == 'macOS', 'Native schema/platform')
    require(bool(report['device']) and bool(report['os']), 'Native device/OS')
    require(report['scriptSHA256'] == hashlib.sha256(script.read_bytes()).hexdigest(), 'Capture script hash')
    require(type(report['supported']) is bool, 'Capture capability flag')
    if receipt is not None:
        require(receipt['schema'] == 1 and receipt['stage'] == 'after-capture-process-exit', 'Final inventory stage')
        require(receipt['reportSHA256'] == _finalizer.report_digest(report), 'Final inventory report binding')
        require(receipt['producerSHA256'] == hashlib.sha256(FINALIZER.read_bytes()).hexdigest(), 'Final inventory producer hash')
    require(report.get('inventoryStage') != 'before-process-exit' or receipt is not None, 'Final inventory required')
    if not report['supported']:
        require(report['status'] == 'unsupported' and report['traces'] == [] and bool(report['reason']), 'Unsupported capture report')
        if receipt is not None:
            require(receipt['status'] == 'unsupported' and receipt['files'] == [], 'Unsupported final inventory')
        return False
    require(report['status'] == 'captured', 'Capture status')
    recipes = {('compact-half-hdr', 'float-hdr', 'RGBAh', 0.3, True),
               ('blur2-float', 'opaque-gradient', 'RGBAf', 2, False),
               ('blur5-half', 'opaque-gradient', 'RGBAh', 5, False)}
    traces = report['traces']
    require(len(traces) == 3 and {(t['name'], t['fixture'], t['workingFormat'], t['radius'], t['clamped'])
                                 for t in traces} == recipes, 'Complete unique GPU trace recipes')
    native = {(c['fixture'], c['workingFormat'], c['radius'], c['clamped']): c['output']
              for c in reference['cases'] if c['filter'] == 'CIGaussianBlur'}
    directory = directory.resolve()
    inventory = set()
    for trace in traces:
        require(type(trace['clamped']) is bool, 'Clamp flag')
        expected = native[trace['fixture'], trace['workingFormat'], trace['radius'], trace['clamped']]
        for key, size in [('float', 24 * 16 * 16), ('rgba', 24 * 16 * 4)]:
            output = trace['output']
            data = base64.b64decode(output[key + 'Base64'], validate=True)
            require(len(data) == size and hashlib.sha256(data).hexdigest() == output[key + 'SHA256'], 'Output bitmap size/hash')
            require(output[key + 'SHA256'] == expected[key + 'SHA256'], 'Captured output differs from native reference')
            if key == 'float':
                require(all(math.isfinite(v[0]) for v in struct.iter_unpack('<f', data)), 'Nonfinite captured pixels')
        require(bool(trace['files']), 'Empty GPU trace inventory')
        for item in trace['files']:
            relative = Path(item['path'])
            require(not relative.is_absolute() and '..' not in relative.parts
                    and relative.parts[0] == trace['name'] + '.gputrace', 'Trace member path')
            path = (directory / relative).resolve()
            require(path.is_relative_to(directory) and path.is_file(), 'Missing/escaping GPU trace member')
            require(str(relative) not in inventory, 'Duplicate trace inventory member')
            inventory.add(str(relative))
            data = path.read_bytes()
            require(len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256'], 'GPU trace member size/hash')
    actual = {str(path.relative_to(directory)) for path in directory.rglob('*') if path.is_file()}
    if receipt is None:
        require(inventory == actual, 'Complete GPU trace inventory')
    else:
        require(receipt['status'] == 'finalized', 'Final inventory status')
        finalized = set()
        roots = {t['name'] + '.gputrace' for t in traces}
        for item in receipt['files']:
            relative = Path(item['path'])
            require(not relative.is_absolute() and '..' not in relative.parts and relative.parts[0] in roots, 'Final trace member path')
            path = (directory / relative).resolve()
            require(path.is_relative_to(directory) and path.is_file(), 'Missing/escaping final trace member')
            require(str(relative) not in finalized, 'Duplicate final inventory member')
            finalized.add(str(relative))
            data = path.read_bytes()
            require(len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256'], 'Final trace member size/hash')
        require(inventory <= finalized and finalized == actual, 'Complete finalized GPU trace inventory')
    return True


if __name__ == '__main__':
    report_path, reference_path, directory, inventory_path = map(Path, sys.argv[1:])
    captured = validate(json.loads(report_path.read_text()), json.loads(reference_path.read_text()), directory,
                        Path(__file__).with_name('capture-coreimage-unsharp.swift'), json.loads(inventory_path.read_text()))
    print('Validated three native GPU trace artifacts and matching reference pixels' if captured
          else 'GPU trace documents are explicitly unsupported on this native device; no execution trace captured')

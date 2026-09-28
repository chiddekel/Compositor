#!/usr/bin/env python3
"""Generate Linux Color Range from the pinned upstream 1.3.4 diff.

Linux additions serialize preview jobs and disable confirmation while computing.
Protected baseline sources are only read; the vendored patch needs no Git objects.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
with tempfile.TemporaryDirectory() as directory:
    staging = Path(directory)
    for name in ['Document/EditorSession.swift', 'Rendering/WandPixels.c', 'Rendering/WandPixels.h']:
        path = staging / 'Compositor' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text((root / 'Compositor' / name).read_text())
    subprocess.run(['patch', '--batch', '--fuzz=0', '-p1', '-d', directory,
                    '-i', str(root / 'linux/patches/color-range.patch')], check=True, stdout=subprocess.DEVNULL)
    def source(name):
        return (staging / 'Compositor' / name).read_text()
    model = source('Document/ColorRangeSelection.swift')
    model = model.replace('import Observation', 'import Observation\nimport CompositorSelectionBackend')
    model = model.replace('    var error: String?', '    var isWorking = false\n    var error: String?')
    model = model.replace('    let image: CGImage\n    let include:', '    let task: ColorRangeTask\n    let image: CGImage\n    let include:')
    model = model.replace('    @ObservationIgnored var generation = 0',
        '    @ObservationIgnored var task = ColorRangeTask()\n    @ObservationIgnored var generation = 0')
    model = model.replace('        edit.generation += 1',
        '        edit.task.cancel()\n        edit.task = ColorRangeTask()\n        edit.generation += 1')
    model = model.replace('guard edit.hasColors else {', 'guard edit.hasColors else { edit.isWorking = false;')
    model = model.replace('let job = ColorRangeJob(image:', 'edit.isWorking = true\n        let job = ColorRangeJob(task: edit.task, image:')
    model = model.replace('await Task.detached(priority: .userInitiated) { Self.colorRangeResult(job) }.value',
        'await ColorRangeWorker.shared.run(job)')
    model = model.replace('            edit.error = result.error?', '            edit.isWorking = false\n            edit.error = result.error?')
    model = model.replace('    func commitColorRange() {\n        guard let edit = colorRange else',
        '    func commitColorRange() {\n        guard let edit = colorRange, !edit.isWorking else')
    model = model.replace('        document?.selection = edit.original\n        colorRange = nil\n    }',
        '        edit.task.cancel()\n        document?.selection = edit.original\n        colorRange = nil\n    }')
    model = model.replace('        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))',
        '        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,\n              point.x < CGFloat(image.width), point.y < CGFloat(image.height) else { return nil }\n        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))')
    model = model.replace('private nonisolated static func colorRangeResult', 'fileprivate nonisolated static func colorRangeResult')
    model = model.replace('private nonisolated struct ColorRangeJob', 'fileprivate nonisolated struct ColorRangeJob')
    model = model.replace('private nonisolated struct ColorRangeResult', 'fileprivate nonisolated struct ColorRangeResult')
    model += '''

// Stale queued work exits before allocating its full-size mask. An already running
// job may finish, but only one job allocates scratch buffers at a time.
nonisolated final class ColorRangeTask: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    func cancel() { lock.lock(); canceled = true; lock.unlock() }
    var isCanceled: Bool { lock.lock(); defer { lock.unlock() }; return canceled }
}

private actor ColorRangeWorker {
    static let shared = ColorRangeWorker()
    func run(_ job: ColorRangeJob) -> ColorRangeResult {
        guard !job.task.isCanceled else { return ColorRangeResult() }
        return EditorSession.colorRangeResult(job)
    }
}
'''
    sheet = source('UI/ColorRangeSheet.swift').replace('Option-click', 'Alt-click').replace('            if let error = edit?.error {',
        '            if edit?.isWorking == true { Text("Updating…").foregroundStyle(.secondary) }\n            if let error = edit?.error {')
    sheet = sheet.replace('.configuredNativeShortcut(.return).buttonStyle(.borderedProminent)',
        '.configuredNativeShortcut(.return).buttonStyle(.borderedProminent)\n                    .disabled(edit?.isWorking == true || edit?.error != nil)')
    outputs = {
        'Sources/Overrides/EditorSession.swift': source('Document/EditorSession.swift'),
        'Sources/Overrides/ColorRangeSelection.swift': model,
        'Sources/Overrides/ColorRangeSheet.swift': sheet,
        'backends/selection/ColorRange.c': '#include "ColorRange.h"\n#include <stdlib.h>\n\n' + 'static inline int color_near' + source('Rendering/WandPixels.c').split('static inline int color_near', 1)[1],
        'backends/selection/include/ColorRange.h': '#pragma once\n#include <stddef.h>\n#include <stdint.h>\n\n' + '// Select > Color Range' + source('Rendering/WandPixels.h').split('// Select > Color Range', 1)[1].split('// Outline of', 1)[0],
    }
for target, content in outputs.items():
    content = '// GENERATED by scripts/gen-color-range.py; see linux/patches/color-range.patch.\n' + content
    path = root / target
    if args.check:
        assert path.read_text() == content, f'Stale generated source: {target}'
    elif not path.exists() or path.read_text() != content:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

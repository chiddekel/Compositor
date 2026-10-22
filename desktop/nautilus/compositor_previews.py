"""Optional Nautilus 4 provider for Compositor directory packages."""
import logging
import os
from pathlib import Path
import sys

import gi
gi.require_version('Nautilus', '4.0')
from gi.repository import Gio, GLib, GObject, Nautilus

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compositor_preview import GioMetadata, PreviewStore

if os.environ.get('COMPOSITOR_PREVIEW_DEBUG') == '1':
    logging.basicConfig(level=logging.DEBUG)


class CompositorPreviews(GObject.GObject, Nautilus.InfoProvider):
    def __init__(self):
        super().__init__()
        cache = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache'))
        self.store = PreviewStore(cache / 'compositor-previews', GioMetadata())
        self.pending = set()
        self.monitors = {}

    def update_file_info(self, file):
        location = file.get_location()
        path = location.get_path()
        logging.debug('Compositor preview request: %s', path)
        if (self.store.root / 'disabled').exists() or not path or Path(path).suffix.lower() != '.comp' or path in self.pending:
            return Nautilus.OperationResult.COMPLETE
        self.pending.add(path)
        def update():
            try:
                changed = self.store.update(path)
            except Exception:
                logging.exception('Compositor preview unavailable for %s', path)
                changed = False
            finish(changed)
            return GLib.SOURCE_REMOVE
        def finish(changed):
            self.pending.discard(path)
            if changed:
                file.invalidate_extension_info()
            watched = Path(path) / 'QuickLook'
            if watched.is_dir() and path not in self.monitors:
                if len(self.monitors) >= 256:
                    self.monitors.pop(next(iter(self.monitors))).cancel()
                monitor = Gio.File.new_for_path(str(watched)).monitor_directory(Gio.FileMonitorFlags.NONE, None)
                monitor.connect('changed', lambda *args: file.invalidate_extension_info())
                self.monitors[path] = monitor
            return GLib.SOURCE_REMOVE
        # Nautilus' embedded Python holds the GIL outside provider calls. Python worker threads can starve
        # indefinitely; a deferred GLib callback reliably runs after the file-info request has returned.
        GLib.idle_add(update, priority=GLib.PRIORITY_LOW)
        return Nautilus.OperationResult.COMPLETE

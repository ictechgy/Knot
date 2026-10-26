# SPDX-License-Identifier: GPL-3.0-only
"""Actual UI source with inert threads, downloader and event loop; no GTK or network."""
import ast
from pathlib import Path
import threading
from types import MethodType, SimpleNamespace
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'ui.py'


class InertLoop:
    def __init__(self):
        self.callbacks = []
        self.progress_schedules = 0
        self.peak_progress_pending = 0

    @property
    def progress_pending(self):
        return sum(callback.__name__ == 'drain' for callback, _ in self.callbacks)

    def idle_add(self, callback, *args):
        self.callbacks.append((callback, args))
        if callback.__name__ == 'drain': self.progress_schedules += 1
        self.peak_progress_pending = max(self.peak_progress_pending, self.progress_pending)
        return len(self.callbacks)

    def take(self, name):
        index = next(index for index, (callback, _) in enumerate(self.callbacks) if callback.__name__ == name)
        return self.callbacks.pop(index)

    def invoke(self, name):
        callback, args = self.take(name)
        return callback(*args)


class ProgressChecks(unittest.TestCase):
    def source_fixture(self, download=None):
        tree = ast.parse(SOURCE.read_text())
        coalescer = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == 'LatestProgress')
        window = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == 'Window')
        methods = [node for node in window.body if isinstance(node, ast.FunctionDef) and node.name in ('run', 'get_package', 'on_close')]
        initializer = next(node for node in window.body if isinstance(node, ast.FunctionDef) and node.name == '__init__')
        # Execute the production delivery guard too, without constructing any widget.
        progress_binding = next(node for node in initializer.body if isinstance(node, ast.Assign)
                                and any(isinstance(target, ast.Attribute) and target.attr == 'download_progress' for target in node.targets))
        loop, workers, events = InertLoop(), [], []

        class Thread:
            def __init__(self, target, **_): self.target = target
            def start(self): workers.append(self.target)

        class Failure(Exception): pass

        namespace = dict(threading=SimpleNamespace(Lock=threading.Lock, Thread=Thread),
                         GLib=SimpleNamespace(idle_add=loop.idle_add), Failure=Failure, download=download)
        exec(compile(ast.Module(body=[coalescer, *methods], type_ignores=[]), str(SOURCE), 'exec'), namespace)
        storage = object()
        state = SimpleNamespace(busy=False, closing=False, operation_token=None, operation_kind=None,
                                cancel=threading.Event(), pin=object(), storage=lambda: storage,
                                progress=SimpleNamespace(set_fraction=lambda value: events.append(('progress', value))),
                                status=SimpleNamespace(set_text=lambda text: events.append(('failure', text))),
                                controls=lambda: None, shutdown=lambda: events.append(('shutdown', None)))
        for name in ('run', 'get_package', 'on_close'):
            setattr(state, name, MethodType(namespace[name], state))
        namespace['self'] = state
        exec(compile(ast.Module(body=[progress_binding], type_ignores=[]), str(SOURCE), 'exec'), namespace)
        return SimpleNamespace(loop=loop, workers=workers, events=events, state=state,
                               LatestProgress=namespace['LatestProgress'], Failure=Failure)

    def test_fragmented_reports_retain_latest_with_one_pending_callback(self):
        fixture = self.source_fixture()
        loop, values = fixture.loop, []
        progress = fixture.LatestProgress(loop.idle_add, lambda token, value: values.append((token, value)))
        token = object(); progress.begin(token)
        for value in range(1, 4097): progress.report(token, value / 4096)
        self.assertEqual(loop.progress_pending, 1)
        self.assertEqual(loop.progress_schedules, 1)
        self.assertIs(loop.invoke('drain'), False)
        self.assertEqual(values, [(token, 1.0)])
        # A subsequent burst must rearm exactly once after the first drain.
        for value in range(1, 4097): progress.report(token, value / 8192)
        self.assertEqual(loop.progress_pending, 1)
        self.assertIs(loop.invoke('drain'), False)
        self.assertEqual(values[-1], (token, 0.5))
        self.assertEqual(loop.peak_progress_pending, 1)
        self.assertEqual(loop.progress_schedules, 2)

    def test_download_bridge_delivers_terminal_progress_before_completion(self):
        captured = []
        def download(pin, store, cancel, progress):
            captured.append((pin, store, cancel))
            for value in range(1, 4097): progress(value / 4096)
            return 'synthetic-package'
        fixture = self.source_fixture(download)
        state, loop = fixture.state, fixture.loop
        state.run(state.get_package, lambda result: fixture.events.append(('complete', result)), kind='download')
        self.assertTrue(state.busy)
        fixture.workers.pop()()
        self.assertEqual(captured, [(state.pin, state.storage(), state.cancel)])
        self.assertEqual(loop.progress_pending, 1)
        self.assertEqual(loop.progress_schedules, 1)
        # Deliberately execute completion ahead of the already queued progress drain.
        self.assertIs(loop.invoke('finish'), False)
        self.assertEqual(fixture.events, [('progress', 1.0), ('complete', 'synthetic-package')])
        self.assertFalse(state.busy)
        self.assertIsNone(state.operation_token)
        self.assertIsNone(state.operation_kind)
        self.assertIs(loop.invoke('drain'), False)
        self.assertEqual(len(fixture.events), 2, 'old progress must not replay after completion')

    def test_cached_download_delivers_terminal_without_progress_reports(self):
        fixture = self.source_fixture(lambda pin, store, cancel, progress: 'synthetic-cached-package')
        state, loop = fixture.state, fixture.loop
        state.run(state.get_package, lambda result: fixture.events.append(('complete', result)), kind='download')
        fixture.workers.pop()()
        self.assertEqual(loop.progress_schedules, 0)
        loop.invoke('finish')
        self.assertEqual(fixture.events, [('progress', 1.0), ('complete', 'synthetic-cached-package')])

    def test_reports_during_delivery_rearm_only_one_callback(self):
        fixture = self.source_fixture()
        loop, values, token = fixture.loop, [], object()
        def deliver(current, value):
            values.append((current, value))
            if len(values) == 1:
                # Script a producer after drain takes its snapshot and before UI
                # delivery returns; no thread timing or real event loop is used.
                progress.report(token, 0.5)
                progress.report(token, 0.75)
        progress = fixture.LatestProgress(loop.idle_add, deliver)
        progress.begin(token); progress.report(token, 0.25)
        loop.invoke('drain')
        self.assertEqual(values, [(token, 0.25)])
        self.assertEqual(loop.progress_pending, 1)
        loop.invoke('drain')
        self.assertEqual(values, [(token, 0.25), (token, 0.75)])
        self.assertEqual(loop.peak_progress_pending, 1)
        self.assertEqual(loop.progress_schedules, 2)

    def test_pending_drain_services_replacement_and_rejects_stale_generation(self):
        fixture = self.source_fixture()
        loop, values = fixture.loop, []
        progress = fixture.LatestProgress(loop.idle_add, lambda token, value: values.append((token, value)))
        old, current = object(), object()
        progress.begin(old); progress.report(old, 0.25); progress.finish(old, 1.0)
        progress.begin(current)
        progress.report(old, 0.9); progress.finish(old, 1.0)
        progress.report(current, 0.5)
        self.assertEqual(loop.progress_pending, 1)
        self.assertEqual(loop.progress_schedules, 1, 'replacement must reuse the pending callback')
        self.assertEqual(values, [(old, 1.0)])
        self.assertIs(loop.invoke('drain'), False)
        self.assertEqual(values, [(old, 1.0), (current, 0.5)])
        progress.finish(current, 1.0)
        progress.report(old, 0.8); progress.report(current, 0.9)
        self.assertEqual(values[-1], (current, 1.0))
        self.assertEqual(loop.progress_pending, 0)

    def test_stale_window_finish_cannot_finish_new_operation(self):
        def download(pin, store, cancel, progress):
            progress(0.5); return 'synthetic-package'
        fixture = self.source_fixture(download)
        state, loop = fixture.state, fixture.loop
        complete = lambda result: fixture.events.append(('complete', result))
        state.run(state.get_package, complete, kind='download'); fixture.workers.pop()()
        old_finish, old_args = loop.take('finish')
        old_finish(*old_args)
        state.run(state.get_package, complete, kind='download')
        current = state.operation_token
        before = list(fixture.events)
        self.assertIs(old_finish(*old_args), False)
        self.assertIs(state.operation_token, current)
        self.assertTrue(state.busy)
        self.assertEqual(fixture.events, before)
        fixture.workers.pop()()
        self.assertEqual(loop.progress_pending, 1)
        self.assertEqual(loop.progress_schedules, 1)
        loop.invoke('drain'); loop.invoke('finish')
        self.assertEqual(fixture.events[-2:], [('progress', 1.0), ('complete', 'synthetic-package')])

    def test_close_revokes_queued_progress_and_completion(self):
        def download(pin, store, cancel, progress):
            progress(0.5); return 'synthetic-package'
        fixture = self.source_fixture(download)
        state, loop = fixture.state, fixture.loop
        state.run(state.get_package, lambda result: fixture.events.append(('complete', result)), kind='download')
        fixture.workers.pop()()
        self.assertIs(state.on_close(), True)
        self.assertTrue(state.cancel.is_set())
        loop.invoke('drain'); loop.invoke('finish')
        self.assertEqual(fixture.events, [('shutdown', None)])
        self.assertFalse(state.busy)

    def test_cancel_revokes_queued_and_late_progress(self):
        callbacks = []
        def download(pin, store, cancel, progress):
            progress(0.5); callbacks.append(progress)
            raise fixture.Failure('cancel')
        fixture = self.source_fixture(download)
        state, loop = fixture.state, fixture.loop
        state.run(state.get_package, lambda result: fixture.events.append(('complete', result)), kind='download')
        fixture.workers.pop()()
        state.cancel.set()
        loop.invoke('drain')
        self.assertEqual(fixture.events, [], 'a queued fraction must not update UI after cancellation')
        loop.invoke('finish')
        self.assertEqual(fixture.events, [('failure', 'cancel')])
        callbacks[0](0.75)
        self.assertEqual(loop.progress_pending, 0)
        self.assertEqual(fixture.events, [('failure', 'cancel')])


if __name__ == '__main__': unittest.main()

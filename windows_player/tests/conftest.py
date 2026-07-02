"""Test import isolation for the flat-module layout (P1-D).

`broker/` and `windows_player/` both ship top-level modules with the SAME names
(`envelope`, `clock`, `discovery`, `pairing`) but different contents. Each test
file does `sys.path.insert(0, <its component dir>)` + `import envelope`, which is
fine in isolation. But under a combined run —

    pytest broker/tests windows_player/tests

— both components share one `sys.modules`, so whichever tree is collected first
caches its `envelope` there and the other tree then imports the wrong one
(AttributeError: module 'envelope' has no attribute 'KEY_MODE_GLOBAL').

A conftest is imported once, up front — too early to fix this, because the
pollution happens later as each test module is imported. So we hook
`pytest_pycollect_makemodule`, which fires per-module right before that module is
imported. Because a conftest's hooks only apply to its own directory subtree,
each tree re-pins its own source dir and evicts any cached copy of a shared
module loaded from a *different* component, so the imminent `import envelope`
resolves to this tree's copy. No production code is modified.
"""
import os
import sys

# Top-level module names that collide between broker/ and windows_player/.
_SHARED = {"envelope", "clock", "discovery", "pairing"}

_SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _isolate() -> None:
    """Pin this component's source dir first and drop any foreign copy of a
    shared module so the next `import` re-resolves it under [_SRC]."""
    if not sys.path or sys.path[0] != _SRC:
        sys.path.insert(0, _SRC)
    for name in _SHARED:
        mod = sys.modules.get(name)
        if mod is None:
            continue
        f = getattr(mod, "__file__", None)
        if f and not os.path.abspath(f).startswith(_SRC + os.sep):
            del sys.modules[name]


def pytest_pycollect_makemodule(module_path, parent):  # noqa: ARG001
    # Runs immediately before pytest imports this directory's test module.
    _isolate()
    return None  # let pytest do the actual import with the cleaned state

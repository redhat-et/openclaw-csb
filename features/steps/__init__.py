import glob
import importlib.util
import os
import sys


_steps_dir = os.path.dirname(__file__)
for _subdir in ("given", "when", "then"):
    _subdir_path = os.path.join(_steps_dir, _subdir)
    if not os.path.isdir(_subdir_path):
        continue
    for _filepath in sorted(glob.glob(os.path.join(_subdir_path, "*.py"))):
        _basename = os.path.basename(_filepath)
        if _basename.startswith("_"):
            continue
        _module_name = f"features.steps.{_subdir}.{_basename[:-3]}"
        _spec = importlib.util.spec_from_file_location(_module_name, _filepath)
        if _spec is None or _spec.loader is None:
            raise ImportError(f"Cannot load Behave step module: {_filepath}")
        _module = importlib.util.module_from_spec(_spec)
        sys.modules[_module_name] = _module
        try:
            _spec.loader.exec_module(_module)
        except Exception:
            sys.modules.pop(_module_name, None)
            raise

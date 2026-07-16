import glob
import importlib.util
import os


_steps_dir = os.path.dirname(__file__)
for _subdir in ("given", "when", "then"):
    _subdir_path = os.path.join(_steps_dir, _subdir)
    if not os.path.isdir(_subdir_path):
        continue
    for _filepath in sorted(glob.glob(os.path.join(_subdir_path, "*.py"))):
        _basename = os.path.basename(_filepath)
        if _basename.startswith("_"):
            continue
        _spec = importlib.util.spec_from_file_location(_basename[:-3], _filepath)
        _module = importlib.util.module_from_spec(_spec)
        _spec.loader.exec_module(_module)

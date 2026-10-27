"""Use the training source from this checkout, independently of dataset locations."""
from pathlib import Path
import hashlib
import sys

SOURCE = Path(__file__).resolve().parents[2] / 'training' / 'device_pdf' / 'src'
sys.path.insert(0, str(SOURCE))
from science_reader_pdf.tagger import train as tagger  # noqa: E402


def source_identity():
    """Bind a run to the actual source, including uncommitted local edits."""
    repo = SOURCE.parents[2]
    files = sorted(SOURCE.rglob('*.py')) + sorted(Path(__file__).parent.glob('*.py'))
    return {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}

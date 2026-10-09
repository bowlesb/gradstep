#!/usr/bin/env python3
"""Build the pipeline worker image locally (no push, no deploy) and run the real ffmpeg encoder on labeled
synthetic fixture audio inside it: mono AAC ~64 kbit/s in MP4 with chapters, verified by ffprobe.

  python3 scripts/check-podcast-encoder.py            # native platform (fast on Apple silicon)
  python3 scripts/check-podcast-encoder.py --amd64    # the deployed linux/amd64 platform (emulated, slower)

Zero spend: no provider, Storage or database call. Needs a local Docker daemon.
"""
import argparse, importlib.util, shutil, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('deploy_pipeline_worker', ROOT / 'scripts/deploy-pipeline-worker.py')
DEPLOY = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(DEPLOY)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--amd64', action='store_true')
    args = parser.parse_args()
    context = DEPLOY.context()
    try:
        tests = context / 'tests/backend'; tests.mkdir(parents=True)
        shutil.copy(ROOT / 'tests/backend/podcast-encoder-container.mjs', tests / 'podcast-encoder-container.mjs')
        dockerfile = (context / 'Dockerfile').read_text() + '\nCOPY tests/backend/podcast-encoder-container.mjs ./tests/backend/\n'
        (context / 'Dockerfile.encoder-check').write_text(dockerfile)
        platform = ['--platform', 'linux/amd64'] if args.amd64 else []
        tag = 'gradstep-pipeline:podcast-encoder-check'
        subprocess.run(['docker', 'build', *platform, '-f', str(context / 'Dockerfile.encoder-check'), '-t', tag, str(context)], check=True)
        subprocess.run(['docker', 'run', '--rm', *platform, '--network', 'none', '--memory', '2g', tag,
                        'node', 'tests/backend/podcast-encoder-container.mjs'], check=True)
    finally:
        shutil.rmtree(context, ignore_errors=True)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Select only manifest-backed targets for a manually dispatched CI matrix."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def matrix(selection, root=ROOT):
    directory = root / 'targets'
    targets = sorted(str(p.parent.relative_to(directory))
                     for p in directory.glob('*/*/manifest.txt'))
    if not targets:
        raise ValueError('no target manifests found')
    if selection == 'all':
        return {'target': targets}
    if selection not in targets:
        raise ValueError('unknown target selection')
    return {'target': [selection]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target')
    args = parser.parse_args()
    try:
        print(json.dumps(matrix(args.target), separators=(',', ':')))
    except ValueError as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()

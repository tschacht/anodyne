#!/usr/bin/env python3
"""Run one command with a deterministic wall-clock timeout."""

import argparse
import os
import signal
import subprocess
import sys
import re


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--minimum-examples", type=int)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.seconds <= 0 or not command:
        parser.error("a positive timeout and command are required")
    if args.minimum_examples is not None and args.minimum_examples < 1:
        parser.error("--minimum-examples must be positive")

    capture = args.minimum_examples is not None
    process = subprocess.Popen(
        command,
        start_new_session=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        text=capture,
    )
    try:
        output, _ = process.communicate(timeout=args.seconds)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        print(f"TIMEOUT after {args.seconds:g}s: {' '.join(command)}", file=sys.stderr)
        return 124
    if output is not None:
        sys.stdout.write(output)
    if process.returncode != 0 or args.minimum_examples is None:
        return process.returncode
    summaries = re.findall(
        r"(\d+)\s+success(?:es)?\s*/\s*(\d+)\s+failures?\s*/\s*"
        r"(\d+)\s+errors?\s*/\s*(\d+)\s+pending",
        output or "",
    )
    if not summaries:
        print("unable to read Busted discovered-example count", file=sys.stderr)
        return 2
    discovered = sum(int(value) for value in summaries[-1])
    if discovered < args.minimum_examples:
        print(
            f"Busted discovered {discovered} examples; minimum is {args.minimum_examples}",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

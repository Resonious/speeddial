#!/usr/bin/env python3
"""Reject Android release mappings that break shared_preferences JNI calls."""

import pathlib
import sys

JNI_TYPES = (
    "kotlin.Unit",
    "kotlin.Result",
    "kotlin.Result$Failure",
    "kotlin.coroutines.Continuation",
    "kotlin.coroutines.intrinsics.CoroutineSingletons",
    "kotlin.coroutines.intrinsics.IntrinsicsKt",
)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check_android_jni.py <release/mapping.txt>")
    path = pathlib.Path(sys.argv[1])
    mappings = set(path.read_text().splitlines())
    missing = [name for name in JNI_TYPES if f"{name} -> {name}:" not in mappings]
    if missing:
        raise SystemExit(
            f"{path}: JNI types were renamed or removed: {', '.join(missing)}"
        )
    print(f"{path}: Kotlin JNI names preserved")


if __name__ == "__main__":
    main()

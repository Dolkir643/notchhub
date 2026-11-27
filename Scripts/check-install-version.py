#!/usr/bin/env python3
"""Проверка перед запуском сборки, использующей общие данные NotchHub."""
import plistlib
import re
import sys
from pathlib import Path


def number(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        raise ValueError("ожидался числовой номер версии")
    parts = [int(part) for part in value.split(".")]
    while parts and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def identity(plist):
    with plist.open("rb") as source:
        info = plistlib.load(source)
    if info["CFBundleIdentifier"] != "name.notchhub.NotchHub":
        raise ValueError("другой идентификатор приложения")
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    return (number(version), number(build)), f"{version} ({build})"


def check(candidate_plist, installed_app):
    candidate, candidate_name = identity(candidate_plist)
    if not installed_app.exists() and not installed_app.is_symlink():
        return
    installed, installed_name = identity(installed_app / "Contents" / "Info.plist")
    if candidate < installed:
        raise ValueError(
            f"установлена версия {installed_name}, выбрана более старая {candidate_name}. "
            "Старая версия может удалить закреплённые файлы с Полки."
        )


if __name__ == "__main__":
    try:
        check(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, KeyError, ValueError, plistlib.InvalidFileException) as error:
        sys.exit(f"NotchHub: запуск остановлен — {error}")

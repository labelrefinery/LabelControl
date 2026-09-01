"""Rendering paths a person can read.

The run root is long and identical on every row, so printing it in full pushes
the part that differs -- which scene, which round -- off the side of the table.
"""

from std.os import getenv


def short_path(path: String, root: String) -> String:
    """A path a person can read: relative to the run root where possible.

    The run root is long and identical on every row, so printing it in full
    pushes the part that differs -- which scene, which round -- off the side of
    the table. Falls back to `~` for anything under home, then to the last two
    segments, so a path from somewhere else is still recognisable without being
    a full line of text.
    """
    if root.byte_length() > 0 and path.startswith(root):
        var rest = String(path.removeprefix(root))
        return String(rest.removeprefix("/"))

    var home = getenv("HOME", "")
    if home.byte_length() > 0 and path.startswith(home):
        return String("~") + String(path.removeprefix(home))

    var parts = path.split("/")
    if len(parts) <= 2:
        return path.copy()
    return String("…/") + String(parts[len(parts) - 2]) + "/" + String(
        parts[len(parts) - 1]
    )

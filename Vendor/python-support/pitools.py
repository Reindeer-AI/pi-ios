"""Commands a-Shell's toolbox lacks: pip, which, and small stand-ins for coreutils. Each covers the options agents and
scripts commonly use, not every GNU option.

The build installs a copy of this file in the app's bin folder under each command's name, with a `#!/usr/bin/env
python3` line, which ios_system runs as a command (in pipelines too); the name it runs under picks the command.
"""

import hashlib
import os
import sys
import tempfile
import zipfile

NAME = os.path.basename(sys.argv[0])


def fail(message):
    print(f"{NAME}: {message}", file=sys.stderr)
    sys.exit(1)


def lines(names):
    """Lines of the named files, or of stdin with no names or "-"."""
    if not names:
        names = ["-"]
    for name in names:
        if name == "-":
            yield from sys.stdin
        else:
            with open(name, encoding="utf-8", errors="surrogateescape") as file:
                yield from file


def selection(spec):
    """A predicate for 1-based positions in a cut list such as 1,3-5,7-."""
    spans = []
    for part in spec.split(","):
        start, dash, end = part.partition("-")
        if dash:
            spans.append((int(start) if start else 1, int(end) if end else None))
        else:
            spans.append((int(part), int(part)))
    return lambda n: any(low <= n and (high is None or n <= high) for low, high in spans)


def pip(arguments):
    """pip is Python's own module; there is no separate pip program."""
    import runpy

    sys.argv = ["pip", *arguments]
    runpy.run_module("pip", run_name="__main__", alter_sys=True)


def which(arguments):
    found_all = True
    for name in (a for a in arguments if not a.startswith("-")):
        for folder in os.environ.get("PATH", "").split(os.pathsep):
            path = os.path.join(folder, name)
            # iOS reports no execute permission for the app's own files, so any file on PATH counts.
            if os.path.isfile(path):
                print(path)
                break
        else:
            found_all = False
    sys.exit(0 if found_all else 1)


def cut(arguments):
    delimiter, fields, characters, only_delimited, names = "\t", None, None, False, []
    while arguments:
        argument = arguments.pop(0)
        if argument.startswith("--") and "=" in argument:
            option, value = argument.split("=", 1)
            argument = {"--delimiter": "-d", "--fields": "-f", "--characters": "-c", "--bytes": "-b"}.get(option, option)
        elif argument in ("-d", "-f", "-c", "-b"):
            value = arguments.pop(0)
        elif argument[:2] in ("-d", "-f", "-c", "-b") and len(argument) > 2:
            argument, value = argument[:2], argument[2:]
        elif argument in ("-s", "--only-delimited"):
            only_delimited = True
            continue
        else:
            names.append(argument)
            continue
        if argument == "-d":
            delimiter = value
        elif argument == "-f":
            fields = selection(value)
        elif argument in ("-c", "-b"):
            characters = selection(value)
        else:
            fail(f"unsupported option {argument}")
    if fields is None and characters is None:
        fail("specify a list of fields (-f) or characters (-c)")
    for line in lines(names):
        line = line.rstrip("\n")
        if characters:
            print("".join(c for n, c in enumerate(line, 1) if characters(n)))
        elif delimiter not in line:
            if not only_delimited:
                print(line)
        else:
            print(delimiter.join(part for n, part in enumerate(line.split(delimiter), 1) if fields(n)))


def seq(arguments):
    separator, width = "\n", False
    numbers = []
    while arguments:
        argument = arguments.pop(0)
        if argument == "-s":
            separator = arguments.pop(0)
        elif argument.startswith("-s") and len(argument) > 2:
            separator = argument[2:]
        elif argument == "-w":
            width = True
        else:
            numbers.append(float(argument) if "." in argument else int(argument))
    if not 1 <= len(numbers) <= 3:
        fail("usage: seq [-s separator] [-w] [first [step]] last")
    if len(numbers) == 1:
        first, step, last = 1, 1, numbers[0]
    elif len(numbers) == 2:
        first, step, last = numbers[0], 1, numbers[1]
    else:
        first, step, last = numbers
    if step == 0:
        fail("step must not be zero")
    values = []
    value = first
    while (step > 0 and value <= last) or (step < 0 and value >= last):
        values.append(value)
        value += step
    texts = [str(v) for v in values]
    if width:
        size = max((len(t) for t in texts), default=0)
        texts = [t.zfill(size) for t in texts]
    if texts:
        print(separator.join(texts))


def mktemp(arguments):
    directory = "-d" in arguments
    rest = [a for a in arguments if a not in ("-d", "-q", "-u", "-t")]
    template = rest[-1] if rest else "tmp.XXXXXXXXXX"
    random = len(template) - len(template.rstrip("X"))
    prefix = template[: len(template) - random] if random else template + "."
    folder, prefix = os.path.split(prefix)
    folder = folder or os.environ.get("TMPDIR") or tempfile.gettempdir()
    if directory:
        print(tempfile.mkdtemp(prefix=prefix, dir=folder))
    else:
        handle, path = tempfile.mkstemp(prefix=prefix, dir=folder)
        os.close(handle)
        print(path)


def digest(algorithm, arguments):
    names = [a for a in arguments if not a.startswith("-") or a == "-"] or ["-"]
    for name in names:
        hasher = hashlib.new(algorithm)
        if name == "-":
            hasher.update(sys.stdin.buffer.read())
        else:
            with open(name, "rb") as file:
                for block in iter(lambda: file.read(1 << 20), b""):
                    hasher.update(block)
        print(f"{hasher.hexdigest()}  {name}")


def shasum(arguments):
    algorithm = "sha1"
    if "-a" in arguments:
        index = arguments.index("-a")
        algorithm = "sha" + arguments[index + 1]
        del arguments[index : index + 2]
    digest(algorithm, arguments)


def zip_(arguments):
    recursive = False
    paths = []
    for argument in arguments:
        if argument.startswith("-"):
            recursive = recursive or "r" in argument
        else:
            paths.append(argument)
    if len(paths) < 2:
        fail("usage: zip [-r] archive.zip path...")
    archive, *members = paths
    with zipfile.ZipFile(archive, "a", zipfile.ZIP_DEFLATED) as output:
        for member in members:
            if os.path.isdir(member) and recursive:
                for root, folders, files in os.walk(member):
                    folders.sort()
                    for name in sorted(files):
                        output.write(os.path.join(root, name))
            else:
                output.write(member)


def unzip(arguments):
    destination, listing, quiet, archive = ".", False, False, None
    while arguments:
        argument = arguments.pop(0)
        if argument == "-d":
            destination = arguments.pop(0)
        elif argument == "-l":
            listing = True
        elif argument.startswith("-"):
            quiet = quiet or "q" in argument
        elif archive is None:
            archive = argument
    if archive is None:
        fail("usage: unzip [-l] [-q] [-o] archive.zip [-d directory]")
    with zipfile.ZipFile(archive) as source:
        if listing:
            for info in source.infolist():
                print(f"{info.file_size:>10}  {info.filename}")
            return
        for info in source.infolist():
            if not quiet:
                print(f"  inflating: {os.path.join(destination, info.filename)}")
            source.extract(info, destination)


def tree(arguments):
    depth, hidden, root = None, False, "."
    while arguments:
        argument = arguments.pop(0)
        if argument == "-L":
            depth = int(arguments.pop(0))
        elif argument == "-a":
            hidden = True
        else:
            root = argument
    counts = [0, 0]

    def walk(folder, prefix, level):
        if depth is not None and level > depth:
            return
        names = sorted(n for n in os.listdir(folder) if hidden or not n.startswith("."))
        for index, name in enumerate(names):
            last = index == len(names) - 1
            path = os.path.join(folder, name)
            print(f"{prefix}{'└── ' if last else '├── '}{name}")
            if os.path.isdir(path) and not os.path.islink(path):
                counts[0] += 1
                walk(path, prefix + ("    " if last else "│   "), level + 1)
            else:
                counts[1] += 1

    print(root)
    walk(root, "", 1)
    print(f"\n{counts[0]} directories, {counts[1]} files")


def tac(arguments):
    for line in reversed(list(lines(arguments))):
        sys.stdout.write(line if line.endswith("\n") else line + "\n")


def rev(arguments):
    for line in lines(arguments):
        print(line.rstrip("\n")[::-1])


def yes(arguments):
    chunk = ((" ".join(arguments) if arguments else "y") + "\n") * 1024
    while True:
        sys.stdout.write(chunk)
        sys.stdout.flush()


COMMANDS = {
    "pip": pip,
    "pip3": pip,
    "which": which,
    "cut": cut,
    "seq": seq,
    "mktemp": mktemp,
    "sha256sum": lambda a: digest("sha256", a),
    "sha1sum": lambda a: digest("sha1", a),
    "md5sum": lambda a: digest("md5", a),
    "shasum": shasum,
    "zip": zip_,
    "unzip": unzip,
    "tree": tree,
    "tac": tac,
    "rev": rev,
    "yes": yes,
}

if __name__ == "__main__":
    try:
        COMMANDS[NAME](sys.argv[1:])
    except BrokenPipeError:
        # The reader stopped (yes | head): end quietly, as a command killed by SIGPIPE would.
        sys.stdout = open(os.devnull, "w")
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        fail(error)

"""Read a FLEURS audio tarball from stdin and keep the first N clips with their reference text."""
import csv
import pathlib
import sys
import tarfile

target, transcripts, count = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
with open(transcripts, encoding="utf-8", newline="") as handle:
    reference = {row[1]: row[2] for row in csv.reader(handle, delimiter="\t", quoting=csv.QUOTE_NONE)}

kept = 0
with tarfile.open(fileobj=sys.stdin.buffer, mode="r|gz") as archive:
    for member in archive:
        name = pathlib.PurePath(member.name).name
        if not member.isfile() or name not in reference:
            continue
        (target / name).write_bytes(archive.extractfile(member).read())
        (target / name).with_suffix(".txt").write_text(reference[name], encoding="utf-8")
        kept += 1
        if kept == count:
            break

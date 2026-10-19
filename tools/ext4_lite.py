"""APEX ext4 payload ELF iterator, reusing the minimal ext4 walker in isa_scan.py."""
import io, isa_scan


def iter_elfs(img, prefix=""):
    fs = isa_scan.Ext4FS(io.BytesIO(img), 0, len(img))
    for vpath, ino in fs.walk_elfs():
        data = fs._read_file(ino)
        if data:
            yield prefix + vpath, data

#!/usr/bin/env python3
"""Lays out an APK's lib/<abi>/ directory from nix-built ELF files.

Android extracts only files named lib*.so, so executables are shipped as
lib<name>.so and versioned sonames (libssl.so.3) lose their version. Every
DT_NEEDED is resolved -- from the file's own RUNPATH, then the search path --
unless Android provides it at minSdk. Renames and RUNPATHs are rewritten in
place (a rename only ever shortens a string), so no segment moves and 16 KB
alignment survives.

usage: native-libs.py OUT --stubs DIR [--search DIR]... [--lib PATH]...
                       [--lib-as FILE=PATH]... [--exe NAME=PATH]...
"""
import argparse, os, re, shutil, struct, sys

DT_NULL, DT_NEEDED, DT_STRTAB, DT_STRSZ, DT_SONAME, DT_RPATH, DT_RUNPATH = 0, 1, 5, 10, 14, 15, 29
DT_VERNEED, DT_VERNEEDNUM = 0x6FFFFFFE, 0x6FFFFFFF
VERNEED = "verneed"  # a pseudo-tag: the file names .gnu.version_r repeats
PT_LOAD, PT_DYNAMIC = 1, 2


class Elf:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.data = bytearray(f.read())
        d = self.data
        if d[:4] != b"\x7fELF" or d[4] != 2 or d[5] != 1:
            raise ValueError(f"{path}: not a little-endian ELF64 file")
        phoff, = struct.unpack_from("<Q", d, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", d, 0x36)
        self.loads, self.dynamic = [], None
        for i in range(phnum):
            p_type, _, p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from("<IIQQQQQQ", d, phoff + i * phentsize)
            if p_type == PT_LOAD:
                self.loads.append((p_vaddr, p_offset, p_filesz))
            elif p_type == PT_DYNAMIC:
                self.dynamic = (p_offset, p_filesz)
        self.entries = []  # (file offset of the entry, tag, value)
        strtab = strsz = None
        if self.dynamic:
            off, size = self.dynamic
            for pos in range(off, off + size, 16):
                tag, val = struct.unpack_from("<qQ", d, pos)
                if tag == DT_NULL:
                    break
                self.entries.append((pos, tag, val))
                if tag == DT_STRTAB:
                    strtab = val
                elif tag == DT_STRSZ:
                    strsz = val
        self.strtab = self.vaddr_to_offset(strtab) if strtab is not None else None
        self.strsz = strsz
        # Versioned symbols name their library again, and bionic matches those
        # names against the loaded libraries' sonames.
        tags = {t: v for _, t, v in self.entries}
        if DT_VERNEED in tags:
            pos = self.vaddr_to_offset(tags[DT_VERNEED])
            for _ in range(tags.get(DT_VERNEEDNUM, 0)):
                _, _, vn_file, _, vn_next = struct.unpack_from("<HHIII", d, pos)
                self.entries.append((pos, VERNEED, vn_file))
                if not vn_next:
                    break
                pos += vn_next

    def vaddr_to_offset(self, vaddr):
        for p_vaddr, p_offset, p_filesz in self.loads:
            if p_vaddr <= vaddr < p_vaddr + p_filesz:
                return vaddr - p_vaddr + p_offset
        raise ValueError(f"{self.path}: address {vaddr:#x} is in no LOAD segment")

    def string(self, index):
        start = self.strtab + index
        return self.data[start:self.data.index(0, start)].decode()

    def strings(self, tag):
        return [self.string(v) for _, t, v in self.entries if t == tag]

    def rewrite(self, tag, old, new):
        """Overwrites a dynamic string in place; `new` may not be longer."""
        for _, t, v in self.entries:
            if t == tag and self.string(v) == old:
                if len(new) > len(old):
                    raise ValueError(f"{self.path}: cannot grow {old!r} to {new!r} in place")
                start = self.strtab + v
                self.data[start:start + len(old)] = new.encode() + b"\0" * (len(old) - len(new))

    def save(self, path):
        with open(path, "wb") as f:
            f.write(self.data)


def apk_name(soname):
    """libssl.so.3 -> libssl.so; lib*.so stays."""
    m = re.fullmatch(r"(lib.+?\.so)(\.[0-9][0-9.]*)?", soname)
    if not m:
        raise ValueError(f"{soname}: not a lib*.so[.N] name, so it cannot ship in an APK")
    return m.group(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--stubs", required=True)
    ap.add_argument("--search", action="append", default=[])
    ap.add_argument("--lib", action="append", default=[])
    ap.add_argument("--lib-as", action="append", default=[])
    ap.add_argument("--exe", action="append", default=[])
    a = ap.parse_args()

    provided = {n for n in os.listdir(a.stubs) if n.endswith(".so")}
    os.makedirs(a.out, exist_ok=True)
    packaged = {}   # APK name -> source path
    queue = []

    def add(source, name):
        if name in provided:
            raise ValueError(f"{name} would shadow the Android library of that name ({source})")
        if name in packaged:
            if os.path.realpath(packaged[name]) != os.path.realpath(source):
                print(f"note: {name} already packaged from {packaged[name]}; ignoring {source}")
            return
        packaged[name] = source
        queue.append(name)

    for spec in a.exe:
        name, path = spec.split("=", 1)
        add(path, f"lib{name}.so")
    for path in a.lib:
        add(path, apk_name(os.path.basename(path)))
    for spec in a.lib_as:
        name, path = spec.split("=", 1)
        add(path, apk_name(name))

    renames = {}  # original soname -> APK name
    while queue:
        name = queue.pop()
        source = packaged[name]
        elf = Elf(source)
        runpath = [p for s in elf.strings(DT_RUNPATH) + elf.strings(DT_RPATH) for p in s.split(":") if p]
        for needed in elf.strings(DT_NEEDED):
            if needed in provided:
                continue
            target = apk_name(needed)
            renames[needed] = target
            if target in packaged:
                continue
            for d in [p.replace("$ORIGIN", os.path.dirname(source)) for p in runpath] + a.search:
                candidate = os.path.join(d, needed)
                if os.path.exists(candidate):
                    add(os.path.realpath(candidate), target)
                    break
            else:
                raise ValueError(f"{os.path.basename(source)} needs {needed}, found in neither its RUNPATH nor the search path")

    for name, source in sorted(packaged.items()):
        elf = Elf(source)
        for tag in (DT_NEEDED, VERNEED):
            for needed in elf.strings(tag):
                if renames.get(needed, needed) != needed:
                    elf.rewrite(tag, needed, renames[needed])
        for own in elf.strings(DT_SONAME):
            # A plugin is dlopen()ed by path, so its longer APK name can wait.
            if own != name and len(name) <= len(own):
                elf.rewrite(DT_SONAME, own, name)
        # The package manager extracts every library into one directory.
        for tag in (DT_RUNPATH, DT_RPATH):
            for value in elf.strings(tag):
                elf.rewrite(tag, value, "$ORIGIN" if len(value) >= len("$ORIGIN") else "")
        dest = os.path.join(a.out, name)
        elf.save(dest)
        os.chmod(dest, 0o755)
        print(f"{name:40} <- {source}")


if __name__ == "__main__":
    try:
        main()
    except ValueError as e:
        print(f"native-libs: {e}", file=sys.stderr)
        sys.exit(1)

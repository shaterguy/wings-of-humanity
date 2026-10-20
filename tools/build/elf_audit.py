"""Strict bounded ELF gate for the dependency-free AArch64 resident-context gate."""
import hashlib
import struct


def audit(raw):
    def need(ok, reason):
        if not ok:
            raise ValueError(reason)

    need(64 <= len(raw) <= 1048576, "ELF size")

    def take(offset, size):
        need(isinstance(offset, int) and isinstance(size, int) and offset >= 0 and size >= 0
             and offset + size <= len(raw), "ELF range")
        return raw[offset:offset + size]

    need(raw[:7] == b"\x7fELF\x02\x01\x01", "ELF64 little-endian version1")
    header = struct.unpack("<16sHHIQQQIHHHHHH", take(0, 64))
    _, kind, machine, version, entry, phoff, shoff, flags, ehsize, phsize, phnum, shsize, shnum, shstr = header
    need(kind == 3 and machine == 183 and version == 1 and entry == 0 and flags == 0 and ehsize == 64,
         "shared AArch64 identity")
    need(phsize == 56 and 1 <= phnum <= 64, "program header count")
    need(shsize == 64 and 1 <= shnum <= 128 and 0 < shstr < shnum, "retained section header count")
    programs = [struct.unpack("<IIQQQQQQ", take(phoff + i * 56, 56)) for i in range(phnum)]
    sections = [struct.unpack("<IIQQQQIIQQ", take(shoff + i * 64, 64)) for i in range(shnum)]
    loads = [p for p in programs if p[0] == 1]
    need(loads, "missing LOAD")
    for p in programs:
        ptype, permissions, offset, address, physical, filesz, memsz, alignment = p
        need(ptype not in (3, 7), "PT_INTERP or PT_TLS")
        need(not (permissions & 1 and permissions & 2), "writable executable segment")
        if ptype == 0x6474E551:
            need(not permissions & 1, "executable GNU_STACK")
        if ptype == 1:
            need(filesz <= memsz <= 1048576 and alignment >= 16384 and alignment & (alignment - 1) == 0,
                 "LOAD size/alignment")
            need(offset % alignment == address % alignment, "LOAD offset/address congruence")
            take(offset, filesz)
    need(any(p[0] == 0x6474E551 for p in programs), "missing GNU_STACK declaration")
    strings_section = sections[shstr]
    need(strings_section[1] == 3, "section string table")
    section_names = take(strings_section[4], strings_section[5])

    def text(strings, at):
        need(0 <= at < len(strings), "string offset")
        end = strings.find(b"\0", at)
        need(end >= at and end - at <= 256, "string bound")
        return strings[at:end].decode("ascii")

    names = [text(section_names, s[0]) for s in sections]
    forbidden_names = {
        ".init", ".fini", ".init_array", ".fini_array", ".preinit_array",
        ".ctors", ".dtors", ".tdata", ".tbss", ".rela.plt", ".rel.plt",
        ".relr.dyn", ".android.rel.dyn", ".android.rela.dyn",
    }
    exports = []
    dynamic_tags = []
    relocations = []
    dynsym_count = 0
    dynamics = []
    dynsyms = []
    relas = []
    for name, section in zip(names, sections):
        _, stype, attributes, address, offset, size, link, info, align, entsize = section
        need(not attributes & 0x400, "TLS section")
        need(not (attributes & 1 and attributes & 4), "writable executable section")
        need(name not in forbidden_names, "forbidden constructor/TLS/packed/PLT section:" + name)
        need(stype not in (14, 15, 16, 19, 0x60000001, 0x60000002), "constructor or packed relocation section type")
        if stype != 8:
            data = take(offset, size)
        else:
            data = b""
        if stype in (2, 11):
            need(entsize == 24 and size % 24 == 0 and size // 24 <= 4096 and 0 <= link < shnum,
                 "symbol table bounds")
            linked = sections[link]
            need(linked[1] == 3, "symbol string table")
            strings = take(linked[4], linked[5])
            if stype == 11:
                dynsym_count += 1
                dynsyms.append(section)
            for at in range(0, size, 24):
                n, sinfo, other, index, value, symbol_size = struct.unpack("<IBBHQQ", data[at:at + 24])
                symbol = text(strings, n)
                need(not (sinfo & 15 == 10), "IFUNC symbol")
                need(not (symbol and index == 0), "undefined symbol:" + symbol)
                if stype == 11 and symbol and index != 0 and sinfo >> 4 in (1, 2) and other & 3 in (0, 3):
                    need(sinfo & 15 == 2, "public symbol must be function")
                    need(index < shnum and sections[index][2] & 4
                         and any(p[1] & 1 and p[3] <= value and value + symbol_size <= p[3] + p[6] for p in loads),
                         "public entry must reside in executable section/LOAD")
                    exports.append(symbol)
        if stype == 6:
            dynamics.append(section)
            need(entsize == 16 and size % 16 == 0 and size // 16 <= 256, "dynamic table bounds")
            # Only standard uncompressed, dependency-free shared-object tags.
            allowed = {0, 4, 5, 6, 7, 8, 9, 10, 11, 14, 30, 0x6FFFFEF5, 0x6FFFFFF9, 0x6FFFFFFB}
            terminated = False
            for at in range(0, size, 16):
                tag, value = struct.unpack("<qQ", data[at:at + 16])
                need(tag in allowed, "forbidden/unexpected dynamic tag:" + hex(tag))
                if tag == 30:
                    need(value & ~8 == 0, "unexpected DT_FLAGS; only BIND_NOW permitted")
                if tag == 0x6FFFFFFB:
                    need(value & ~1 == 0, "unexpected DT_FLAGS_1; only NOW permitted")
                dynamic_tags.append({"tag": tag, "value": value})
                if tag == 0:
                    terminated = True
                    break
            need(terminated, "dynamic table not terminated")
        if stype == 9:
            need(False, "REL relocation table unexpected on AArch64")
        if stype == 4:
            relas.append(section)
            need(entsize == 24 and size % 24 == 0 and size // 24 <= 4096, "RELA bounds")
            for at in range(0, size, 24):
                where, rinfo, addend = struct.unpack("<QQq", data[at:at + 24])
                symbol, rtype = rinfo >> 32, rinfo & 0xFFFFFFFF
                need(symbol == 0 and rtype in (0, 1027), "only NONE/RELATIVE local relocations permitted")
                need(any(p[3] <= where and where + 8 <= p[3] + p[6] and not p[1] & 1 for p in loads),
                     "relocation target must be non-executable LOAD memory")
                relocations.append({"type": rtype, "offset": where})
    need(dynsym_count == 1, "exactly one dynsym required")
    need(exports == ["wings_resident_init"], "unexpected public exports")
    need(dynamic_tags, "dynamic table required")
    dynamic_programs = [p for p in programs if p[0] == 2]
    need(len(dynamics) == len(dynamic_programs) == 1, "one matching PT_DYNAMIC/section required")
    dp, ds = dynamic_programs[0], dynamics[0]
    need((dp[2], dp[3], dp[5]) == (ds[4], ds[3], ds[5]), "PT_DYNAMIC/section mismatch")
    tags = {}
    for row in dynamic_tags:
        need(row["tag"] not in tags, "duplicate dynamic tag")
        tags[row["tag"]] = row["value"]
    symbols = dynsyms[0]
    strings = sections[symbols[6]]
    need(tags.get(6) == symbols[3] and tags.get(11) == 24 and tags.get(5) == strings[3]
         and tags.get(10) == strings[5], "dynamic symbol/string table mismatch")
    need(text(take(strings[4], strings[5]), tags.get(14, -1)) == "libwings_resident.arm64.so",
         "exact SONAME required")
    if relas:
        need(len(relas) == 1 and tags.get(7) == relas[0][3] and tags.get(8) == relas[0][5]
             and tags.get(9) == 24, "dynamic RELA table mismatch")
    else:
        need(not any(tag in tags for tag in (7, 8, 9, 0x6FFFFFF9)), "unexpected dynamic RELA tags")
    return {
        "ok": True, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
        "elf": "ELF64 little-endian ET_DYN AArch64", "public_exports": exports,
        "dependencies": [], "undefined_symbols": [], "runpath": [], "rpath": [],
        "interpreter": None, "tls": False, "constructors": False, "ifunc": False,
        "textrel": False, "packed_relocations": False, "section_headers_retained": True,
        "load_segments": [{"offset": p[2], "vaddr": p[3], "filesz": p[5], "memsz": p[6],
                           "flags": p[1], "alignment": p[7]} for p in loads],
        "relocations": relocations, "dynamic_tags": dynamic_tags,
        "android_runtime_compatibility_established": False,
    }

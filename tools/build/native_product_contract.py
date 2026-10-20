"""Exact R6d full-product candidate contract. No generic native allowlist."""
import hashlib
import stat
import struct
import zipfile
from elf_audit import audit

DESC = 'addons/wings_native/resident.gdextension'
LIB = 'addons/wings_native/libwings_resident.arm64.so'
APK_LIB = 'lib/arm64-v8a/libwings_resident.arm64.so'
EXT_LIST = 'assets/.godot/extension_list.cfg'
LIB_BYTES = 36328
LIB_SHA256 = '96b752d715593250fe3920d00e45aefd78142696232045e615b67631ab3836d3'
# Exact reviewed descriptor bytes; the preparation tests bind the separate file.
DESC_BYTES = b'[configuration]\nentry_symbol = "wings_resident_init"\ncompatibility_minimum = "4.6"\nreloadable = false\n\n[libraries]\nandroid.debug.arm64 = "res://addons/wings_native/libwings_resident.arm64.so"\nlinux.debug.arm64 = "res://addons/wings_native/libwings_resident.arm64.so"\n'

PRODUCT_SOURCE_PINS = {'game/core/native_pursuit_reader.gd': {'bytes': 9263, 'sha256': '0073338760c041ea2c6ca3a7f27a7a2fa7ef19b5a2dbc6c5d885105e8d0d5421'}, 'game/core/run_simulation.gd': {'bytes': 203265, 'sha256': '343fffe424a21f308afcca9f1d2ae9b9220b5b23ee64ac412392e3d0bd028d04'}, 'game/core/streamed_run_world.gd': {'bytes': 72220, 'sha256': '7e44c966291572f5d125b9816df05ea996356e2302e0fbdf9348fcfba004bb07'}, 'project.godot': {'bytes': 1329, 'sha256': 'b46c5e2fa1deba7f8e206ff5d9fbc578b7408d2eae31553840c7ec2a8bf4f5be'}}
PRODUCT_FREEZE_SHA256 = "377ac97522694a2792679ad6ccab8dea89d3fd493af99be35059ff4b9c2aadb5"
NATIVE_SOURCE_FREEZE_SHA256 = "774e3c75cfd772a90834573f2ecee9f2a0f4475bf4e8b7472b8d41f443e529d8"
SIGNER_CERTIFICATE_SHA256 = "0ea1f152a801330f69ca0301a638de283e665c814535b54f407b1974c6bd2ae0"

def need(ok, why):
    if not ok: raise ValueError('NATIVE_PRODUCT:' + why)

def file_bytes(path, expected_size):
    need(path.stat().st_size == expected_size, 'source_size')
    with path.open('rb') as stream: raw = stream.read(expected_size + 1)
    need(len(raw) == expected_size, 'bounded_source_read')
    return raw

def native_source_files(root, source_file):
    # A fixture, wrong opt-in, altered Core/helper/reader or config is not this product.
    for relative, pin in PRODUCT_SOURCE_PINS.items():
        raw = file_bytes(source_file(root, relative), pin['bytes'])
        need(hashlib.sha256(raw).hexdigest() == pin['sha256'], 'exact_product_source:' + relative)
    descriptor = file_bytes(source_file(root, DESC), len(DESC_BYTES))
    need(descriptor == DESC_BYTES, 'exact_source_descriptor')
    raw = file_bytes(source_file(root, LIB), LIB_BYTES)
    need(hashlib.sha256(raw).hexdigest() == LIB_SHA256, 'exact_source_library')
    need(audit(raw)['ok'] is True, 'source_ELF')
    return {DESC, LIB}

def native_archive_report(archive, root, source_file):
    native_source_files(root, source_file)
    names = archive.namelist()
    need(len(names) == len(set(names)) and len(names) <= 2048, 'duplicate_or_excess_entries')
    need(all(stat.S_IFMT(i.external_attr >> 16) != stat.S_IFLNK for i in archive.infolist()), 'symlink_entry')
    need(sum(i.file_size for i in archive.infolist()) <= 256 * 1024 * 1024, 'uncompressed_archive_bound')
    for relative, pin in PRODUCT_SOURCE_PINS.items():
        if not relative.endswith('.gd'): continue
        member = 'assets/' + relative
        if member in names:
            info = archive.getinfo(member)
            need(info.file_size == pin['bytes'] and not info.flag_bits & 1, 'packaged_script_metadata')
            need(hashlib.sha256(archive.read(info)).hexdigest() == pin['sha256'], 'exact_packaged_script:' + relative)
        else:
            # The original validator verifies this remap's exact target later.
            # Compiled bytes are not falsely called byte-equal to source text.
            compiled = member[:-3] + '.gdc'
            need(member + '.remap' in names and compiled in names, 'required_product_script:' + relative)
            need(0 < archive.getinfo(compiled).file_size <= 4 * 1024 * 1024, 'compiled_product_script_bound')
    for name, expected in [('assets/' + DESC, DESC_BYTES), (EXT_LIST, ('res://' + DESC + '\n').encode())]:
        info = archive.getinfo(name)
        need(info.file_size == len(expected) and not info.flag_bits & 1, 'metadata_size_or_encryption')
        need(archive.read(info) == expected, 'exact_exported_descriptor_or_list')
    info = archive.getinfo(APK_LIB)
    need(info.file_size == LIB_BYTES and info.compress_size == LIB_BYTES, 'library_size')
    need(info.compress_type == zipfile.ZIP_STORED and not info.flag_bits & 1, 'stored_unencrypted_library')
    raw = archive.read(info)
    need(hashlib.sha256(raw).hexdigest() == LIB_SHA256, 'packaged_library_identity')
    elf = audit(raw)
    need(elf['ok'] is True, 'packaged_ELF')
    stream = archive.fp
    position = stream.tell()
    try:
        stream.seek(info.header_offset)
        header = stream.read(30)
        need(len(header) == 30, 'local_header_length')
        signature, version, flags, method, mtime, mdate, crc, csize, usize, nlen, xlen = struct.unpack('<IHHHHHIIIHH', header)
        need(signature == 0x04034b50 and flags == info.flag_bits and method == 0 and not flags & 9, 'local_header_flags')
        need((crc, csize, usize) == (info.CRC, LIB_BYTES, LIB_BYTES), 'local_header_sizes')
        need(nlen == len(APK_LIB.encode()) and stream.read(nlen) == APK_LIB.encode(), 'local_header_name')
        offset = info.header_offset + 30 + nlen + xlen
        need(offset % 16384 == 0, 'library_ZIP_16KiB_alignment')
        need(offset + LIB_BYTES <= archive.start_dir, 'library_extent')
    finally:
        stream.seek(position)
    # No additional native library can be admitted by this dedicated exception.
    return {'descriptor': 'assets/' + DESC, 'descriptor_sha256': hashlib.sha256(DESC_BYTES).hexdigest(),
            'android_feature': 'android.debug.arm64', 'archive_library': APK_LIB,
            'library_bytes': LIB_BYTES, 'library_sha256': LIB_SHA256,
            'zip_compression': 'stored', 'zip_data_offset': offset, 'zip_alignment_bytes': 16384,
            'extension_list': EXT_LIST, 'elf': elf, 'product_revision': 'product-adapter-r6d',
            'native_source_freeze_sha256': NATIVE_SOURCE_FREEZE_SHA256,
            'product_freeze_sha256': PRODUCT_FREEZE_SHA256,
            'expected_signer_certificate_sha256': SIGNER_CERTIFICATE_SHA256,
            'packaging_only': True, 'production_adoption_allowed': False,
            'android_in_app_load_proved': False}

def verify_native_entries(archive, root, source_file):
    native_archive_report(archive, root, source_file)
    return {'assets/' + DESC, EXT_LIST, APK_LIB}

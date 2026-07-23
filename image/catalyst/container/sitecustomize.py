"""Volatoo-specific Catalyst compression definitions."""

from DeComp.definitions import COMPRESS_DEFINITIONS

COMPRESS_DEFINITIONS["squashfs_zstd"] = [
    "_sqfs",
    "mksquashfs",
    [
        "%(basedir)s/%(source)s",
        "%(filename)s",
        "-comp",
        "zstd",
        "-Xcompression-level",
        "19",
        # pyDeComp 0.3 removes this pair when Catalyst does not supply an
        # architecture. Keep the placeholders even though Zstd has no BCJ
        # filter so the released SquashFS runner can perform that cleanup.
        "-Xbcj",
        "%(arch)s",
        "-b",
        "1M",
        "-noappend",
        # pyDeComp 0.3's default long options work for tar, but were removed
        # by squashfs-tools 4.7. Keep the modern spelling local to this mode.
        "-xattrs",
        "-xattrs-include",
        "security.capability",
        "-xattrs-include",
        "user.pax.flags",
    ],
    "SQUASHFS",
    ["squashfs", "sfs"],
    {"mksquashfs"},
]

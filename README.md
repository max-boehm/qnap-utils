# qnap-utils
Utilities to unpack QNAP firmware images and QPKG files

## extract_qnap_fw.sh

This script unpacks a firmware image. The firmware image can be passed in the
original form (\*.img), decrypted (\*.tgz), or as a source directory.

Usage:

    ./extract_qnap_fw.sh firmware.img destdir
    ./extract_qnap_fw.sh firmware.img.tgz destdir
    ./extract_qnap_fw.sh srcdir destdir

this results in:

    destdir/fw              files extracted from the firmware.img
    destdir/sysroot         unpacked initrd/initramfs, rootfs2, rootfs_ext
    destdir/qpkg            unpacked qpkg.tar

## extract_qpkg.sh

This script unpacks a QPKG file.

Usage:

    ./extract_qpkg.sh package.qpkg [destdir]

Another way to do this would be using the QDK tool.

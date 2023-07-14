#!/bin/bash
#
# Script to extract the contents from a QNAP firmware image.
#
# The script has been created for research purposes to better understand
# the requirements for cross compilation as it shows which library versions
# exist in which firmware.
#
# invocation (on a linux host):
# ./extract_qnap_fw.sh firmware.img destdir
#
# this results in:
# destdir/fw              files extracted from the firmware.img
# destdir/sysroot         unpacked initrd/initramfs, rootfs2, rootfs_ext
# destdir/qpkg            unpacked qpkg.tar
#
# Tested for firmware images of the following models
# - x09, x10, x12, x19, x20, x21
# - x51, x53
# - x31, x31+
#
# Older firmware images use ext2 images of filesystems.
# Newer firmware images (x31, x31+) use Unsorted Block Images (UBI) files.
# Those are accessed in the script using tools from the mtd-utils package
# which therefore must have been installed on the linux host.
#
#
# Copyright 2015 Max Böhm
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

trap 'echo "error in line ${LINENO}. Exiting."' ERR
set -e               # stop on error

if [ $# -lt 2 ]; then
  echo "usage $0 firmware.img destdir"
  echo "      $0 firmware.img.tgz destdir"
  echo "      $0 srcdir destdir"
  exit
fi

SRC="$1"
DEST="$2"

extract-image() {
    local image="${1}" dst="${2}"
    shift 2 # leaves mount options in ${@}

    local mntdir
    mntdir="$(sudo mktemp -d -t qnap-utils-XXXXXX -p /mnt)"
    echo "- mount image '${image}' on '${mntdir}'${*:+, options: ${@}}"
    sudo mount "${@}" "${image}" "${mntdir}"
    echo "- copy image contents to '${dst}/'"
    # maybe run cp with sudo to preserve owner/group and avoid access denied
    # errors?
    cp -a "${mntdir}/"* "${dst}/" || {
        echo "- WARNING: failed to copy some (if not all) files"
    }
    echo "- cleanup: '${mntdir}'"
    sudo umount "${mntdir}"
    sudo rmdir "${mntdir}"
}

extract-image-with-tar() {
    local image="${1}" dst="${2}" tarfile="${3}"
    shift 3 # leaves mount options in ${@}

    local tmpdst
    tmpdst="$(mktemp -d -p "${TEMPDIR:-/tmp}")"
    extract-image "${image}" "${tmpdst}" "${@}"
    echo "- extract data from '${tarfile}' to '${dst}/'"
    # maybe run tar with sudo to preserve owner/group?
    tar -xjf "${tmpdst}/${tarfile}" -C "${dst}"
    sudo rm -rf "${tmpdst}"
}

if [ -e $DEST ]; then echo "destdir '$DEST' must not already exist"; exit; fi

echo "SRC=$SRC, DEST=$DEST"
mkdir -p $DEST

if [ -f $SRC ]; then
  
  if file $SRC | grep -q ": data" ; then
    echo "----------------------------------------------"
    if which PC1 >/dev/null; then
      FW_TGZ=$DEST/`basename $SRC`.tgz
      echo "decrypting '$SRC' to '$FW_TGZ' using PC1 tool ..."
      PC1 d QNAPNASVERSION4 $SRC $FW_TGZ
      SRC=$FW_TGZ
    else
      echo "PC1 tool not found; decrypt the image first by invoking on your NAS"
      echo
      echo "/sbin/PC1 d QNAPNASVERSION4 $SRC $SRC.tgz"
      exit
    fi
  fi

  if file $SRC | grep -q ": gzip" ; then
    echo "----------------------------------------------"
    echo "extracting '$SRC' into '$DEST/fw'..."
    mkdir -p $DEST/fw
    # ignore the gzip `trailing garbage` error
    tar xf $SRC -C $DEST/fw || true
    SRC=$DEST/fw
  fi
fi

UIMAGE="$SRC/uImage"               # x31,x31+
UBI="$SRC/rootfs2.ubi"             # x31,x31+
IMAGE="$DEST/image"

# initial ramdisk root filesystem 
INITRAMFS="$DEST/initramfs"        # x31,x31+
INITRD="$SRC/initrd.boot"          # x10,x12,x19,x20,x21
if [ ! -e $INITRD ]; then
  INITRD="$SRC/initrd"             # x51,x53
fi

ROOTFS2="$SRC/rootfs2.tgz"
ROOTFS2_BZ="$SRC/rootfs2.bz"
ROOTFS2_IMG="$SRC/rootfs2.img"
ROOTFS_EXT="$SRC/rootfs_ext.tgz"
QPKG="$SRC/qpkg.tar"

if [ -e $UBI ]; then
  ROOTFS2="$DEST/rootfs2.tgz"
  ROOTFS_EXT="$DEST/rootfs_ext.tgz"
  QPKG="$DEST/qpkg.tar"
fi

SYSROOT="$DEST/sysroot"

mkdir -p $DEST


# uImage           x19,x20,x21: kernel only,  x31,x31+: kernel+ramdisk

if [ -e $UIMAGE ]; then
  echo "----------------------------------------------"
  echo "scanning '$UIMAGE' for (gzipped) parts..."

  a=`od -t x1 -w4 -Ad -v $UIMAGE | grep '1f 8b 08 00' | awk '{print $1}'`
  if [ ! -z "$a" ]; then
    dd if=$UIMAGE bs=$a skip=1 of=$IMAGE.gz status=none
    gunzip --quiet $IMAGE.gz || [ $? -eq 2 ]
    echo "- extracted and uncompressed '$IMAGE' at offset $a"

    i=0
    for a in `od -t x1 -w4 -Ad -v $IMAGE | grep '1f 8b 08 00' | awk '{print $1}'`; do
      i=$((i+1))
      dd if=$IMAGE bs=$a skip=1 of=$IMAGE.part$i.gz status=none
      gunzip --quiet $IMAGE.part$i.gz || [ $? -eq 2 ] 
      echo "- extracted and uncompressed '$IMAGE.part$i' at offset $a"
    done

    if [ $i -gt 0 ]; then
      mv $IMAGE.part$i $INITRAMFS
      echo "- renamed '$IMAGE.part$i' to '$INITRAMFS'"
      rm $IMAGE
    fi

  fi
fi


# rootfs2.ubi      (rootfs2.tgz, rootfs_ext.tgz, qpkg.tar)

if [ -e $UBI ]; then
  echo "----------------------------------------------"
  echo "unpacking '$UBI'..."

  # see http://trac.gateworks.com/wiki/linux/ubi
  #
  # apt-get install mtd-utils

  # 256MB flash
  sudo modprobe -r nandsim || true
  if [ -e /dev/mtdblock0 ]; then
    echo "/dev/mtdblock0 does already exist! Exiting to not overwrite it."; exit
  fi
  sudo modprobe nandsim first_id_byte=0x2c second_id_byte=0xda third_id_byte=0x90 fourth_id_byte=0x95

  echo "- copy UBI image into simulated flash device"
  # populate NAND with an existing ubi: 
  sudo modprobe mtdblock
  sudo dd if=$UBI of=/dev/mtdblock0 bs=2048 status=none

  echo "- attach simulated flash device"
  # attach ubi
  sudo modprobe ubi
  sudo ubiattach /dev/ubi_ctrl -m0 -O2048
  #sudo ubinfo -a

  echo "- mounting ubifs file system"
  # mount the ubifs to host 
  sudo modprobe ubifs
  extract-image ubi0 "${DEST}" -t ubifs
  sudo ubidetach /dev/ubi_ctrl -m0
  sudo modprobe -r nandsim
fi


echo "----------------------------------------------"
mkdir -p $SYSROOT

if [ -e $INITRAMFS ]; then
  echo "extracting '$INITRAMFS'..."
  cat $INITRAMFS | (cd $SYSROOT && (cpio -i --make-directories||true) )
fi

if [ -e $INITRD ]; then
  if file $INITRD | grep -q LZMA ; then
    echo "extracting '$INITRD' (LZMA)..."
    lzma -d <$INITRD | (cd $SYSROOT && (cpio -i --make-directories||true) )
  fi
  if file $INITRD | grep -q gzip ; then
    echo "extracting '$INITRD' (gzip)..."
    gzip -d <$INITRD >$DEST/initrd.$$
    extract-image "${DEST}/initrd.${$}" "${SYSROOT}" -t ext2 -oro,loop
    rm $DEST/initrd.$$
  fi
fi

echo "----------------------------------------------"

if [ -e $ROOTFS2 ]; then
  echo "extracting $ROOTFS2 (gzip, tar)..."
  tar -xzf $ROOTFS2 -C $SYSROOT
fi

if [ -e $ROOTFS2_BZ ]; then
  if file $ROOTFS2_BZ | grep -q LZMA ; then
    # x51
    echo "extracting $ROOTFS2_BZ (lzma, tar)..."
    tar --lzma -xf $ROOTFS2_BZ -C $SYSROOT
  else
  echo "extracting $ROOTFS2_BZ (bzip2, tar)..."
  tar -xjf $ROOTFS2_BZ -C $SYSROOT
  fi
fi

if [ -f $ROOTFS2_IMG ]; then
  echo "extracting $ROOTFS2_IMG (ext2)..."
  extract-image-with-tar \
      "${ROOTFS2_IMG}" "${SYSROOT}" 'rootfs2.bz' -t ext2 -oro,loop
fi

echo "----------------------------------------------"

if [ -e $ROOTFS_EXT ]; then
  echo "extracting $ROOTFS_EXT..."
  tar xzvf $ROOTFS_EXT
  extract-image rootfs_ext.img "${SYSROOT}" -oro,loop
  rm rootfs_ext.img
fi

for f in `find $SYSROOT/opt/source -name "*.tgz"`; do
  echo "extracting '$f' -> sysroot/usr/local..."
  mkdir -p $SYSROOT/usr/local
  tar xzf $f -C $SYSROOT/usr/local
done

echo "----------------------------------------------"

if [ -e $QPKG ]; then
  echo "extracting '$QPKG'..."
  mkdir -p $DEST/qpkg
  tar xf $QPKG -C $DEST/qpkg
  for f in $DEST/qpkg/*.tgz; do
    if file $f | grep -q gzip; then
      tar tvzf $f >$f.txt
    fi
  done
fi

for name in apache_php5 mysql5 mariadb5; do
  if [ -e $DEST/qpkg/$name.tgz ]; then
    echo "extracting 'qpkg/$name.tgz' -> sysroot/usr/local..."
    tar xzf $DEST/qpkg/$name.tgz -C $SYSROOT/usr/local
  fi
done

if [ -e $DEST/qpkg/libboost.tgz ]; then
  echo "extracting 'qpkg/libboost.tgz' -> sysroot/usr/lib..."
  tar xzf $DEST/qpkg/libboost.tgz -C $SYSROOT/usr/lib
elif [ -e $DEST/qpkg/DSv3.tgz ]; then
  echo "extracting libboost from 'qpkg/DSv3.tgz' -> sysroot/usr/lib..."
  tar tzf $DEST/qpkg/DSv3.tgz |grep libboost | tar xzf $DEST/qpkg/DSv3.tgz -C $SYSROOT -T -
fi
# add symlinks to boost libs, this assumes boost 1.42.0
(cd $SYSROOT/usr/lib; for f in libboost*.so.1.42.0; do ln -s $f ${f%.1.42.0}; done)

(cd $SYSROOT && find . -ls) >$DEST/sysroot.txt

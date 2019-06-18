#!/bin/sh
#
# Version 1.0.1 Copyright (c) Magnus (Mem) Sandberg 2019
# Email: mem (a) datakon , se
#
# Created by Mem, 2019-05-29
# Based on luksmount, created by Mem, 2019-05-29
#
# Developed for udisks2 2.8.1-4 (Debian 10.x Buster)
#
# Depends: udisks2
#
# Default settings, change by edit $HOME/.config/luks-mgmt.conf
IMAGEPATH="$HOME/.images"
CONFIG=$HOME/.config/luks-mgmt.conf
DEBUG=0

[ -f $CONFIG ] && . $CONFIG

if [ "x$1" = "x-v" ] ; then
    DEBUG=1
    shift
fi

if [ "x$1" = "x" ] || [ "x$1" = "x-h" ] ; then
    echo "Usage: $0 [-h] [-v] <volume>"
    echo
    echo " -h      : show this help text"
    echo " -v      : verbose mode"
    echo
    echo " Mounted volumes :"
    /usr/sbin/losetup -l | grep $IMAGEPATH | awk '{ print $6 }' | sed -e 's#.*/#   #' | sed -e 's/\.img$//'
    echo
    exit
fi

volume=$1
if [ ! -f ${IMAGEPATH}/${volume}.img ] ; then
    echo "Could not find volume ${volume}"
    exit 1
fi

R=$( /usr/sbin/losetup -l | grep "${IMAGEPATH}/${volume}.img" ) ; RC=$?
if [ $RC -eq 0 ] ; then
    loopdev=$( echo $R | awk '{ print $1 }' )
    [ $DEBUG -gt 0 ] && echo "Image $volume mapped to ${loopdev}."
else
    echo "Image not in use."
    exit
fi

loopd=$( echo $loopdev | sed -e 's#.*/##' )
R=$( udisksctl dump | egrep '( | CryptoBacking)Device: ' | grep -A1 "CryptoBackingDevice:.*/${loopd}" ) ; RC=$?
if [ $RC -eq 0 ] ; then
    fsdev=$( echo $R | awk '{ print $4 }' )
    [ $DEBUG -gt 0 ] && echo "Filesystem unlocked as ${fsdev}."
else
    echo "Filesystem not unlocked, tear down loop device."
    udisksctl loop-delete -b $loopdev
    exit
fi

R=$( df --output=target ${fsdev} ) ; RC=$?
filesys=$( echo $R | awk '{ print $3 }' )
if [ $RC -eq 0 ] && [ "x$filesys" != "x/dev" ] ; then
    [ $DEBUG -gt 0 ] && echo "Filesystem mounted at ${filesys}, un-mounting."
    udisksctl unmount -b $fsdev
else
    echo "Filesystem not mounted."
fi
[ $DEBUG -gt 0 ] &&  echo "Locking filesystem"
udisksctl lock -b $loopdev
echo "Tear down loop device."
udisksctl loop-delete -b $loopdev

#!/bin/sh
#
# Version 1.3 Copyright (c) Magnus (Mem) Sandberg 2019
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
PHYSDEV=0

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
    echo " The script can also unmount devices like USB sticks."
    echo " Mounted LUKS devices :"
    lsblk -o NAME,FSTYPE -i | grep -A1 crypto_LUKS | sed -e 's/^|[- ]//' | awk '{ print $1 " " $2 }' | sed -z -e 's/LUKS\n`-/LUKS @@/g' | sed -e 's/^`-//' | grep "LUKS" | grep '@@' | grep -v "^loop" | awk '{ print "   /dev/" $1 }'

    echo
    exit
fi

volume=$1
if echo $volume | grep "\.\." >/dev/null ; then
    echo "Dangerous filename including '..': $volume"
    exit 1
fi
if echo $volume | grep "\./" >/dev/null ; then
    echo "Un-supported filename including './': $volume"
    exit 1
fi
if echo $volume | grep "^/dev/" >/dev/null ; then
    PHYSDEV=1
    if [ ! -b $volume ] ; then
	echo "Device ${volume} doesn't exists or is not a block device."
	exit 1
    fi
else
    if echo $volume | grep "/" >/dev/null ; then
	echo "Un-supported filename including '/': $volume"
	echo "No path under or outside $IMAGEPATH supported!"
	exit 1
    fi
    if echo $volume | grep " " >/dev/null ; then
	echo "Un-supported filename including ' ' (space char): $volume"
	exit 1
    fi
    volume=$( echo $volume | sed -e 's/\.img$//' )
    if [ ! -f ${IMAGEPATH}/${volume}.img ] ; then
	echo "Could not find volume ${volume}"
	exit 1
    fi
fi

if [ $PHYSDEV -eq 0 ] ; then
    R=$( /usr/sbin/losetup -l | grep "${IMAGEPATH}/${volume}.img" ) ; RC=$?
    if [ $RC -eq 0 ] ; then
	loopdev=$( echo $R | awk '{ print $1 }' )
	[ $DEBUG -gt 0 ] && echo "Image $volume mapped to ${loopdev}."
    else
	echo "Image not in use."
	exit
    fi
    luksdev=$loopdev
else
    luksdev=$volume
fi

loopd=$( echo $luksdev | sed -e 's#.*/##' )
R=$( udisksctl dump | egrep '( | CryptoBacking)Device: ' | grep -A1 "CryptoBackingDevice:.*/${loopd}" ) ; RC=$?
if [ $RC -eq 0 ] ; then
    fsdev=$( echo $R | awk '{ print $4 }' )
    [ $DEBUG -gt 0 ] && echo "Filesystem unlocked as ${fsdev}."
else
    echo "Filesystem not unlocked."
    if [ $PHYSDEV -eq 0 ] ; then
	echo "Tear down loop device."
	udisksctl loop-delete -b $loopdev
    fi
    exit
fi

R=$( df --output=target ${fsdev} ) ; RC=$?
filesys=$( echo $R | awk '{ print $3 }' )
if [ $RC -eq 0 ] && [ "x$filesys" != "x/dev" ] ; then
    [ $DEBUG -gt 0 ] && echo "Filesystem mounted at ${filesys}, un-mounting."
    R=$( udisksctl unmount -b $fsdev 2>&1 ) ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo "Unmount problems: $R"
	exit 1
    fi
else
    echo "Filesystem not mounted."
fi
[ $DEBUG -gt 0 ] &&  echo "Locking filesystem"
R=$( udisksctl lock -b $luksdev 2>&1 ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo "Lock problems: $R"
    exit 1
fi
if [ $PHYSDEV -eq 0 ] ; then
    echo "Tear down loop device."
    udisksctl loop-delete -b $loopdev
else
    read -p "Power off $luksdev (y/N): " R
    case $R in
	y|Y|[yY][eE][sS])
	    [ $DEBUG -gt 0 ] && echo "Powering off $luksdev."
	    R=$( udisksctl power-off -b $luksdev ) ; RC=$?
	    if [ $RC -gt 0 ] ; then
		echo "Power off problems: $R"
		exit 1
	    fi
	    ;;
	*)
	;;
    esac
fi

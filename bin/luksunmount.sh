#!/bin/bash
#
# Version 2.1 Copyright (c) Magnus (Mem) Sandberg 2019,2022
# Email: mem (a) datakon , se
#
# Created by Mem, 2019-05-29
# Based on luksmount, created by Mem, 2019-05-29
#
# Developed for udisks2 2.8.1-4 (Debian 10.x Buster)
#
# Depends: udisks2
#
# Required luks-functions version
REQ_LUKS_FUNCTIONS_MAJOR="1"
REQ_LUKS_FUNCTIONS_MINOR="6"
#
# Default settings, change by edit $HOME/.config/luks-mgmt.conf
IMAGEPATH="$HOME/.images"
EXCLUDEDEVS=""
CONFIG=$HOME/.config/luks-mgmt.conf
[ -f $CONFIG ] && . $CONFIG

# Commandline options and device type
DEBUG=0
PHYSDEV=0

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
    lsblk -o NAME,FSTYPE -i | grep -A1 crypto_LUKS | sed -e 's/^|[- ]//' | awk '{ print $1 " " $2 }' | sed -z -e 's/LUKS\n`-/LUKS @@/g' | sed -e 's/^`-//' | grep "LUKS" | grep '@@' | grep -v "^loop" | awk '{ print "   /dev/" $1 }' | egrep -v "${EXCLUDEDEVS}"

    echo
    exit
fi

if ! which udisksctl >/dev/null 2>&1 ; then
    echo "This script needs 'udisksctl' command (Debian package: udisks2), exiting."
    exit 1
fi

# Find location of this script it self to locate functions to include
# Search path /lib/luks-mgmt/luks-functions, DIRNAME($0)/../lib/luks-functions, DIRNAME($0)/luks-functions,
# https://www.cyberciti.biz/faq/unix-linux-appleosx-bsd-bash-script-find-what-directory-itsstoredin/

[ $DEBUG -gt 0 ] && echo "Looking for 'luks-functions' location"
if [ -r /lib/luks-mgmt/luks-functions ]; then
    [ $DEBUG -gt 0 ] && echo "Sourcing /lib/luks-mgmt/luks-functions"
    . /lib/luks-mgmt/luks-functions
else
    # Find location of this script it self
    _scriptdir="$( dirname $( readlink -f ${BASH_SOURCE[0]} ) )"
#   [ $DEBUG -gt 0 ] && echo "Script's location: $_scriptdir"
    _libdir="$( echo $_scriptdir | sed -e 's#/$##' | sed -e 's/[^/]\+$/lib/' )"
#   [ $DEBUG -gt 0 ] && echo "Lib dir: $_libdir"

    if [ -r $_libdir/luks-functions ]; then
	[ $DEBUG -gt 0 ] && echo "Sourcing $_libdir/luks-functions"
	. $_libdir/luks-functions
    elif [ -r $_scriptdir/luks-functions ]; then
	[ $DEBUG -gt 0 ] && echo "Sourcing $_scriptdir/luks-functions"
	. $_scriptdir/luks-functions
    else
	echo "Could not find any 'luks-functions' to include!"
	exit 1
    fi
fi

if [ "x${LUKS_FUNCTIONS_MAJOR}" = "x" ] ; then
    echo "Could not find LUKS_FUNCTIONS_MAJOR, luks-functions file too old."
    exit 1
fi
if [ "x${LUKS_FUNCTIONS_MINOR}" = "x" ] ; then
    echo "Could not find LUKS_FUNCTIONS_MINOR, luks-functions file too old."
    exit 1
fi
[ $DEBUG -gt 0 ] && echo "LUKS_FUNCTIONS_MAJOR: ${LUKS_FUNCTIONS_MAJOR}"
[ $DEBUG -gt 0 ] && echo "LUKS_FUNCTIONS_MINOR: ${LUKS_FUNCTIONS_MINOR}"
if [ ${LUKS_FUNCTIONS_MAJOR} -ne ${REQ_LUKS_FUNCTIONS_MAJOR} ] ; then
    echo
    echo "Found LUKS_FUNCTIONS_MAJOR: ${LUKS_FUNCTIONS_MAJOR}"
    echo "This script needs major verion: ${REQ_LUKS_FUNCTIONS_MAJOR}"
    exit 1
fi
if [ ${LUKS_FUNCTIONS_MINOR} -lt ${REQ_LUKS_FUNCTIONS_MINOR} ] ; then
    echo
    echo "Found LUKS_FUNCTIONS_MINOR: ${LUKS_FUNCTIONS_MINOR}"
    echo "This script needs minor verion ${REQ_LUKS_FUNCTIONS_MINOR} or higher."
    exit 1
fi

# Validate volume (file) name
R=$( valid_volume "$1" ) ; RC=$?
if [ $RC -gt 1 ] ; then
    echo "$R" ; exit $RC
elif [ $RC -eq 1 ] ; then
    echo "No volume found with filename: ${R}.img"
    exit 1
fi
volume="$R"

# If image file, find loop device.
# Otherwise the volume name should be the block device it self.
if echo $volume | grep "^/dev/" >/dev/null ; then
    PHYSDEV=1
    luksdev=$volume
    [ $DEBUG -gt 0 ] && echo "Block device: ${volume}"
else
    R=$( /usr/sbin/losetup -l | grep "${IMAGEPATH}/${volume}.img" ) ; RC=$?
    if [ $RC -eq 0 ] ; then
	loopdev=$( echo $R | awk '{ print $1 }' )
	[ $DEBUG -gt 0 ] && echo "Image $volume mapped to ${loopdev}"
    else
	echo "Image not in use."
	exit
    fi
    luksdev=$loopdev
fi

# Chech that it is a LUKS volume
R=$( check_if_luks_volume "${luksdev}" ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo "$R"
    # If we handled the loop device, tear it down
    if [ $PHYSDEV -eq 0 ] ; then
	[ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}"
	R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
	if [ $RC2 -gt 0 ] ; then
	    echo "$R" ; exit $RC2
	fi
    fi
    exit $RC
fi
[ $DEBUG -gt 0 ] && echo "Is a LUKS volume type: $R"

# Chech if unlocked
R=$( check_if_unlocked "${luksdev}" ) ; RC=$?
if [ $RC -eq 0 ] ; then
    # Is unlocked
    fsdev="$R"
    [ $DEBUG -gt 0 ] && echo "LUKS volume unlocked as ${fsdev}"
else
    if [ $PHYSDEV -eq 0 ] ; then
	[ $DEBUG -gt 0 ] && echo "LUKS volume not unlocked, tear down of loop device ${loopdev}"
	R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
	if [ $RC2 -gt 0 ] ; then
	    echo "$R" ; exit $RC2
	fi
    fi
    exit
fi

# Check if mounted
R=$( check_if_mounted "${fsdev}" ) ; RC=$?
if [ $RC -eq 0 ] ; then
    filesys="$R"
    [ $DEBUG -gt 0 ] && echo "Filesystem mounted at ${filesys}, un-mounting."
    R=$( unmount_fs "${fsdev}" ) ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo "$R" ; exit $RC
    fi
else
    echo "Filesystem not mounted."
fi

# Locking the LUKS volume
[ $DEBUG -gt 0 ] &&  echo "Locking LUKS volume."
R=$( lock_volume "${luksdev}" ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo "$R"
fi

if [ $PHYSDEV -eq 0 ] ; then
    [ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}"
    R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
    if [ $RC2 -gt 0 ] ; then
	echo "$R" ; exit $RC2
    fi
else
    read -p "Power off $luksdev (y/N): " R
    case $R in
	y|Y|[yY][eE][sS])
	    [ $DEBUG -gt 0 ] && echo "Powering off ${luksdev}"
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

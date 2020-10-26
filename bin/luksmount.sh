#!/bin/bash
# bash is needed to use read that has silent mode to not echo passphrase
#
# Version 1.3 Copyright (c) Magnus (Mem) Sandberg 2019
# Email: mem (a) datakon , se
#
# Created by Mem, 2019-05-29
# Inspired by root's tcmount, created by Mem, 2019-03-26
#
# Developed for udisks2 2.8.1-4 (Debian 10.x Buster)
#
# Depends: udisks2, yubikey-personalization
#
# Default settings, change by edit $HOME/.config/luks-mgmt.conf
CONCATENATE=0
HASH=0
YKSLOT="2"
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
    echo " -h      : Show this help text"
    echo " -v      : Verbose mode"
    echo
    echo " Volumes :"
    ls -1 ${IMAGEPATH}/*.img | sed -e 's#.*/#   #' -e 's#\..*$##'
    echo
    echo " The script can also mount devices like USB sticks."
    echo " Available LUKS devices :"
    lsblk -o NAME,FSTYPE -i | grep -A1 crypto_LUKS | sed -e 's/^|[- ]//' | awk '{ print $1 " " $2 }' | sed -z -e 's/LUKS\n`-/LUKS @@/g' | sed -e 's/^`-//' | grep "LUKS" | grep -v '@@' | grep -v "^loop" | awk '{ print "   /dev/" $1 }'
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

do_yubikey () {
    read -s -p "Enter challenge: " pph ; echo
    [ $HASH -gt 0 ] && pph=$(printf %s "$pph" | sha256sum | awk '{print $1}')
    echo "Sending challenge to YubiKey, press button if blinking."
    Resp="$(ykchalresp -${YKSLOT} "$pph" || true )"
    if [ -z "$Resp" ] ; then
	unset pph ; unset Resp
	echo "Yubikey not available, wrong config (slot ${YKSLOT}) or timed out waiting for button press."
	exit 1
    fi
    [ $CONCATENATE -gt 0 ] ; Resp=$pph$Resp
    echo "Unlock of $luksdev will take a number of seconds, standby..."
    R=$( udisksctl unlock -b $luksdev --key-file <( echo -n "$Resp" ) ) ; RC=$?
    unset pph ; unset Resp
    [ $DEBUG -gt 0 ] && echo "\$R: '$R'"
    if [ "$R" = "Passphrase: " ] ; then
	echo
	echo "Passphrase prompt as response from unlock."
	echo
	if [ $PHYSDEV -eq 0 ] ; then
	    echo "Tear down loop device."
	    udisksctl loop-delete -b $loopdev
	fi
	exit 1
    fi
}

if [ $PHYSDEV -eq 0 ] ; then
    R=$( /usr/sbin/losetup -l | grep "${IMAGEPATH}/${volume}.img" ) ; RC=$?
    if [ $RC -eq 0 ] ; then
	loopdev=$( echo $R | awk '{ print $1 }' )
	[ $DEBUG -gt 0 ] && echo "Image $volume already mapped to ${loopdev}."
    else
	R=$( udisksctl loop-setup -f ${IMAGEPATH}/${volume}.img ) ; RC=$?
	[ $RC -gt 0 ] && exit $RC
	loopdev=$( echo $R | sed -e 's/.* as //' | sed -e 's/\.$//' )
	[ $DEBUG -gt 0 ] && echo "Loop dev: ${loopdev}."
    fi
    luksdev=$loopdev
else
    luksdev=$volume
fi

loopd=$( echo $luksdev | sed -e 's#.*/##' )
R=$( udisksctl dump | egrep '( | CryptoBacking)Device: ' | grep -A1 "CryptoBackingDevice:.*/${loopd}" ) ; RC=$?
if [ $RC -eq 0 ] ; then
    fsdev=$( echo $R | awk '{ print $4 }' )
    [ $DEBUG -gt 0 ] && echo "Filesystem already unlocked as ${fsdev}."
else
    echo ; echo "Unlock volume: $volume"
    R=$( ykinfo -q -${YKSLOT} 2>/dev/null ) ; RC=$?
    if [ $RC -eq 0 ] && [ $R -eq 1 ]; then
	echo "Found attached YubiKey, will use challenge-response."
	do_yubikey
    else
	echo "No configured YubiKey (slot ${YKSLOT}) found."
	read -p "Continue without YubiKey (y/N): " R
	case $R in
	    y|Y|[yY][eE][sS])
		echo
		echo "No configured YubiKey (slot ${YKSLOT}) found, will use static passphrase."
		R=$( udisksctl unlock -b $luksdev ) ; RC=$?
		if [ $RC -gt 0 ] ; then
		    echo "Could not unlock volume, maybe wrong passphrase."
		    echo $R
		    if [ $PHYSDEV -eq 0 ] ; then
			echo "Tear down loop device."
			udisksctl loop-delete -b $loopdev
		    fi
		    exit $RC
		fi
		;;
	    *)
		R=$( ykinfo -q -${YKSLOT} 2>/dev/null ) ; RC=$?
		if [ $RC -eq 0 ] && [ $R -eq 1 ]; then
		    echo "Found attached YubiKey, will use challenge-response."
		    do_yubikey
		else
		    echo "No configured YubiKey (slot ${YKSLOT}) found, exiting."
		    if [ $PHYSDEV -eq 0 ] ; then
			echo "Tear down loop device."
			udisksctl loop-delete -b $loopdev
		    fi
		    exit
		fi
		;;
	esac
    fi
    fsdev=$( echo $R | sed -e 's/.* as //' | sed -e 's/\.$//' )
    [ $DEBUG -gt 0 ] && echo "Filesystem dev: ${fsdev}."
fi

R=$( df --output=target ${fsdev} ) ; RC=$?
filesys=$( echo $R | awk '{ print $3 }' )
if [ $RC -eq 0 ] && [ "x$filesys" != "x/dev" ] ; then
    echo "Filesystem already mounted at ${filesys}."
else
    R=$( udisksctl mount -b $fsdev ) ; RC=$?
    [ $RC -gt 0 ] && exit $RC
    filesys=$( echo $R | sed -e 's/.* at //' | sed -e 's/\.$//' )
    echo "Filesystem mounted at ${filesys}"
fi

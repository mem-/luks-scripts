#!/bin/bash
# bash is needed to use read that has silent mode to not echo passphrase
#
# Version 1.1 Copyright (c) Magnus (Mem) Sandberg 2019
# Email: mem (a) datakon , se
#
# Created by Mem, 2019-05-29
# Inspired by root's tcmount, created by Mem, 2019-03-26
#
# Developed for udisks2 2.8.1-4 (Debian 10.x Buster)
#
# Depends: socat, udisks2, yubikey-personalization
#
# Default settings, change by edit $HOME/.config/luks-mgmt.conf
CONCATENATE=0
HASH=0
YKSLOT="2"
IMAGEPATH="$HOME/.images"
CONFIG=$HOME/.config/luks-mgmt.conf
DEBUG=0

[ -f $CONFIG ] && . $CONFIG

# Sleep values when running 'socat' as wrapper for 'udiskctl unlock'
sleepbefore=2 ; sleepafter=7

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
    echo " Volumes :"
    ls -1 ${IMAGEPATH}/*.img | sed -e 's#.*/#   #' -e 's#\..*$##'
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
    [ $DEBUG -gt 0 ] && echo "Image $volume already mapped to ${loopdev}."
else
    R=$( udisksctl loop-setup -f ${IMAGEPATH}/${volume}.img ) ; RC=$?
    [ $RC -gt 0 ] && exit $RC
    loopdev=$( echo $R | sed -e 's/.* as //' | sed -e 's/\.$//' )
    [ $DEBUG -gt 0 ] && echo "Loop dev: ${loopdev}."
fi

loopd=$( echo $loopdev | sed -e 's#.*/##' )
R=$( udisksctl dump | egrep '( | CryptoBacking)Device: ' | grep -A1 "CryptoBackingDevice:.*/${loopd}" ) ; RC=$?
if [ $RC -eq 0 ] ; then
    fsdev=$( echo $R | awk '{ print $4 }' )
    [ $DEBUG -gt 0 ] && echo "Filesystem already unlocked as ${fsdev}."
else
    R=$( ykinfo -q -${YKSLOT} 2>/dev/null ) ; RC=$?
    if [ $RC -eq 0 ] && [ $R -eq 1 ]; then
	echo "Found attached YubiKey, will use challenge-response."
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
	echo "Unlock of $loopdev will take a number of seconds, standby..."
	[ $DEBUG -gt 0 ] && echo "Sleep before socat unlocks $loopdev: ${sleepbefore}."
	[ $DEBUG -gt 0 ] && echo "Sleep adter socat unlocked $loopdev: ${sleepafter}."
	R=$( (sleep ${sleepbefore}; echo "$Resp"; sleep ${sleepafter}) | socat - EXEC:"udisksctl unlock -b $loopdev",pty,setsid,ctty ) ; RC=$?
	unset pph ; unset Resp
	R=$( echo $R | sed -e 's/\r$//' ) # as socat adds trailing <CR>
	[ $DEBUG -gt 0 ] && echo "\$R: '$R'"
	if [ "$R" = "Passphrase: " ] ; then
	    echo
	    echo "Passphrase prompt as response from unlock."
	    echo "Variable \$sleepafter probably has to be increased."
	    echo
	    echo "Tear down loop device."
	    udisksctl loop-delete -b $loopdev
	    exit 1
	fi
    else
	echo "No configured YubiKey (slot ${YKSLOT}) found, will use static passphrase."
	R=$( udisksctl unlock -b $loopdev ) ; RC=$?
    fi
    if [ $RC -gt 0 ] ; then
	echo "Could not unlock volume, maybe wrong passphrase."
	echo $R
	echo "Tear down loop device."
	udisksctl loop-delete -b $loopdev
	exit $RC
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

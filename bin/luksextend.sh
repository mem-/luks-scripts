#!/bin/bash
# bash is needed to use 'read' command that has silent mode to not echo passphrase
#
# Version 0.9 Copyright (c) Magnus (Mem) Sandberg 2020
# Email: mem (a) datakon , se
#
# Created by Mem, 2020-03-14
#
# Inspired by 'yubikey-luks-enroll' from yubikey-luks, https://github.com/cornelinux/yubikey-luks
# Also inspired by my own 'tcmount' script for mount TrueCrypt volumes
#
# Developed for udisks2 2.8.1-4 (Debian 10.x Buster)
#
# Depends Debian packages:    socat, udisks2, yubikey-personalization (need when using YubiKey)
# Recommends Debian packages: a2ps
#
# Default settings, change by edit $HOME/.config/luks-mgmt.conf
CONCATENATE=0
HASH=0
YKSLOT="2"
SPARSE=0
SUCMD="su --login -c"
IMAGEPATH="$HOME/.images"
CONFIG=$HOME/.config/luks-mgmt.conf
DEBUG=0
PHYSDEV=0

[ -f $CONFIG ] && . $CONFIG

# Sleep values when running 'socat' as wrapper for 'udiskctl unlock'
sleepbefore=2 ; sleepafter=5

if [ "x$1" = "x-v" ] ; then
    DEBUG=1
    shift
fi

if [ "x$1" = "x" ] || [ "x$1" = "x-h" ] ; then
    echo
    echo "Usage: $0 [-h] [-v] <volume>"
    echo
    echo " -h       : Show this help text"
    echo " -v       : Verbose mode"
    echo
    echo " <volume> : The volume filename to be extended, with or without '.img' extension"
    echo "          : volume should be located in ${IMAGEPATH}/"
    echo "          : Available volumes :"
    ls -1 ${IMAGEPATH}/*.img | sed -e 's#.*/#            #' -e 's#\..*$##'
    echo "          :"
    echo "          : The volume can also be a physical device, like USB stick,"
    echo "          : Available LUKS devices :"
    lsblk -o NAME,FSTYPE -i | grep -A1 crypto_LUKS | sed -e 's/^|[- ]//' | awk '{ print $1 " " $2 }' | sed -z -e 's/LUKS\n`-/LUKS @@/g' | sed -e 's/^`-//' | grep "LUKS" | grep -v '@@' | grep -v "^loop" | awk '{ print "            /dev/" $1 }'
    echo
    exit
fi

if ! which udisksctl >/dev/null 2>&1 ; then
    echo "This script needs 'udisksctl' command (Debian package: udisks2), exiting."
    exit 1
fi

if ! which socat >/dev/null 2>&1 ; then
    echo "This script needs 'socat' command (Debian package: socat), exiting."
    exit 1
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

# Make sure the volume is not mounted
echo "Unmounting ${volume}, if in use"
luksunmount $volume
echo

echo "ENDING"
exit


if [ $PHYSDEV -eq 0 ] ; then
    echo "Extending LUKS volume in image file ${IMAGEPATH}/${volume}.img"
    read -p "Enter image size in 'dd' format (512M, 1G, etc): " R
    if [ $SPARSE -gt 0 ] ; then
	# Using 'if [[ ]]' as case statements doesn't do regex
	if [[ "$R" =~  ^[0-9]+$ ]] ||
	       [[ "$R" =~ ^[0-9]+c$ ]] ||
	       [[ "$R" =~ ^[0-9]+w$ ]] ||
	       [[ "$R" =~ ^[0-9]+b$ ]] ||
	       [[ "$R" =~ ^[0-9]+[kMGTPEZY]B$ ]] ||
	       [[ "$R" =~ ^[0-9]+[KMGTPEZY]$ ]] ; then
	    BS=1
	else
	    echo "Unknown size value for 'dd': $R"
	    cleanup_tmp
	    exit 1
	fi
	[ $DEBUG -gt 0 ] && echo "Block size for dd: $BS"
	[ $DEBUG -gt 0 ] && echo "Number of blocks to create: $R"

	if [ $DEBUG -gt 0 ] ; then
	    dd if=/dev/zero of=${IMAGEPATH}/${volume}.img bs=$BS count=0 seek=$R
	else
	    dd if=/dev/zero of=${IMAGEPATH}/${volume}.img bs=$BS count=0 seek=$R 2>&1 | egrep -v ' records | copied, '
	fi
    else
	# Using 'if [[ ]]' as case statements doesn't do regex
	if [[ "$R" =~  ^[0-9]+$ ]] ||
	  [[ "$R" =~ ^[0-9]+c$ ]] ||
	  [[ "$R" =~ ^[0-9]+w$ ]] ; then
	    BS=1
	elif [[ "$R" =~ ^[0-9]+b$ ]] ; then
	    BS=512
	    R=$( echo $R | tr -d 'b' )
	elif [[ "$R" =~ ^[0-9]+[kMGTPEZY]B$ ]] ; then
	    BS=1000
	    R=$( echo $R | sed -e 's/kB$//' | tr 'MGTPEZY' 'kMGTPEZ' )
	elif [[ "$R" =~ ^[0-9]+[KMGTPEZY]$ ]] ; then
	    BS=1024
	    R=$( echo $R | tr -d 'K' | tr 'MGTPEZY' 'KMGTPEZ' )
	else
	    echo "Unknown size value for 'dd': $R"
	    cleanup_tmp
	    exit 1
	fi
	[ $DEBUG -gt 0 ] && echo "Block size for dd: $BS"
	[ $DEBUG -gt 0 ] && echo "Number of blocks to create: $R"

	if [ $DEBUG -gt 0 ] ; then
	    dd if=/dev/zero of=${IMAGEPATH}/${volume}.img bs=$BS count=$R
	else
	    dd if=/dev/zero of=${IMAGEPATH}/${volume}.img bs=$BS count=$R 2>&1 | egrep -v ' records | copied, '
	fi
    fi
else
    echo
    echo " !!!"
    echo " !!! ALL DATA ON DEVICE $volume WILL BE ERASED"
    echo " !!!"
    echo " !!! Enter 'Yes' in uppercase to continue."
    echo " !!!"

    read -p "Continue: " R
    case $R in
	YES)
	    [ $DEBUG -gt 0 ] && echo "Continuing."
	    ;;
	*)
	    echo "You didn't answer 'YES', exiting."
	    cleanup_tmp
	    exit
	    ;;
    esac

    echo
    echo " >>>"
    echo " >>> Really overwrite $volume ?"
    echo " >>>"
    echo " >>> Enter 'Yes' in uppercase once more to continue."
    echo " >>>"

    read -p "Continue: " R
    case $R in
	YES)
	    [ $DEBUG -gt 0 ] && echo "Continuing."
	    ;;
	*)
	    echo "You didn't answer 'YES', exiting."
	    cleanup_tmp
	    exit
	    ;;
    esac
    echo
fi

if [ $PHYSDEV -eq 0 ] ; then
    echo
    echo "Select preferred mount-name, usually mounted under /media/$USER/, like /media/$USER/$volume"
    echo "The mount-name can be changed by root with 'tune2fs -L <new-name> <dev>' where <dev> usually is something like /dev/dm-X."
    read -p "Enter mount-name (default: $volume): " label
    [ -z $label ] && label=$volume
else
    echo
    echo "Select preferred mount-name, usually mounted under /media/$USER/, like /media/$USER/USB-encrypted"
    echo "The mount-name can be changed by root with 'tune2fs -L <new-name> <dev>' where <dev> usually is something like $volume."
    read -p "Enter mount-name (default: USB-encrypted): " label
    [ -z $label ] && label="USB-encrypted"
fi


echo
echo "OLD: Preparing for password generation and optional print-out."
echo
echo "OLD: Use YubiKey with Challenge-Response (Y/n): "


if [ $PHYSDEV -eq 0 ] ; then
    [ $DEBUG -gt 0 ] && echo -e "\nSetting up loopback device"
    R=$( udisksctl loop-setup -f ${IMAGEPATH}/${volume}.img ) ; RC=$?
    [ $RC -gt 0 ] && exit $RC
    loopdev=$( echo $R | sed -e 's/.* as //' | sed -e 's/\.$//' )
    [ $DEBUG -gt 0 ] && echo "Loop dev: ${loopdev}."
    luksdev=$loopdev
    lukslabel="luks_img-$volume"
else
    luksdev=$volume
    lukslabel="luks-$label"
fi

echo -e "\nCreating LUKS volume."
if [ $STATICPW -gt 0 ] ; then
    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
    # The first arg to 'printf' should be without '\n' otherwise the password will include NEWLINE
    $SUCMD "printf '%s' \"$( cat $tempdir/args.txt )\" | cryptsetup --label $lukslabel --key-file - luksFormat $luksdev" ; RC=$?
    [ $RC -eq 1 ] && echo -n "Something went wrong, did you miss to write 'yes' in uppercase?"
    if [ $RC -gt 0 ] ; then
	echo -e "\nCould not create LUKS volume, exiting."
	unset Resp ; unset PW1
	if [ $PHYSDEV -eq 0 ] ; then
	    [ $DEBUG -gt 0 ] && echo "Tear down loop device."
	    udisksctl loop-delete -b $loopdev
	    rm ${IMAGEPATH}/${volume}.img
	fi
	cleanup_tmp
	exit $RC
    fi
    if [ $CHALRESP -gt 0 ] ; then
	echo -e "\nAdding Challenge-Response to LUKS volume."
	echo "$Resp" >> $tempdir/args.txt
	echo "$Resp" >> $tempdir/args.txt
	if [ ! -z $SLOT ] && [ $SLOT -gt 0 ] ; then
	    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
	    $SUCMD "printf '%s\n' \"$( cat $tempdir/args.txt )\" | cryptsetup --key-slot=$SLOT luksAddKey $luksdev" ; RC=$?
	else
	    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
	    $SUCMD "printf '%s\n' \"$( cat $tempdir/args.txt )\" | cryptsetup luksAddKey $luksdev" ; RC=$?
	fi
    fi
    [ $DEBUG -gt 0 ] && echo -e "\nUnlocking LUKS volume."
    [ $DEBUG -gt 0 ] && echo "Sleep before socat unlocks $loopdev: ${sleepbefore}."
    [ $DEBUG -gt 0 ] && echo "Sleep adter socat unlocked $loopdev: ${sleepafter}."
    R=$( (sleep ${sleepbefore}; echo "$PW1"; sleep ${sleepafter}) | socat - EXEC:"udisksctl unlock -b $luksdev",pty,setsid,ctty ) ; RC=$?
    R=$( echo $R | sed -e 's/\r$//' ) # as socat adds trailing <CR>
    unset PW1 ; unset Resp
else
    echo "$Resp" > $tempdir/args.txt
    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
    # The first arg to 'printf' should be without '\n' otherwise the password will include NEWLINE
    $SUCMD "printf '%s' \"$( cat $tempdir/args.txt )\" | cryptsetup --label $lukslabel --key-file - luksFormat $luksdev" ; RC=$?
    [ $RC -eq 1 ] && echo -n "Something went wrong, did you miss to write 'yes' in uppercase?"
    if [ $RC -gt 0 ] ; then
	echo -e "\nCould not create LUKS volume, exiting."
	unset Resp
	if [ $PHYSDEV -eq 0 ] ; then
	    [ $DEBUG -gt 0 ] && echo "Tear down loop device."
	    udisksctl loop-delete -b $loopdev
	    rm ${IMAGEPATH}/${volume}.img
	fi
	cleanup_tmp
	exit $RC
    fi
    [ $DEBUG -gt 0 ] && echo -e "\nUnlocking LUKS volume."
    R=$( (sleep ${sleepbefore}; echo "$Resp"; sleep ${sleepafter}) | socat - EXEC:"udisksctl unlock -b $luksdev",pty,setsid,ctty ) ; RC=$?
    R=$( echo $R | sed -e 's/\r$//' ) # as socat adds trailing <CR>
    unset Resp
fi
[ $RC -gt 0 ] && exit $RC   # unlock failed...
fsdev=$( echo $R | sed -e 's/.* as //' | sed -e 's/\.$//' )
[ $DEBUG -gt 0 ] && echo "Filesystem dev: ${fsdev}."
echo

echo "Creating filesystem in LUKS volume."
echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
R=$( $SUCMD "mke2fs -t ext4 -L $label $fsdev 2>&1" ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo -e "\nSomething went wrong with 'mke2fs':"
    echo "Output from mke2fs (newlines stipped off):"
    echo $R
    echo
    if [ $PHYSDEV -eq 0 ] ; then
	udisksctl lock -b $luksdev
	udisksctl loop-delete -b $loopdev
    fi
    cleanup_tmp
    exit $RC
fi
echo

echo "Mounting filesystem."
[ $DEBUG -gt 0 ] && echo "Sleeping 2 seconds to make device to settle"
sleep 2
R=$( udisksctl mount -b $fsdev ) ; RC=$?
[ $RC -gt 0 ] && exit $RC
filesys=$( echo $R | sed -e 's/.* at //' | sed -e 's/\.$//' )
echo "Filesystem mounted at ${filesys}"
echo

myUID=$( id -u ) ; myGID=$( id -g )
echo "Changing user/group of newly created filesystem's root"
echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
$SUCMD "chown $myUID:$myGID ${filesys}/."

echo "Done!"
echo

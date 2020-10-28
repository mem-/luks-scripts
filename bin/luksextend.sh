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
# Depends Debian packages: udisks2, yubikey-personalization (need when using YubiKey)
#
# Default settings, change by edit $HOME/.config/luks-mgmt.conf
CONCATENATE=0
HASH=0
YKSLOT="2"
SPARSE=0
SUCMD="su --login -c"
IMAGEPATH="$HOME/.images"
CONFIG=$HOME/.config/luks-mgmt.conf
FIX=0
DEBUG=0
PHYSDEV=0
#
loop_state=0
fsdev_state=0
filesys_state=0

[ -f $CONFIG ] && . $CONFIG

if [ "x$1" = "x-v" ] ; then
    DEBUG=1
    shift
    if [ "x$1" = "x-f" ] ; then
	FIX=1
	shift
    fi
elif [ "x$1" = "x-f" ] ; then
    FIX=1
    shift
    if [ "x$1" = "x-v" ] ; then
	DEBUG=1
	shift
    fi
fi

if [ "x$1" = "x" ] || [ "x$1" = "x-h" ] ; then
    echo
    echo "Usage: $0 [-h] [-v] [-f] <volume> [<size>]"
    echo
    echo " -h       : Show this help text"
    echo " -v       : Verbose mode"
    echo " -f       : Fix steps that wasn't done during previous run"
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
    echo " <size>   : The new volume size."
    echo "          :"
    echo "          : For physical devices and partitions the <size> value will not matter,"
    echo "          : the entire device/partition will be used."
    echo "          :"
    echo "          : When using '+' prefix the new size is not an absolute size, then it"
    echo "          : indicates how much the volume should be extended."
    echo "          :"
    echo "          : When using '%' suffix the new size will be calcutated relative to"
    echo "          : the current size. '120%' is equal of '+20%'."
    echo "          : The size can only be increased, values below 100% or negative"
    echo "          : will be ignored."
    echo "          :"
    echo "          : If the size value is ombitted, you will be asked for new size when"
    echo "          : managing an image file."
    echo
    exit
fi

if ! which udisksctl >/dev/null 2>&1 ; then
    echo "This script needs 'udisksctl' command (Debian package: udisks2), exiting."
    exit 1
fi

# Find location of this script it self to locate functions to include
# Seach path /lib/luks-mgmt/luks-functions, DIRNAME($0)/../lib/luks-functions, DIRNAME($0)/luks-functions,
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
[ $DEBUG -gt 0 ] && [ $FIX -gt 0 ] && echo "Fix mode active."
[ $DEBUG -gt 0 ] && echo
addsize="$2"

# Validate volume (file) name
R=$( valid_volume "$1" ) ; RC=$?
if [ $RC -gt 1 ] ; then
    echo "$R" ; exit $RC
elif [ $RC -eq 1 ] ; then
    echo "No volume found with filename: ${R}.img"
    exit 1
fi
volume="$R"

# If image file, set up loop device.
# Otherwise the volume name should be the block device it self.
if echo $volume | grep "^/dev/" >/dev/null ; then
    PHYSDEV=1
    luksdev=$volume
    [ $DEBUG -gt 0 ] && echo "Block device: ${volume}."
else
    R=$( setup_loopdevice "${volume}" ) ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo "$R" ; exit $RC
    fi
    read loop_state loopdev <<<$( IFS=":"; echo $R )
    DEBUG_loopdev[0]="Image file attached to loop device: ${loopdev}."
    DEBUG_loopdev[1]="Image file already attached to ${loopdev}."
    [ $DEBUG -gt 0 ] && echo "${DEBUG_loopdev[$loop_state]}"
    luksdev=$loopdev
fi

# Chech that it is a LUKS volume
R=$( check_if_luks_volume "${luksdev}" ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo "$R"
    # If we handled the loop device, tear it down
    if [ $PHYSDEV -eq 0 ] && [ $loop_state -eq 0 ] ; then
	[ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}."
	R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
	if [ $RC2 -gt 0 ] ; then
	    echo "$R" ; exit $RC2
	fi
    fi
    exit $RC
fi
[ $DEBUG -gt 0 ] && echo "Is a LUKS volume type: $R"

R=$( volume_info "${IMAGEPATH}" "${volume}" ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo "$R" ; exit $RC
fi
volinfo="$R"
[ $DEBUG -gt 0 ] && echo -e "Volume info: ${volinfo}.\n"
read vol_sparse volsize_real volsize_human volsize_type volused_real volused_human diskfree_real diskfree_human <<<$( IFS=":"; echo $volinfo )

if [ $PHYSDEV -eq 0 ] && [ $FIX -eq 0 ] ; then
    if [ "x" = "x${addsize}" ] ;then
	echo "No new size was givven. Please enter new size in absolute or relative format."
	read -p "(current volume size ${volsize_human}): " addsize
	if [ "x" = "x${addsize}" ] ;then
	    echo "No size was entered, exiting!"
	    exit 1
	fi
    fi
    R=$( calc_newsize "${volsize_real}" "${addsize}" ) ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo "$R" ; exit $RC
    fi
    newsize="$R"
    addsize=$(( ${newsize} - ${volsize_real} ))
    newsize_human=$( int_to_human "$newsize" "$volsize_type" ) ; RC=$?
    newsize_human2=$( int_to_human "$newsize" "" ) ; RC=$?
    addsize_human=$( int_to_human "$addsize" "" ) ; RC=$?
    echo -n "New size: ${newsize_human}" ; [ "${volsize_type}" = "KiB" ] && echo -n "iB"
    [ "x${newsize_human}" = "x${newsize_human2}" ] && echo "." || echo " / ${newsize_human2}."
    [ $DEBUG -gt 0 ] && echo "Addition size: ${addsize} / ${addsize_human}."

    # Needed diskspace
    neededspace=$(( ${newsize} - ${volused_real} ))
    if [ $neededspace -ge $diskfree_real ] ;then
	if [ $SPARSE -eq 0 ] && [ $vol_sparse -eq 0 ] ; then
	    echo "Not enough space for new size, exiting."
	    if [ $loop_state -eq 0 ] ; then
		[ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}."
		R=$( teardown_loopdevice "$loopdev" ) ; RC=$?
		if [ $RC -gt 0 ] ; then
		    echo "$R" ; exit $RC
		fi
	    fi
	    exit 1
	else
	    echo
	    echo "The the total size exceeds available disk space."
	    echo "With sparse file it may be okay to overbook disk space."
	fi
    fi
    read -p "Continue (y/N): " R
    case $R in
	y|Y|[yY][eE]|[sS])
	    [ $DEBUG -gt 0 ] && echo "Continuing..."
	    ;;
	*)
	    echo "Aborting..."
	    if [ $loop_state -eq 0 ] ; then
		[ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}."
		R=$( teardown_loopdevice "$loopdev" ) ; RC=$?
		if [ $RC -gt 0 ] ; then
		    echo "$R" ; exit $RC
		fi
	    fi
	    exit 1
	    ;;
    esac
fi

# Chech if unlocked
R=$( check_if_unlocked "${luksdev}" ) ; RC=$?
if [ $RC -gt 0 ] ; then
    # We continue even when not unlocked
    #echo "$R" ; exit $RC
    [ $DEBUG -gt 0 ] && echo "$R"
    fsdev_state=0
    fsdev=""
    filesys=""
else
    fsdev_state=1
    fsdev="$R"
    [ $DEBUG -gt 0 ] && echo "LUKS volume unlocked as ${fsdev}."

    # Chech if mounted
    R=$( check_if_mounted "${fsdev}" ) ; RC=$?
    if [ $RC -eq 5 ] ; then
	# not mounted
	[ $DEBUG -gt 0 ] && echo "$R"
	filesys_state=0
	filesys=""
    elif [ $RC -gt 0 ] ; then
	echo "$R" ; exit $RC
    else
	filesys_state=1
	filesys="$R"
	[ $DEBUG -gt 0 ] && echo "Filesystem mounted at ${filesys}."
    fi
fi

# Unmount
if [ "x" != "x${fsdev}" ] || [ "x" != "x${filesys}" ] ; then
    echo "For now $( basename $( readlink -f ${BASH_SOURCE[0]} ) ) only supports off-line mode."

    read -p "Continue to bring ${volume} offline or quit (c/Q): " R
    case $R in
	n|N|q|Q|[nN][oO])
	    echo "Aborting..."
	    exit 1
	    ;;
	c|C|y|Y|[yY][eE][sS])
	    [ $DEBUG -gt 0 ] && echo "Continuing..."
	    ;;
	*)
	    echo "Aborting..."
	    exit 1
	    ;;
    esac

    if [ "x" != "x${filesys}" ] ; then
	[ $DEBUG -gt 0 ] && echo "Filesystem mounted at ${filesys}, un-mounting."
	R=$( unmount_fs "${fsdev}" ) ; RC=$?
	if [ $RC -gt 0 ] ; then
	    echo "$R"
	fi
    fi
    # In "FIX" mode, we doesn't need to look the volume
    if [ "x" != "x${fsdev}" ] && [ $FIX -eq 0 ] ; then
	[ $DEBUG -gt 0 ] &&  echo "Locking LUKS volume."
	R=$( lock_volume "${luksdev}" ) ; RC=$?
	if [ $RC -gt 0 ] ; then
	    echo "$R"
	fi
    fi
fi

# Do all the things related to the image file,
# unless in "FIX" mode as we assume the image file already extended and then loop device in place
if [ $PHYSDEV -eq 0 ] && [ $FIX -eq 0 ] ; then
    [ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}."
    R=$( teardown_loopdevice "$loopdev" ) ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo "$R" ; exit $RC
    fi

    # Go for sparse file if config says so of if volume is a sprase file
    if [ $SPARSE -gt 0 ] || [ $vol_sparse -gt 0 ] ; then
	[ $DEBUG -gt 0 ] && echo "Extending ${IMAGEPATH}/${volume}.img to new size (sparse mode): $newsize"

	if [ $DEBUG -gt 0 ] ; then
	    dd if=/dev/zero of=${IMAGEPATH}/${volume}.img bs=1 count=0 seek=$newsize
	else
	    dd if=/dev/zero of=${IMAGEPATH}/${volume}.img bs=1 count=0 seek=$newsize 2>&1 | egrep -v ' records | copied, '
	fi
    else
	# Check if size in MiB
	if [ "$(( ${addsize} / 1048576 * 1048576 ))" -eq ${addsize} ] ; then
	    BS=1M
	    addsize=$(( ${addsize} / 1048576 ))
	elif [ "$(( ${addsize} / 1000000 * 1000000 ))" -eq ${addsize} ] ; then
	    BS=1MB
	    addsize=$(( ${addsize} / 1000000 ))
	elif [ "$(( ${addsize} / 4096 * 4096 ))" -eq ${addsize} ] ; then
	    BS=4K
	    addsize=$(( ${addsize} / 4096 ))
	elif [ "$(( ${addsize} / 1024 * 1024 ))" -eq ${addsize} ] ; then
	    BS=1K
	    addsize=$(( ${addsize} / 1024 ))
	elif [ "$(( ${addsize} / 1000 * 1000 ))" -eq ${addsize} ] ; then
	    BS=1000
	    addsize=$(( ${addsize} / 1000 ))
	elif [ "$(( ${addsize} / 512 * 512 ))" -eq ${addsize} ] ; then
	    BS=512
	    addsize=$(( ${addsize} / 512 ))
	else
	    BS=1
	fi
	[ $DEBUG -gt 0 ] && echo "Block size for dd: $BS"
	[ $DEBUG -gt 0 ] && echo "Number of blocks to create: $addsize"

	if [ $DEBUG -gt 0 ] ; then
	    dd if=/dev/zero of=${IMAGEPATH}/${volume}.img conv=notrunc oflag=append bs=$BS count=$addsize
	else
	    dd if=/dev/zero of=${IMAGEPATH}/${volume}.img conv=notrunc oflag=append bs=$BS count=$addsize 2>&1 | egrep -v ' records | copied, '
	fi
    fi

    R=$( setup_loopdevice "${volume}" ) ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo "$R" ; exit $RC
    fi
    read R loopdev <<<$( IFS=":"; echo $R )
    [ $DEBUG -gt 0 ] && echo "Image file re-attached to loop device: ${loopdev}."
    luksdev=$loopdev
fi

unlock_volume R $luksdev ; RC=$?
if [ $RC -gt 0 ] ; then
    echo "$R"
    if [ $PHYSDEV -eq 0 ] && [ $loop_state -eq 0 ] ; then
	[ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}."
	R=$( teardown_loopdevice "$loopdev" ) ; RC=$?
	if [ $RC -gt 0 ] ; then
	    echo "$R" ; exit $RC
	fi
    fi
    exit $RC
fi
fsdev="$R"
[ $DEBUG -gt 0 ] && echo "Filesystem dev: ${fsdev}."


# As I understand 'cryptsetup -v resize $fsdev' isn't nesessary as it only updates mapping info if needed
# From man page:
#     Note  that  this  does  not change the raw device geometry,
#     it just changes how many sectors of the raw device are represented in the mapped device.


echo "Checking filesystem before resizing it."
echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
# Maybe replace 'y' with 'p' if spanwing "$SYCMD" as interactive command
R=$( $SUCMD "fsck -fvy $fsdev 2>&1" ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo -e "\nSomething went wrong with 'fsck':"
    echo "Output from fsck:"
    echo "$R"
    echo
    if [ $fsdev_state -eq 0 ] ; then
	[ $DEBUG -gt 0 ] &&  echo "Locking LUKS volume."
	R=$( lock_volume "${luksdev}" ) ; RC=$?
	if [ $RC -gt 0 ] ; then
	    echo "$R"
	fi
    fi
    if [ $PHYSDEV -eq 0 ] && [ $loop_state -eq 0 ] ; then
	[ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}."
	R=$( teardown_loopdevice "$loopdev" ) ; RC=$?
	if [ $RC -gt 0 ] ; then
	    echo "$R" ; exit $RC
	fi
    fi
    exit $RC
fi
echo
[ $DEBUG -gt 0 ] && echo -e "${R}\n"

echo "Resizing filesystem."
echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
R=$( $SUCMD "resize2fs $fsdev 2>&1" ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo -e "\nSomething went wrong with 'resize2fs':"
    echo "Output from resize2fs:"
    echo "$R"
    echo
    if [ $fsdev_state -eq 0 ] ; then
	[ $DEBUG -gt 0 ] &&  echo "Locking LUKS volume."
	R=$( lock_volume "${luksdev}" ) ; RC=$?
	if [ $RC -gt 0 ] ; then
	    echo "$R"
	fi
    fi
    if [ $PHYSDEV -eq 0 ] && [ $loop_state -eq 0 ] ; then
	[ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}."
	R=$( teardown_loopdevice "$loopdev" ) ; RC=$?
	if [ $RC -gt 0 ] ; then
	    echo "$R" ; exit $RC
	fi
    fi
    exit $RC
fi
echo
[ $DEBUG -gt 0 ] && echo -e "${R}\n"

[ $DEBUG -gt 0 ] && echo "Sleeping 2 seconds to allow device to settle."
sleep 2

echo "Checking filesystem after resizing it."
echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
# Maybe replace 'y' with 'p' if spanwing "$SYCMD" as interactive command
R=$( $SUCMD "fsck -fvy $fsdev 2>&1" ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo -e "\nSomething went wrong with 'fsck':"
    echo "Output from fsck:"
    echo "$R"
    echo
    if [ $fsdev_state -eq 0 ] ; then
	[ $DEBUG -gt 0 ] &&  echo "Locking LUKS volume."
	R=$( lock_volume "${luksdev}" ) ; RC=$?
	if [ $RC -gt 0 ] ; then
	    echo "$R"
	fi
    fi
    if [ $PHYSDEV -eq 0 ] && [ $loop_state -eq 0 ] ; then
	[ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}."
	R=$( teardown_loopdevice "$loopdev" ) ; RC=$?
	if [ $RC -gt 0 ] ; then
	    echo "$R" ; exit $RC
	fi
    fi
    exit $RC
fi
echo
[ $DEBUG -gt 0 ] && echo -e "${R}\n"

if [ $filesys_state -gt 0 ] ; then
    echo "Mounting filesystem after resize."
    R=$( udisksctl mount -b $fsdev ) ; RC=$?
    [ $RC -gt 0 ] && exit $RC
    filesys=$( echo $R | sed -e 's/.* at //' | sed -e 's/\.$//' )
    echo "Filesystem mounted at ${filesys}"
    echo
elif [ $fsdev_state -eq 0 ] ; then
    [ $DEBUG -gt 0 ] &&  echo "Locking LUKS volume."
    R=$( lock_volume "${luksdev}" ) ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo "$R"
    fi
    if [ $PHYSDEV -eq 0 ] && [ $loop_state -eq 0 ] ; then
	[ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}."
	R=$( teardown_loopdevice "$loopdev" ) ; RC=$?
	if [ $RC -gt 0 ] ; then
	    echo "$R" ; exit $RC
	fi
    fi
fi

echo "Done!"
echo

#!/bin/bash
# bash is needed to use read that has silent mode to not echo passphrase
#
# Version 2.1.2 Copyright (c) Magnus (Mem) Sandberg 2019-2022,2024
# Email: mem (a) datakon , se
#
# Created by Mem, 2019-05-29
# Inspired by root's tcmount, created by Mem, 2019-03-26
#
# Developed for udisks2 2.8.1-4 (Debian 10.x Buster)
#
# Depends on the following Debian packages: udisks2, yubikey-personalization (need when using YubiKey)
# Recommends Debian packages:               xclip
#
# Required luks-functions version
REQ_LUKS_FUNCTIONS_MAJOR="1"
REQ_LUKS_FUNCTIONS_MINOR="5"
#
# Default settings, change by edit $HOME/.config/luks-mgmt.conf
CONCATENATE=0
HASH=0
SLOT="7"
YKSLOT="2"
SPARSE=0
SUCMD="su --login -c"
IMAGEPATH="$HOME/.images"
EXCLUDEDEVS=""
CONFIG=$HOME/.config/luks-mgmt.conf
[ -f $CONFIG ] && . $CONFIG

# Commandline options and device type
FSCK=0
DEBUG=0
PHYSDEV=0
# State of things before the run of this script
loop_before=0
fsdev_before=0
filesys_before=0

my_usage () {
    echo "Usage: $0 [-h] [-v] [-f] <volume>"
    echo
    echo " -h       : Show this help text"
    echo " -v       : Verbose mode"
    echo " -f       : Do 'fsck' before mounting the filesystem,"
    echo "          : or ask to unmount to perform 'fsck'"
    echo
    echo " <volume> : The volume filename to be mounted, with or without '.img' extension"
    echo "          : volume should be located in ${IMAGEPATH}/"
    echo "          : Available volumes :"
    ls -1 ${IMAGEPATH}/*.img | sed -e 's#.*/#           - #' -e 's#\..*$##'
    echo
    echo "          : The volume can also be a physical device, like USB stick"
    echo "          : Available LUKS devices :"
    lsblk -o NAME,FSTYPE -i | grep -A1 crypto_LUKS | sed -e 's/^|[- ]//' | awk '{ print $1 " " $2 }' | sed -z -e 's/LUKS\n`-/LUKS @@/g' | sed -e 's/^`-//' | grep "LUKS" | grep -v '@@' | grep -v "^loop" | awk '{ print "           - /dev/" $1 }'
    echo
    exit 1
}

## https://medium.com/@Drew_Stokes/bash-argument-parsing-54f3b81a6a8f
## https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash
PARAMS=""
while (( "$#" )) ; do
    case "$1" in
	-h)
	    my_usage
	    ;;
	-v)
	    DEBUG=1
	    shift
	    ;;
	-f)
	    FSCK=1
	    shift
	    ;;
	-*|--*=*) # unsupported flags
	    my_usage
	    ;;
	*) # preserve positional arguments
	    PARAMS="$PARAMS $1"
	    shift
	    ;;
    esac
done
# Set positional arguments in their proper place
eval set -- "$PARAMS"
[ $# -ne 1 ] && my_usage

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

#[ $DEBUG -gt 0 ] && [ $FSCK -gt 0 ] && echo "Fsck will be done before mounting the actual filesystem."
[ $DEBUG -gt 0 ] && echo

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
    [ $DEBUG -gt 0 ] && echo "Block device: ${volume}"
else
    R=$( setup_loopdevice "${volume}" ) ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo "$R" ; exit $RC
    fi
    read loop_before loopdev <<<$( IFS=":"; echo $R )
    DEBUG_loopdev[0]="Image file attached to loop device: ${loopdev}"
    DEBUG_loopdev[1]="Image file already attached to ${loopdev}"
    [ $DEBUG -gt 0 ] && echo "${DEBUG_loopdev[$loop_before]}"
    luksdev=$loopdev
fi

# Chech that it is a LUKS volume
R=$( check_if_luks_volume "${luksdev}" ) ; RC=$?
if [ $RC -gt 0 ] ; then
    echo "$R"
    # If we handled the loop device, tear it down
    if [ $PHYSDEV -eq 0 ] && [ $loop_before -eq 0 ] ; then
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
    # Already unlocked
    fsdev_before=1
    fsdev="$R"
    [ $DEBUG -gt 0 ] && echo "LUKS volume already unlocked as ${fsdev}"
else
    # Unlock LUKS volume
    unlock_volume R $luksdev ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo -e "$R"
	if [ $PHYSDEV -eq 0 ] && [ $loop_before -eq 0 ] ; then
	    [ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}"
	    R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
	    if [ $RC2 -gt 0 ] ; then
		echo "$R" ; exit $RC2
	    fi
	fi
	exit $RC
    fi
    fsdev="$R"
    [ $DEBUG -gt 0 ] && echo "Filesystem dev: ${fsdev}"
fi

# Check if mounted
R=$( check_if_mounted "${fsdev}" ) ; RC=$?
if [ $RC -eq 5 ] ; then
    # not mounted
    [ $DEBUG -gt 0 ] && echo "$R"
elif [ $RC -gt 0 ] ; then
    # Not found
    echo "$R"
    if [ $fsdev_before -eq 0 ] ; then
	[ $DEBUG -gt 0 ] &&  echo "Locking LUKS volume."
	R=$( lock_volume "${luksdev}" ) ; RC=$?
	if [ $RC -gt 0 ] ; then
	    echo "$R"
	fi
    fi
    if [ $PHYSDEV -eq 0 ] && [ $loop_before -eq 0 ] ; then
	[ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}"
	R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
	if [ $RC2 -gt 0 ] ; then
	    echo "$R" ; exit $RC2
	fi
    fi
    exit $RC
else
    filesys_before=1
    filesys="$R"
fi

# Maybe time for 'fsck'
if [ $FSCK -gt 0 ] ; then
    if [ $filesys_before -gt 0 ] ; then
	echo "Filesystem mounted at ${filesys}"
	read -p "Unmout to perform 'fsck' (y/N): " R
	case $R in
	    y|Y|[yY][eE]|[sS])
		[ $DEBUG -gt 0 ] && echo "Continuing..."
		R=$( unmount_fs "${fsdev}" ) ; RC=$?
		if [ $RC -gt 0 ] ; then
		    echo "$R" ; exit $RC
		fi
		# To remount the filesystem after 'fsck' we change filesys_before
		filesys_before=0
		;;
	    *)
		echo "Leaving filesystem mounted, skipping 'fsck'."
		exit 0
		;;
	esac
    fi

    echo "Starting check of filesystem."
    echo "If asked, enter relevant password for '$( echo $SUCMD | awk '{ print $1 }' )' command."
    # Maybe replace 'y' with 'p' if spanwing "$SYCMD" as interactive command
    R=$( $SUCMD "fsck -fvy $fsdev 2>&1" ) ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo -e "\nSomething went wrong with 'fsck':"
	echo "Output from fsck:"
	echo "$R"
	echo
	if [ $fsdev_before -eq 0 ] ; then
	    [ $DEBUG -gt 0 ] &&  echo "Locking LUKS volume."
	    R=$( lock_volume "${luksdev}" ) ; RC=$?
	    if [ $RC -gt 0 ] ; then
		echo "$R"
	    fi
	fi
	if [ $PHYSDEV -eq 0 ] && [ $loop_before -eq 0 ] ; then
	    [ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}"
	    R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
	    if [ $RC2 -gt 0 ] ; then
		echo "$R" ; exit $RC2
	    fi
	fi
	exit $RC
    fi
    echo
    [ $DEBUG -gt 0 ] && echo -e "${R}\n"
fi

# Time to mount filesystem
# The following, similar code, also in lukscreate.sh, luksextend.sh
if [ $filesys_before -eq 0 ] ; then
    [ $FSCK -gt 0 ] && echo "Mounting filesystem after 'fsck'."
    R=$( udisksctl mount -b $fsdev ) ; RC=$?
    if [ $RC -gt 0 ] ; then
	echo -e "\nSomething went wrong with mount of filesystem:"
	echo "$R"
	echo
	if [ $fsdev_before -eq 0 ] ; then
	    [ $DEBUG -gt 0 ] &&  echo "Locking LUKS volume."
	    R=$( lock_volume "${luksdev}" ) ; RC2=$?
	    if [ $RC2 -gt 0 ] ; then
		echo "$R"
	    fi
	fi
	if [ $PHYSDEV -eq 0 ] && [ $loop_before -eq 0 ] ; then
	    [ $DEBUG -gt 0 ] && echo "Tear down of loop device ${loopdev}"
	    R=$( teardown_loopdevice "$loopdev" ) ; RC2=$?
	    if [ $RC2 -gt 0 ] ; then
		echo "$R" ; exit $RC2
	    fi
	fi
	exit $RC
    fi
    filesys=$( echo $R | sed -e 's/.* at //' | sed -e 's/\.$//' )
    echo "Filesystem mounted at ${filesys}"
else
    echo "Filesystem already mounted at ${filesys}"
fi

# If we find xclip, put path in clipboard buffer
if which xclip >/dev/null 2>&1 ; then
    echo "${filesys}" | xclip -i -r -selection c
    echo "Path added to clipboard buffer."
    echo 'Pro tip: cd $( xclip -o -selection c )'
fi

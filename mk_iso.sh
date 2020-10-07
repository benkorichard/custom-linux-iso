#!/bin/bash
#---help---
#
# Usage: mk_iso.sh [options]
#
# This script creates a customized bootable Linux ISO disk image.
# In order to run the script the following packages must be installed on the system: genisoimage, squashfs-tools.
# These packagae names apply to debian based distributions. On different distros they might have different names.
#
# NOTE: For now, this works ONLY with Ubuntu.
#
#
#
#   -d [PATH]       Destination directory of files copied into the new ISO.
#                   If it's not present on the original filesystem inside the ISO image, the directory will be created.
#
#                   Default: /usr/sbin
#
#   -s [PATH]       Source directory of files copied into the new ISO.
#
#                   Default: No default value. If not specified, no files will be copied. However, the image will be built.
#
#   -p [PACKAGES]   packages into the ISO image.
#
#                   Default: If not specified, no package will be installed. However, the image will be built.
#                   To install multiple packages at a time, enclose them with "" or ''.
#
#   -f [FILE]       File containing a list of packages to be instlled. Individual packages have to be separated with a newline.
#                   If a specific version of the package is required, it can be set as follows package=version
#
#                   Default: No default value. If not specified, no package will be installed. However, the image will be built.
#
#                   If both -p and -f are set, the -f option takes precedence. The -p option will be ignored.
#
#   -i [FILE]       Location of the original ISO file from which the customized image will be created.
#
#                   Default: Ubuntu-20.04.1-live-server-amd64.iso will be downloaded into the /tmp directory and used.
#
#   -o [FILE]       Output ISO file
#
#                   Default: /tmp/custom-image-<DATE>.iso, where DATE is in YYMMDDHHmm fomrate - i.e. /tmp/custom-image-202009042003.iso
#
#   -h              Display this help.
#
# https://github.com/benkorichard/custom-linux-iso.git
#
#---help---

function cleanup {
	umount ${MK_ISO_WORKDIR}/mount

	rm -fr ${MK_ISO_WORKDIR}
}

function copy_scripts {
	[[ -n ${MK_ISO_DESTINATION} ]] \
		|| MK_ISO_DESTINATION='/usr/sbin/'

	local copy_to="${MK_ISO_WORKDIR}/squashfs${MK_ISO_DESTINATION}"

	if [[ ! -d ${MK_ISO_SOURCE} ]]
	then
		echo "Source directory ${MK_ISO_SOURCE} does not exist."
	else
		[[ -d ${copy_to} ]] \
			|| mkdir ${copy_to}

		for file in $(find ${MK_ISO_SOURCE} -type f)
		do
			[[ -x ${file} ]] \
				|| chmod +x ${file}
			echo ""
			echo "Copying ${file} to ${copy_to}"
			echo ""
			cp ${file} ${copy_to}
		done
	fi
}

function find_package_manager {
	declare -A os_info

	local os_info[${MK_ISO_WORKDIR}/squashfs/etc/redhat-release]=yum
	local os_info[${MK_ISO_WORKDIR}/squashfs/etc/SuSE-release]=zypp
	local os_info[${MK_ISO_WORKDIR}/squashfs/etc/debian_version]=apt

	for f in ${!os_info[@]}
	do
		[[ -f ${f} ]] \
			&& MK_ISO_PACKAGE_MANAGER="${os_info[$f]}"
	done
}

function install_packages {
	find_package_manager

	##
	## https://stackoverflow.com/questions/59895/how-to-get-the-source-directory-of-a-bash-script-from-within-the-script-itself
	##
	local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

	source ${script_dir}/libs/_${MK_ISO_PACKAGE_MANAGER}

	local from=${1}

	##
	## To have name resolution inside chroot environment. Otherwise the apt cannot resolve the repositories.
	##
	mount -o bind /run ${MK_ISO_WORKDIR}/squashfs/run

	if [[ ${from} == 'file' ]]
	then
		local old_IFS="${IFS}"
		IFS=$'\r\n'
		GLOBIGNORE='*'

		MK_ISO_PACKAGES=$(cat ${MK_ISO_PACKAGE_FILE})

		IFS="${old_IFS}"
		echo "Installing packages: ${MK_ISO_PACKAGES}"
		install
	elif [[ "${from}" == 'list' ]]
	then
		echo "Installing packages: ${MK_ISO_PACKAGES}"
		install > /dev/null
	else
		echo ""
		echo "No packages will be installed."
		echo ""
	fi

	umount ${MK_ISO_WORKDIR}/squashfs/run
}

function make_iso {
	local default_url="https://releases.ubuntu.com/20.04.1/ubuntu-20.04.1-live-server-amd64.iso"

	[[ -d ${MK_ISO_WORKDIR}/{newfs,mount,squashfs} ]] \
		|| mkdir -p ${MK_ISO_WORKDIR}/{newfs,mount,squashfs}

	[[ -n ${MK_ISO_OUTPUT} ]] \
		|| MK_ISO_OUTPUT="/tmp/custom-image-$(date +%Y%m%d%H%M).iso"

	if [[ -z ${MK_ISO_ORIGINAL} ]]
	then
		echo ""
		echo "Downloading Ubuntu 20.04.1 ..."
		echo ""

		MK_ISO_ORIGINAL='/tmp/ubuntu-20.04-server.iso'

		wget -O ${MK_ISO_ORIGINAL} ${default_url}
	fi

	mount -o loop ${MK_ISO_ORIGINAL} ${MK_ISO_WORKDIR}/mount

	rsync	--exclude=/casper/filesystem.squashfs \
			--exclude=ubuntu -avvP \
			${MK_ISO_WORKDIR}/mount/ \
			${MK_ISO_WORKDIR}/newfs

	unsquashfs -f -d ${MK_ISO_WORKDIR}/squashfs/ ${MK_ISO_WORKDIR}/mount/casper/filesystem.squashfs

	[[ -n ${MK_ISO_SOURCE} ]] \
		&& copy_scripts

	install_packages ${MK_ISO_PACKAGE_SOURCE}

	mksquashfs ${MK_ISO_WORKDIR}/squashfs ${MK_ISO_WORKDIR}/newfs/casper/filesystem.squashfs -b 1048576

	genisoimage -D -r -V "Custom Image" \
						-cache-inodes -J -l \
						-b isolinux/isolinux.bin \
						-c isolinux/boot.cat \
						-no-emul-boot \
						-boot-load-size 4 \
						-boot-info-table \
						-input-charset utf-8 \
						-o "${MK_ISO_OUTPUT}" \
						"${MK_ISO_WORKDIR}/newfs"

	if [[ ${?} -eq 0 ]]
	then
		echo ""
		echo "Created customized ISO: ${MK_ISO_OUTPUT}"
		echo ""
	fi
}

function usage {
	sed -En '/^#---help---/,/^#---help---/p' "$0" | sed -E 's/^# ?//; 1d;$d;'
	exit ${1:-0}
}

function utils {
	for util in "${@}"
	do
		command -v ${util} >/dev/null 2>&1 || { echo >&2 "The utility ${util} is not installed."; exit 1; }
	done
}

function main {
	MK_ISO_WORKDIR='/tmp/mk_iso'
	MK_ISO_PACKAGE_SOURCE=''

	trap cleanup 1 2 3 8 9 14 15

	while getopts 'd:f:hi:o:p:s:' option
	do
		case ${option} in
			d ) MK_ISO_DESTINATION=${OPTARG} ;;
			f ) MK_ISO_PACKAGE_FILE=${OPTARG} ;;
			h ) usage ;;
			i ) MK_ISO_ORIGINAL=${OPTARG} ;;
			o ) MK_ISO_OUTPUT=${OPTARG} ;;
			p ) MK_ISO_PACKAGES=${OPTARG} ;;
			s ) MK_ISO_SOURCE=${OPTARG} ;;
			* ) usage 1
		esac
	done

	[[ -n ${MK_ISO_PACKAGES} ]] \
		&& MK_ISO_PACKAGE_SOURCE='list'

	if [[ -n ${MK_ISO_PACKAGE_FILE} ]]
	then
		MK_ISO_PACKAGES=''
		MK_ISO_PACKAGE_SOURCE='file'
	fi

	utils wget genisoimage unsquashfs mksquashfs

	make_iso

	cleanup
}

main "${@}"

#!/bin/bash
# Copyright 2011, Dell 
# 
# Licensed under the Apache License, Version 2.0 (the "License"); 
# you may not use this file except in compliance with the License. 
# You may obtain a copy of the License at 
# 
#  http://www.apache.org/licenses/LICENSE-2.0 
# 
# Unless required by applicable law or agreed to in writing, software 
# distributed under the License is distributed on an "AS IS" BASIS, 
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
# See the License for the specific language governing permissions and 
# limitations under the License. 
# 
# Author: VictorLowther
#

# This script expects to be able to run certian commands as root.
# Either run it as a user who can sudo to root, or give the user
# you are running it as the following sudo rights:
# crowbar-tester ALL = NOPASSWD: /bin/mount, /bin/umount, /usr/sbin/debootstrap, /bin/cp, /usr/sbin/chroot

# When running this script for the first time, it will automatically create a
# cache directory and try to populate it with all the build dependencies.
# After that, if you need to pull in new dependencies, you will need to
# call the script with the --update-cache parameter.  If you are going to 
# develop on Crowbar, it is a good idea to put the build cache in its own git
# repository, and create a branching structure for the packages that mirrors
# the branching structure in the crowbar repository -- if you do that, then
# this build script can be smarter about what packages it should pull in
# whenever you invoke it to build an iso.

[[ $DEBUG ]] && {
    set -x
    export PS4='${BASH_SOURCE}@${LINENO}(${FUNCNAME[0]}): '
}

export PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"

# Our general cleanup function.  It is called as a trap whenever the 
# build script exits, and it's job is to make sure we leave the local 
# system in the same state we cound it, modulo a few calories of wasted heat 
# and a shiny new .iso.
cleanup() {
    # Clean up any stray mounts we may have left behind. 
    # The paranoia with the grepping is to ensure that we do not 
    # inadvertently umount everything.
    GREPOPTS=()
    [[ $CACHE_DIR ]] && GREPOPTS=(-e "$CACHE_DIR")
    [[ $IMAGE_DIR && $CACHE_DIR =~ $IMAGE_DIR ]] && GREPOPTS=(-e "$IMAGE_DIR")
    [[ $BUILD_DIR && $CACHE_DIR =~ $BUILD_DIR ]] && GREPOPTS=(-e "$BUILD_DIR")
    if [[ $GREPOPTS ]]; then
	while read dev fs type opts rest; do
	    sudo umount -d -l "$fs"
	done < <(tac /proc/self/mounts |grep "${GREPOPTS[@]}")
    fi
    # If the build process spawned a copy of webrick, make sure it is dead.
    [[ $webrick_pid && -d /proc/$webrick_pid ]] && kill -9 $webrick_pid
    # clean up after outselves from merging branches, if needed.
    cd "$CROWBAR_DIR"
    if [[ $THROWAWAY_BRANCH ]]; then
	# Check out the branch we started the build process, and then 
	# nuke whatever throwaway branch we may have created.
	git checkout -f "${CURRENT_BRANCH##*/}" &>/dev/null
	git branch -D "$THROWAWAY_BRANCH" &>/dev/null
    fi
    # If we saved unadded changes, resurrect them.
    [[ $THROWAWAY_STASH ]] && git stash apply "$THROWAWAY_STASH" &>/dev/null
    # Do the same thing as above, but for the build cache instead.
    cd "$CACHE_DIR"
    if [[ $CACHE_THROWAWAY_BRANCH ]]; then
	git checkout -f "$CURRENT_CACHE_BRANCH" &>/dev/null
	git branch -D "$CACHE_THROWAWAY_BRANCH" &>/dev/null
    fi
    [[ $CACHE_THROWAWAY_STASH ]] && git stash apply "$CACHE_THROWAWAY_STASH"
    for d in "$IMAGE_DIR" "$BUILD_DIR"; do
	[[ -d $d ]] && rm -rf -- "$d"
    done
}

# Test to see if $1 is in the rest of the args.
is_in() {
    local t="$1"
    shift
    while [[ $1 && $t != $1 ]]; do shift; done
    [[ $1 ]]
}

# Arrange for cleanup to be called at the most common exit points.
trap cleanup 0 INT QUIT TERM

# Source our config file if we have one
[[ -f $HOME/.build-crowbar.conf ]] && \
    . "$HOME/.build-crowbar.conf"

# Look for a local one.
[[ -f build-crowbar.conf ]] && \
    . "build-crowbar.conf"

# Next, some configuration variables that can be used to tune how the 
# build process works.

# Barclamps to include.  By default, start with jsut crowbar and let
# the dependency machinery and the command line pull in the rest.
# Note that BARCLAMPS is an array, not a string!
[[ $BARCLAMPS ]] || BARCLAMPS=()

# Hashes to hold our "interesting" information.
# Key = barclamp name
# Value = whatever interesting thing we are looking for.
declare -A BC_DEPS BC_GROUPS BC_PKGS BC_EXTRA_FILES BC_OS_DEPS BC_GEMS
declare -A BC_REPOS BC_PPAS BC_RAW_PKGS BC_BUILD_PKGS BC_QUERY_STRINGS
    
# Query strings to pull info we are interested out of crowbar.yml
BC_QUERY_STRINGS["deps"]="barclamp requires"
BC_QUERY_STRINGS["groups"]="barclamp member"
BC_QUERY_STRINGS["pkgs"]="$PKG_TYPE pkgs"
BC_QUERY_STRINGS["extra_files"]="extra_files"
BC_QUERY_STRINGS["os_support"]="barclamp os_support"
BC_QUERY_STRINGS["gems"]="gems pkgs"
BC_QUERY_STRINGS["repos"]="$PKG_TYPE repos"
BC_QUERY_STRINGS["ppas"]="$PKG_TYPE ppas"
BC_QUERY_STRINGS["build_pkgs"]="$PKG_TYPE build_pkgs"

# Default sources for barclamps.  You can add to these or override them
# in one of your config files.  The format is:
# BC_SOURCES["barclamp_name"]="repository_location tag_or_branch"
# If tag_or_branch is missing, it is assumed to be master.
declare -A BC_SOURCES
# Core Crowbar barclamps.
BC_SOURCES["crowbar"]="http://github.com/dellcloudedge/barclamp-crowbar.git"
BC_SOURCES["deployer"]="http://github.com/dellcloudedge/barclamp-deployer.git"
BC_SOURCES["dns"]="http://github.com/dellcloudedge/barclamp-dns.git"
BC_SOURCES["ipmi"]="http://github.com/dellcloudedge/barclamp-ipmi.git"
BC_SOURCES["logging"]="http://github.com/dellcloudedge/barclamp-logging.git"
BC_SOURCES["nagios"]="http://github.com/dellcloudedge/barclamp-nagios.git"
BC_SOURCES["ganglia"]="http://github.com/dellcloudedge/barclamp-ganglia.git"
BC_SOURCES["network"]="http://github.com/dellcloudedge/barclamp-network.git"
BC_SOURCES["ntp"]="http://github.com/dellcloudedge/barclamp-ntp.git"
BC_SOURCES["provisioner"]="http://github.com/dellcloudedge/barclamp-provisioner.git"
BC_SOURCES["redhat-install"]="http://github.com/dellcloudedge/barclamp-redhat-install.git"
BC_SOURCES["test"]="http://github.com/dellcloudedge/barclamp-test.git"
BC_SOURCES["ubuntu-install"]="http://github.com/dellcloudedge/barclamp-ubuntu-install.git"
# Core Crowbar group membership
BC_GROUPS["crowbar"]="crowbar deployer dns ipmi logging nagios ganglia network ntp provisioner redhat-install test ubuntu-install"

# Core Openstack Barclamps
BC_SOURCES["keystone"]="http://github.com/dellcloudedge/barclamp-keystone.git"
BC_SOURCES["nova"]="http://github.com/dellcloudedge/barclamp-nova.git"
BC_SOURCES["mysql"]="http://github.com/dellcloudedge/barclamp-mysql.git"
BC_SOURCES["swift"]="http://github.com/dellcloudedge/barclamp-swift.git"
BC_SOURCES["kong"]="http://github.com/dellcloudedge/barclamp-kong.git"
BC_SOURCES["glance"]="http://github.com/dellcloudedge/barclamp-glance.git"
BC_SOURCES["nova_dashboard"]="http://github.com/dellcloudedge/barclamp-nova_dashboard.git"

# Core Openstack group membership
BC_GROUPS["openstack"]="keystone nova mysql swift kong glance nova_dashboard"

# Location for caches that should not be erased between runs
[[ $CACHE_DIR ]] || CACHE_DIR="$HOME/.crowbar-build-cache"

# Location to store .iso images that we use in the build process.
# These are usually OS install DVDs that we will stage Crowbar on to.
[[ $ISO_LIBRARY ]] || ISO_LIBRARY="$CACHE_DIR/iso"

# This is the location that we will save the generated .iso to.
[[ $ISO_DEST ]] || ISO_DEST="$PWD"

# Directory that holds our Sledgehammer PXE tree.
[[ $SLEDGEHAMMER_PXE_DIR ]] || SLEDGEHAMMER_PXE_DIR="$CACHE_DIR/tftpboot"

# Location of the Crowbar checkout we are building from.
[[ $CROWBAR_DIR ]] ||CROWBAR_DIR="${0%/*}"

# Location of the Sledgehammer source tree.  Only used if we cannot 
# find Sledgehammer in $SLEDGEHAMMER_PXE_DIR above. 
[[ $SLEDGEHAMMER_DIR ]] || SLEDGEHAMMER_DIR="${CROWBAR_DIR}/../sledgehammer"

# Command to run to clean out the tree before starting the build.
# By default we want to be relatively pristine.
[[ $VCS_CLEAN_CMD ]] || VCS_CLEAN_CMD='git clean -f -x -d'

# If there is a config directory in the crowbar checkout,
# source all the files in it.

if [[ -d $CROWBAR_DIR/config.d ]]; then
    for f in "$CROWBAR_DIR/config.d/"*".conf"; do
	[[ -f $f ]] || continue
	. "$f"
    done
fi

# Arrays holding the additional pkgs and gems populate Crowbar with.
PKGS=()
GEMS=()

# Some helper functions

# Print a message to stderr and exit.  cleanup will be called.
die() { echo "$(date '+%F %T %z'): $*" >&2; exit 1; }

# Print a message to stderr and keep going.
debug() { echo "$(date '+%F %T %z'): $*" >&2; }

# Clean up any cruft that we might have left behind from the last run.
clean_dirs() {
    local d=''
    for d in "$@"; do
	(   mkdir -p "$d"
	    cd "$d"
	    chmod -R u+w .
	    rm -rf * )
    done
}

# Verify that the passed name is really a branch in the git repo.
branch_exists() { git show-ref --quiet --verify --heads -- "refs/heads/$1"; }
tag_exists() { git show-ref --quiet --verify --tags -- "refs/tags/$1"; }
checkout_exists() { branch_exists "$1" || tag_exists "$1"; }

# Run a git command in the crowbar repo.
in_repo() ( cd "$CROWBAR_DIR"; "$@")
in_barclamp() ( cd "$CROWBAR_DIR/barclamps/$1"; shift; "$@")

# Run a git command in the build cache, assuming it is a git repository. 
in_cache() (
    [[ $CURRENT_CACHE_BRANCH ]] || return 
    cd "$CACHE_DIR"
    "$@"
)

checkout_barclamp() {
    [[ ${BC_SOURCES["$1"]} ]] || die "Don't know how to check out $1"
    [[ -d $CROWBAR_DIR/barclamps/$1 ]] && \
	die "Something has already created a directory named $1, cowardly refusing to continue."
    mkdir -p "$CROWBAR_DIR/barclamps/$1"
    in_barclamp "$1" git init . &>/dev/null || die "Could not initialize git repository for $1"
    local repo=${BC_SOURCES["$1"]%% *}
    local branch=${BC_SOURCES["$1"]#* }
    [[ $branch = $repo ]] && branch=master
    echo -n "Fetching barclamp $1... "
    in_barclamp "$1" git remote add origin "$repo" &>/dev/null
    in_barclamp "$1" git fetch origin &>/dev/null || {
	rm -rf "$CROWBAR_DIR/barclamps/$1"
	die "Could not fetch git repository for $1"
    }
    in_barclamp "$1" git checkout "$branch" &>/dev/null || {
	rm -rf "$CROWBAR_DIR/barclamps/$1"
	die "Could not checkout $branch in $1"
    }
    get_barclamp_metadata "$1"
    echo "Done."
}

is_barclamp() { 
    # If the crowbar.yml file exists, then it is a barclamp.
    [[ -f $CROWBAR_DIR/barclamps/$1/crowbar.yml ]] && return 0
    [[ -d $CROWBAR_DIR/barclamps/$1 ]] && \
	die "$CROWBAR_DIR/barclamps/$1 exists, but does not have crowbar.yml!"
    [[ ${BC_SOURCES["$1"]} ]] || \
	die "Do not know how to check out $1, please manually add it to $CROWBAR_DIR/barclamps"
    checkout_barclamp "$1" || die "Could not check out barclamp $1"
}

sync_barclamp() {
    is_barclamp "$1" || die "Cannot sync $1, it is not a barclamp!"
    local branch=''
    # if this barclamp is not a git repo, don't try to sync it.
    [[ -f $CROWBAR_DIR/barclamps/$1/.git/config ]] || return 0
    branch=$(in_barclamp "$1" git symbolic-ref -q HEAD)
    branch="${branch##*/}"
    [[ $branch ]] || die "$1 is not on a commit, cannot sync!"
    # if we are on a tag, don't bother trying to sync.
    in_barclamp "$1" tag_exists "$branch" && return 0
    in_barclamp "$1" branch_exists "$branch" || die "$branch in $1 is not a branch!"
    # If we do not have an origin, then just return
    in_barclamp "$1" git show-ref --quiet --verify --heads \
	"refs/remotes/origin/$branch" || return 0
    in_barclamp "$1" git fetch --tags origin
    if ! in_barclamp "$1" git merge "origin/$branch"; then
	in_barclamp "$1" git reset --hard
	echo "Could not merge $branch in $1 with upstream." >&2
	die "Changes were undone, please merge manually."
    fi
}

sync_barclamps() {
    for d in "$CROWBAR_DIR/barclamps/"*; do
	d="${d##*/}"
	is_barclamp "$d" || continue
	sync_barclamp "$d"
    done
}

get_barclamp_metadata() {
    is_barclamp "$1" || die "$1 is not a barclamp!"
    yml_file="$CROWBAR_DIR/barclamps/$1/crowbar.yml"
    for query in "${!BC_QUERY_STRINGS[@]}"; do
	while read line; do
	    [[ $line = nil ]] && continue
	    case $query in
		deps) [[ $line = $1 ]] && die "$1 cannot depend on itself!"
		    is_in "$line" ${BC_DEPS["$1"]} && continue
		    BC_DEPS["$1"]+=" $line";;
		groups) is_in "$line" ${BC_GROUPS["$1"]} && continue
		    [[ $line = @* ]] && \
			die "Cannot include a group in another group!"
		    BC_GROUPS["$line"]+=" $1";;
		pkgs) BC_PKGS["$1"]+=" $line";;
		extra_files) BC_EXTRA_FILES["$1"]+="\n$line";;
		os_support) BC_OS_SUPPORT["$1"]+=" $line";;
		gems) BC_GEMS["$1"]+=" $line";;
		repos) BC_REPOS["$1"]+="\n$line";;
		ppas) [[ $PKG_TYPE = debs ]] || \
		    die "Cannot declare a PPA for $PKG_TYPE!"
		    BC_REPOS["$1"]+="\nppa $line";;
		build_pkgs) BC_BUILD_PKGS["$1"]+="\$line";;
		*) die "Cannot handle query for $query."
	    esac
	done < <("$CROWBAR_DIR/parse_yml.rb" \
	    "$yml_file" \
	    ${BC_QUERY_STRINGS["$query"]} 2>/dev/null)
    done
    # Add the dependency on the crowbar barclamp if it does not exist.
    [[ $1 = crowbar ]] || is_in crowbar ${BC_DEPS["$1"]} || \
	BC_DEPS[$1]+=" crowbar"
}

maybe_expand_group() {
    local bc
    for bc in "$@"; do
	if [[ $bc != @* ]]; then
	    is_barclamp "$bc" || return 1
	    printf " %s" "$bc"
	    continue
	fi
	bc=${bc#@}
	[[ ${BC_GROUPS["$bc"]} ]] || return 1
	maybe_expand_group ${BC_GROUPS["$bc"]} || return 1
    done
}

# Get the OS we were asked to stage Crowbar on to.  Assume it is Ubuntu 10.10
# unless we specify otherwise.
OS_TO_STAGE="${1-ubuntu-10.10}"
shift

# Make sure that we actually know how to build the ISO we were asked to 
# build.  If we do not, print a helpful error message.
if ! [[ $OS_TO_STAGE && -d $CROWBAR_DIR/$OS_TO_STAGE-extra && \
    -f $CROWBAR_DIR/$OS_TO_STAGE-extra/build_lib.sh ]]; then
    cat <<EOF
You must pass the name of the operating system you want to stage Crowbar
on to.  Valid choices are:
EOF
    cd "$CROWBAR_DIR"
    for d in *-extra; do
	[[ -d $d && -f $d/build_lib.sh ]] || continue
	echo "    ${d%-extra}"
    done
    exit 1
fi

# Source OS specific build knowledge.  This includes:
# Parameters that build_crowbar.sh needs to know:
# OS = the distribution we are staging on to, such as redhat or ubuntu.
# OS_VERSION = the version of the distribution we are staging on to.
#              For redhat, it would be somethibng like 5.6
# OS_TOKEN = Defaults to "$OS-$OS_VERSION"
# ISO = the name of the install ISO image we are going to stage Crowbar on to.
#
# Functions that build_crowbar needs to call:
# maybe_update_cache(): This function should check and see if the OS and Gem
#   caches in $CACHE_DIR need updating.  If they do, it shoould update them
#   in a way that is reasonably portable across Linuxes and that leaves the
#   build host alone -- the state of the hosts packaging system should not 
#   be touched at all. It does not take any arguments.
# copy_pkgs(): This function should appropriatly stage any extra packages
#   that Crowbar will need to install and run. We recommend that this function
#   take care to only copy the latest version of a package if there are any
#   duplicates.  It takes 3 arguments -- the location of the package pool on 
#   the OS install media, the package cache to copy packages from, and the
#   location to copy extra packages to (which should NOT be the same as the 
#   package pool on the OS media).
# final_build_fixups(): This function should take wahtever steps are needed
#   to make the default OS install process also ensure that the Crowbar bits 
#   are properly staged and to completly automate the admin node install 
#   process, either as an install from CD or an install via PXE.  This 
#   usually entails modifying initrd files, adding kickstarts/install seeds,
#   modifying boot config files, and so on.
. "$CROWBAR_DIR/$OS_TO_STAGE-extra/build_lib.sh"

{
    # Make sure only one instance of the ISO build runs at a time.
    # Otherwise you can easily end up with a corrupted image.
    flock 65
    # Figure out what our current branch is, in case we need to merge 
    # other branches in to the iso to create our build.  
    CURRENT_BRANCH="$(in_repo git symbolic-ref HEAD)" || \
	die "Not on a branch we can build from!"
    CURRENT_BRANCH=${CURRENT_BRANCH##*/}
    [[ $CURRENT_BRANCH ]] || die "Not on a branch we can merge from!"
    
    # Check and see if our local build repository is a git repo. If it is,
    # we may need to do the same sort of merging in it that we might do in the 
    # Crowbar repository.
    if [[ -d $CACHE_DIR/.git ]]; then
	for br in "$CURRENT_BRANCH" master ''; do
	    [[ $br ]] || die "Cannot find $CURRENT_BRANCH or master in $CACHE_DIR"
	    (cd "$CACHE_DIR"; branch_exists "$br") || continue
	    CURRENT_CACHE_BRANCH="$br"
	    break
	done
	# If there are packages that have not been comitted, save them
	# in a stash before continuing.  We do this on the assumption that
	# these packages were added manually for testing purposes, or were
	# added in an earlier update-cache operation, but that the user has
	# not gotten around to comitting yet.
	if [[ ! $(in_cache git status) =~ working\ directory\ clean ]]; then
	    CACHE_THROWAWAY_STASH=$(in_cache git stash create)
	    in_cache git checkout -f .
	fi
    fi

    # Parse our options.  
    while [[ $1 ]]; do
	case $1 in
	    # Merge a list of branches into a throwaway branch with the 
	    # current branch as a baseline before starting the rest of the 
	    # build process.  This makes it easier to spin up iso images 
	    # with local changes without having to manually merge those 
	    # changes in with any other branches of interest first.  
	    # This code takes heavy advantage of the lightweight nature of 
	    # git branches and takes care to leave uncomitted changes in place.
	    -m|--merge)
		shift
		# Loop through the rest of the arguments, as long as they
		# do not start with a -.
		while [[ $1 && ! ( $1 = -* ) ]]; do
		    # Check to make sure that this argument refers to a branch
		    # in the crowbar git tree.  Die if it does not.
		    in_repo branch_exists "$1" || die "$1 is not a git branch!"
		    # If we have not already created a throwaway branch to
		    # merge these branches into, do so now. If we have 
		    # uncomitted changes that need to be stashed, do so here.
		    if [[ ! $THROWAWAY_BRANCH ]]; then
			THROWAWAY_BRANCH="build-throwaway-$$-$RANDOM"
			REPO_PWD="$PWD"
			if [[ ! $(in_repo git status) =~ working\ directory\ clean ]]; then
			    THROWAWAY_STASH=$(in_repo git stash create)
			    in_repo git checkout -f .
			fi
			in_repo git checkout -b "$THROWAWAY_BRANCH"
		    fi
		    # Merge the requested branch into the throwaway branch.
		    # Die if the merge failed -- there must have been a
		    # conflict, and the user needs to fix it up.
		    in_repo git merge "$1" || \
			die "Merge of $1 failed, fix things up and continue"
		    # If there is n identically named branch in the build cache,
		    # merge it into a throwaway branch of the build cache
		    # along with the current branch in the build cache.
		    # This makes it easier to include and manage packages that
		    # are branch-specific, but that do not need to be included
		    # in every build.
		    if in_cache branch_exists "$1"; then
			if [[ ! $CACHE_THROWAWAY_BRANCH ]]; then
			    CACHE_THROWAWAY_BRANCH=${THROWAWAY_BRANCH/build/cache}
			    in_cache git checkout -b "$CACHE_THROWAWAY_BRANCH"
			fi
			in_cache git merge "$1" || \
			    die "Could not merge build cache branch $1"
		    fi
		    shift
		done
		;;
	    # Force an update of the cache
	    update-cache|--update-cache) shift; need_update=true;;
	    # Pull in additional barclamps.
	    --barclamps)
		shift
		while [[ $1 && $1 != -* ]]; do
		    BARCLAMPS+=("$1")
		    shift
		done;;
	    --sync-barclamps) BC_SYNC=true; shift;;
	    *) 	die "Unknown command line parameter $1";;
	esac
    done

    # If we stached changes to the crowbar repo, apply them now.
    [[ $THROWAWAY_STASH ]] && in_repo git stash apply "$THROWAWAY_STASH"
    # Ditto for the build cache.
    [[ $CACHE_THROWAWAY_STASH ]] && \
	in_cache git stash apply "$CACHE_THROWAWAY_STASH" 

    # Finalize where we expect to find our caches and out chroot.
    # If they were set in one of the conf files, don't touch them.

    # The directory we perform a minimal install into if we need
    # to refresh our gem or pkg caches
    [[ $CHROOT ]] || CHROOT="$CACHE_DIR/$OS_TOKEN/chroot"

    # Make sure that the $OS_TOKEN directory exist.
    mkdir -p "$CACHE_DIR/$OS_TOKEN"
    
    # The directory we will stage the build into.
    [[ $BUILD_DIR ]] || \
	BUILD_DIR="$(mktemp -d "$CACHE_DIR/$OS_TOKEN/build-XXXXX")"
    # The directory that we will mount the OS .ISO on .
    [[ $IMAGE_DIR ]] || \
	IMAGE_DIR="$CACHE_DIR/$OS_TOKEN/image-${BUILD_DIR##*-}"

    # Directories where we cache our pkgs, gems, and extra files
    [[ $PKG_CACHE ]] || PKG_CACHE="$CACHE_DIR/$OS_TOKEN/pkgs"
    [[ $GEM_CACHE ]] || GEM_CACHE="$CACHE_DIR/gems"
    [[ $FILE_CACHE ]] || FILE_CACHE="$CACHE_DIR/files"

    # Directory where we will look for our package lists
    [[ $PACKAGE_LISTS ]] || PACKAGE_LISTS="$BUILD_DIR/extra/packages"
    
    # Pull in interesting information from all our barclamps
    for bc in $CROWBAR_DIR/barclamps/*; do
	[[ -d $bc ]] || continue
	get_barclamp_metadata "${bc##*/}"
    done

    # Proxy Variables
    [[ $USE_PROXY ]] || USE_PROXY=0
    [[ $PROXY_HOST ]] || PROXY_HOST=""
    [[ $PROXY_PORT ]] || PROXY_PORT=""
    [[ $PROXY_USER ]] || PROXY_USER=""
    [[ $PROXY_ESC_USER ]] || PROXY_ESC_USER=""
    [[ $PROXY_PASSWORD ]] || PROXY_PASSWORD=""

    # Version for ISO
    [[ $VERSION ]] || VERSION="$(cd "$CROWBAR_DIR"; git describe --long --tags)-dev"

    # Name of the built iso we will build
    [[ $BUILT_ISO ]] || BUILT_ISO="crowbar-${VERSION}.iso"

    # If we were not passed a list of barclamps to include,
    # pull in all of the ones that claim to be in the crowbar group.
    [[ $BARCLAMPS ]] || BARCLAMPS=("@crowbar")

    # Sync our barclamps if we were asked to.
    [[ $BC_SYNC = true ]] && sync_barclamps

    # Group-expand and pull in barclamp dependencies, and unset groups after they are expanded.
    
    while [[ a = a ]]; do
	for bc in "${BARCLAMPS[@]}"; do
	    if [[ $bc = @* ]]; then
		[[ ${BC_GROUPS["${bc#@}"]} ]] || \
		    die "No such group ${bc#@}!"
		for dep in ${BC_GROUPS["${bc#@}"]}; do
		    is_in "$dep" "${new_barclamps[@]}" || \
			new_barclamps+=("$dep")
		done
	    else
		is_barclamp "$bc" || die "$bc is not a barclamp!"
		for dep in ${BC_DEPS["$bc"]}; do
		    if [[ $dep = @* ]]; then
			[[ ${BC_GROUPS["${dep#@}"]} ]] || \
			    die "No such group ${dep#@}!"
			for d in ${BC_GROUPS["${bc#@}"]}; do
			    is_in "$d" "${new_barclamps[@]}" || \
				new_barclamps+=("$d")
			done
		    else
			is_in "$dep" "${new_barclamps[@]}" || \
			    new_barclamps+=("$dep")
		    fi
		done
		is_in "$bc" "${new_barclamps[@]}" || new_barclamps+=("$bc")
	    fi
	done
	[[ ${new_barclamps[*]} = ${BARCLAMPS[*]} ]] && break
	BARCLAMPS=("${new_barclamps[@]}")
    done

    # Make any directories we don't already have
    for d in "$PKG_CACHE" "$GEM_CACHE" "$ISO_LIBRARY" "$ISO_DEST" \
	"$IMAGE_DIR" "$BUILD_DIR" "$FILE_CACHE" \
	"$SLEDGEHAMMER_PXE_DIR" "$CHROOT"; do
	mkdir -p "$d"
    done
    
    # Make sure Sledgehammer has already been built and pre-staged.
    if ! [[ -f $SLEDGEHAMMER_DIR/bin/sledgehammer-tftpboot.tar.gz || \
	-f $SLEDGEHAMMER_PXE_DIR/initrd0.img ]]; then
	echo "Slegehammer TFTP image missing!"
	echo "Please build Sledgehammer from $SLEDGEHAMMER_DIR before building Crowbar."
	exit 1
    fi  
  
    # Fetch the OS ISO if we need to.
    [[ -f $ISO_LIBRARY/$ISO ]] || fetch_os_iso

    # Start with a clean slate.
    clean_dirs "$IMAGE_DIR" "$BUILD_DIR"

    # Clean up any cruft that the editor may have left behind.
    (cd "$CROWBAR_DIR"; $VCS_CLEAN_CMD)

    # Make additional directories we will need.
    for d in discovery extra; do
	mkdir -p "$BUILD_DIR/$d"
    done
    
    # Copy over the Crowbar bits and their prerequisites
    debug "Staging extra Crowbar bits"
    cp -r "$CROWBAR_DIR/extra"/* "$BUILD_DIR/extra"
    cp -r "$CROWBAR_DIR/$OS_TOKEN-extra"/* "$BUILD_DIR/extra"
    cp -r "$CROWBAR_DIR/change-image"/* "$BUILD_DIR"
    mkdir -p "$BUILD_DIR/dell/barclamps"
    for bc in "${BARCLAMPS[@]}"; do
	is_barclamp "$bc" || die "Cannot find barclamp $bc!"
	cp -r "$CROWBAR_DIR/barclamps/$bc" "$BUILD_DIR/dell/barclamps"
    done

    echo "$OS_TOKEN" >"$BUILD_DIR/extra/os_tag"

    # Mount our ISO for the build process.
    debug "Mounting $ISO"
    sudo mount -t iso9660 -o loop "$ISO_LIBRARY/$ISO" "$IMAGE_DIR" || \
	die "Could not mount $ISO"


    # If we need to or were asked to update our cache, do it.
    maybe_update_cache 
    
    # Copy our extra pkgs, gems, and files into the appropriate staging
    # directory.
    debug "Copying pkgs, gems, and extra files"
    copy_pkgs "$IMAGE_DIR" "$PKG_CACHE" "$BUILD_DIR/extra/pkgs"
    cp -r "$GEM_CACHE" "$BUILD_DIR/extra"
    cp -r "$FILE_CACHE" "$BUILD_DIR/extra"
    # Make sure we still provide the legacy ami location
    (cd "$BUILD_DIR"; ln -sf extra/files/ami)
    # Store off the version
    echo "$VERSION" >> "$BUILD_DIR/dell/Version"

    # Custom start-up in place
    if [ -f "$CROWBAR_DIR/crowbar.json" ] ; then
      mkdir -p "$BUILD_DIR/extra/config"
      cp "$CROWBAR_DIR/crowbar.json" "$BUILD_DIR/extra/config"
    fi
   
    final_build_fixups
 
    # Copy over the bits that Sledgehammer will look for.
    debug "Copying over Sledgehammer bits"
    # If we need to copy over a new Sledgehammer image, do so.
    if [[ $SLEDGEHAMMER_DIR/bin/sledgehammer-tftpboot.tar.gz -nt \
	$SLEDGEHAMMER_PXE_DIR/initrd0.img ]]; then
	(   cd $SLEDGEHAMMER_PXE_DIR
	    debug "Extracting new Sledgehammer TFTP boot image"
	    rm -rf .
	    cd ..
	    tar xzf "$SLEDGEHAMMER_DIR/bin/sledgehammer-tftpboot.tar.gz"
	    rm -f "$SLEDGEHAMMER_DIR/bin/sledgehammer-tftpboot.tar.gz"
	)
    fi
    cp -a "$SLEDGEHAMMER_PXE_DIR"/* "$BUILD_DIR/discovery"

    # Make our image
    debug "Creating new ISO"
    # Find files and directories that mkisofs will complain about.
    # Do just top-level overlapping directories for now.
    for d in $(cat <(cd "$BUILD_DIR"; find -maxdepth 1 -type d ) \
	           <(cd "$IMAGE_DIR"; find -maxdepth 1 -type d) | \
	           sort |uniq -d); do
	[[ $d = . ]] && continue
	d=${d#./}
	# Copy contents of the found directories into $BUILD_DIR, taking care
	# to not clobber existing files.
	mkdir -p "$BUILD_DIR/$d"
	chmod u+wr "$BUILD_DIR/$d"
	# We could also use cp -n, but rhel5 and centos5 do not understand it.
	rsync -rl --ignore-existing --inplace "$IMAGE_DIR/$d/." "$BUILD_DIR/$d/."
	chmod -R u+wr "$BUILD_DIR/$d"
	# Bind mount an empty directory on the $IMAGE_DIR instance.
	sudo mount -t tmpfs -o size=1K tmpfs "$IMAGE_DIR/$d"
    done
    (   cd "$BUILD_DIR"
	rm -f isolinux/boot.cat
	find -name '.svn' -type d -exec rm -rf '{}' ';' 2>/dev/null >/dev/null
	mkdir -p $ISO_DEST
	mkisofs -r -V "${VERSION:0:30}" -cache-inodes -J -l -quiet \
	    -b isolinux/isolinux.bin -c isolinux/boot.cat \
	    -no-emul-boot --boot-load-size 4 -boot-info-table \
	    -o "$ISO_DEST/$BUILT_ISO" "$IMAGE_DIR" "$BUILD_DIR" ) || \
	    die "There was a problem building our ISO."
 
    echo "$(date '+%F %T %z'): Finshed. Image at $ISO_DEST/$BUILT_ISO"
} 65> /tmp/.build_crowbar.lock

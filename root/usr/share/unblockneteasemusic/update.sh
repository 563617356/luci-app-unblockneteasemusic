#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2019-2023 Tianling Shen <cnsztl@immortalwrt.org>

NAME="unblockneteasemusic"
UNM_DIR="/usr/share/$NAME"
RUN_DIR="/var/run/$NAME"
mkdir -p "$RUN_DIR"

LOCK="$RUN_DIR/update_core.lock"
LOG="$RUN_DIR/run.log"

clean_log(){
	echo "" > "$LOG"
}

# --- China-friendly mirrors ---------------------------------------------
# The official endpoints (api.github.com, fastly.jsdelivr.net) are throttled
# or blocked on mainland China networks, which silently breaks auto-update
# and leaves the core stuck on an old, broken build. We try the official
# host first, then fall back to accessible mirrors.
GITHUB_API_MIRRORS="
https://api.github.com
https://ghproxy.net/https://api.github.com
https://ghproxy.com/https://api.github.com
"
JSDELIVR_MIRRORS="
https://fastly.jsdelivr.net/gh
https://cdn.jsdelivr.net/gh
https://gcore.jsdelivr.net/gh
https://testingcf.jsdelivr.net/gh
https://jsdelivr.panhua.top/gh
"

github_api_get() {
	# $1 = API path (e.g. /repos/owner/repo/commits?...)
	local path="$1" base out
	for base in $GITHUB_API_MIRRORS; do
		out="$(wget -T10 -qO- "${base}${path}")"
		if [ -n "$out" ]; then
			echo "$out"
			return 0
		fi
	done
	return 1
}

jsdelivr_download() {
	# $1 = relative path (owner/repo@ref/file); $2 = output file
	local rel="$1" out="$2" base
	for base in $JSDELIVR_MIRRORS; do
		if wget -T15 "${base}/${rel}" -qO "$out"; then
			if [ -s "$out" ]; then
				return 0
			fi
		fi
	done
	return 1
}

check_core_latest_version() {
	exec 200>"$LOCK"
	if ! flock -n 200 &> /dev/null; then
		echo -e "\nA task is already running." >> "$LOG"
		exit 2
	fi

	core_latest_ver="$(github_api_get '/repos/UnblockNeteaseMusic/server/commits?sha=enhanced&path=precompiled' | jsonfilter -e '@[0].sha')"
	[ -n "$core_latest_ver" ] || { echo -e "\nFailed to check latest core version, please try again later." >> "$LOG"; exit 1; }
	if [ ! -e "$UNM_DIR/core_local_ver" ]; then
		clean_log
		echo -e "Local version: NOT FOUND, latest version: $core_latest_ver." >> "$LOG"
		update_core
	else
		if [ "$(cat $UNM_DIR/core_local_ver)" != "$core_latest_ver" ]; then
			clean_log
			echo -e "Local version: $(cat $UNM_DIR/core_local_ver 2>"/dev/null"), latest version: $core_latest_ver." >> "$LOG"
			update_core
		else
			echo -e "\nLocal version: $(cat $UNM_DIR/core_local_ver 2>"/dev/null"), latest version: $core_latest_ver." >> "$LOG"
			echo -e "You're already using the latest version." >> "$LOG"
			exit 3
		fi
	fi
}

update_core() {
	echo -e "Updating core..." >> "$LOG"

	mkdir -p "$UNM_DIR/core"
	rm -rf "$UNM_DIR/core"/*

	for file in $(github_api_get '/repos/UnblockNeteaseMusic/server/contents/precompiled' | jsonfilter -e '@[*].path')
	do
		if ! jsdelivr_download "UnblockNeteaseMusic/server@$core_latest_ver/$file" "$UNM_DIR/core/${file##*/}"; then
			echo -e "Failed to download ${file##*/}." >> "$LOG"
			exit 1
		fi
	done

	for cert in "ca.crt" "server.crt" "server.key"
	do
		if ! jsdelivr_download "UnblockNeteaseMusic/server@$core_latest_ver/$cert" "$UNM_DIR/core/$cert"; then
			echo -e "Failed to download ${cert}." >> "$LOG"
			exit 1
		fi
	done

	echo -e "$core_latest_ver" > "$UNM_DIR/core_local_ver"
	[ -n "$non_restart" ] || /etc/init.d/"$NAME" restart

	echo -e "Succeeded in updating core." > "$LOG"
	echo -e "Current core version: $core_latest_ver.\n" >> "$LOG"
}

case "$1" in
	"check_version")
		if [ ! -e "$UNM_DIR/core_local_ver" ] || [ ! -e "$UNM_DIR/core/app.js" ]; then
			echo -e "Not installed."
			exit 2
		else
			version="$(node "$UNM_DIR/core/app.js" -v)"
			commit="$(cat "$UNM_DIR/core_local_ver" | head -c7)"
			echo "$version ($commit)"
			exit 0
		fi
		;;
	"update_core")
		check_core_latest_version
		;;
	"update_core_non_restart")
		non_restart=1
		check_core_latest_version
		;;
	"remove_core")
		"/etc/init.d/$NAME" stop
		rm -rf "$UNM_DIR/core" "$UNM_DIR/core_local_ver" "$LOCK"
		;;
	*)
		echo -e "Usage: $0 check_version | update_core | remove_core"
		;;
esac

#!/usr/bin/env bash

set -u

SRVPORT=${SRVPORT:-4499}

get_api() {
	local request_line
	IFS= read -r request_line || return 1
	local header
	while IFS= read -r header; do
		header=${header%$'\r'}
		[[ -n "$header" ]] || break
	done
}

handleRequest() {
	get_api || return 1
	local fortune_text cow_text html_text
	fortune_text=$(fortune) || return 1
	cow_text=$(cowsay "$fortune_text") || return 1
	html_text=$(printf '%s\n' "$cow_text" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

	printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n<pre>%s</pre>\n' "$html_text"
}

prerequisites() {
	command -v cowsay >/dev/null 2>&1 &&
	command -v fortune >/dev/null 2>&1 || 
		{ 
			echo "Install prerequisites."
			exit 1
		}
}

main() {
	prerequisites
	if ! [[ "$SRVPORT" =~ ^[0-9]+$ ]]; then
		echo "SRVPORT must be a port number between 1 and 65535." >&2
		exit 1
	fi
	SRVPORT=$((10#$SRVPORT))
	if (( SRVPORT < 1 || SRVPORT > 65535 )); then
		echo "SRVPORT must be a port number between 1 and 65535." >&2
		exit 1
	fi
	echo "Wisdom served on port=$SRVPORT..."

	local script_path handler_command
	script_path=$(readlink -f -- "${BASH_SOURCE[0]}") || {
		echo "Could not resolve the server script path." >&2
		exit 1
	}
	printf -v handler_command 'WISECOW_HANDLE_REQUEST=1 exec /bin/bash %q --handle-request' "$script_path"
	exec socat "TCP-LISTEN:${SRVPORT},reuseaddr,fork" "SYSTEM:${handler_command}"
}

if [[ "${1:-}" == "--handle-request" ]]; then
	handleRequest
	exit $?
fi

main

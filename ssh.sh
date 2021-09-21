#!/bin/bash
set -e

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
BASE_DIR="$SCRIPT_DIR"
SERVER_DIR="$BASE_DIR/auth"

set_server() {
  [ -f "$SERVER_DIR/$1.sh" ] || return 1
  . "$SERVER_DIR/$1.sh"
}

case "$1" in
set)
  shift
  if set_server "$1"; then
    basename "$(realpath "$SERVER_DIR/$1.sh")" .sh > "$SERVER_DIR/current"
  fi
  ;&
i)
  cat "$SERVER_DIR/current"
  exit
esac

ENV_AUTH="$AUTH"
ENV_PORT="$PORT"

set_server "$(cat "$SERVER_DIR/current" 2>/dev/null)"

[ -n "$ENV_AUTH" ] && AUTH="$ENV_AUTH"
[ -n "$ENV_PORT" ] && PORT="$ENV_PORT"

[ -z "$PORT" ] && PORT=22
[ -z "$SSH" ] && SSH=ssh
[ -z "$SCP" ] && SCP=scp

if [ -n "$SSHPASS" ]; then
  SSH='sshpass -e ssh'
  SCP='sshpass -e scp'
  export SSHPASS
fi

[ -z "$SSH_LOGIN" ] && SSH_LOGIN="$SSH -t"

case "$1" in
push)
  shift
	tar zcf - "$@" | $SSH -p $PORT $AUTH -- tar zxf -
  ;;
pull)
  shift
  # Note that tokens in $@ will be split anyway, because ssh passes arguments as
  # a single string to the remote shell.
  $SSH -p $PORT $AUTH -- tar zcf - $@ | tar zxf -
  ;;
put)
  shift
  $SCP -r -P $PORT "$@" $AUTH:
  ;;
get)
  shift
  $SCP -r -P $PORT "${@/#/$AUTH:}" .
  ;;
init)
  cd "$BASE_DIR/config"
	tar zcf - .??* | $SSH -p $PORT $AUTH -- tar zxf -
  ;;
a|'')
  $SSH_LOGIN -p $PORT $AUTH -- tmux -u $1
  ;;
*)
  $SSH -p $PORT $AUTH "$@"
  ;;
esac

#!/bin/bash
set -e

SCRIPT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
BASE_DIR=$SCRIPT_DIR
SERVER_DIR=$BASE_DIR/auth

set_server() {
  [ -f "$SERVER_DIR/$1.sh" ] || return 1
  . "$SERVER_DIR/$1.sh"
}

show_current() {
  cat "$SERVER_DIR/current" 2>/dev/null
}

handle_meta_commands() {
  case $1 in
  ls)
    find "$SERVER_DIR" -name '*.sh' ! -type l |
      xargs -d'\n' basename -s .sh |
      awk '{ print "'"$(show_current)"'" == $0 ? "*" : " ", $0 }'
    ;;
  set)
    shift
    if set_server "$1"; then
      basename "$(realpath "$SERVER_DIR/$1.sh")" .sh > "$SERVER_DIR/current"
    fi
    ;&
  i)
    show_current
    ;;
  *)
    return 1
  esac
}

handle_meta_commands "$@" && exit

ENV_AUTH=$AUTH
ENV_PORT=$PORT

set_server "$(show_current)"

[ -n "$ENV_AUTH" ] && AUTH=$ENV_AUTH
[ -n "$ENV_PORT" ] && PORT=$ENV_PORT

[ -z "$PORT" ] && PORT=22
[ -z "$SSH" ] && SSH=ssh
[ -z "$SCP" ] && SCP=scp

if [ -n "$SSHPASS" ]; then
  SSH='sshpass -e ssh'
  SCP='sshpass -e scp'
  export SSHPASS
fi

[ -z "$SSH_LOGIN" ] && SSH_LOGIN="$SSH -t"

[ -x "$(command -v pv)" ] && PV=pv || PV=cat

case ${1-} in a|'')
  $SSH_LOGIN -p $PORT $AUTH -- tmux -u "$@"
  exit
esac

COMM=$1
shift

case $COMM in
push)
	tar zc "$@" | $PV | $SSH -p $PORT $AUTH -- tar zx --no-same-owner
  ;;
pull)
  # Note that tokens in $@ will be split anyway, because ssh passes arguments as
  # a single string to the remote shell.
  $SSH -p $PORT $AUTH -- tar zc $@ | $PV | tar zx
  ;;
put)
  $SCP -r -P $PORT "$@" $AUTH:
  ;;
get)
  $SCP -r -P $PORT "${@/#/$AUTH:}" .
  ;;
init)
  < "$BASE_DIR/config/pack.tar.xz" $PV | $SSH -p $PORT $AUTH -- tar Jx --no-same-owner
  ;;
e)
  $SSH -p $PORT $AUTH "$@"
  ;;
*)
  echo "unrecognized command \`$COMM\`"
  exit 1
esac

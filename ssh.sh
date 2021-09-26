#!/bin/bash
set -e

SCRIPT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
BASE_DIR=$SCRIPT_DIR
SERVER_DIR=$BASE_DIR/auth

cond() {
  if eval "$1" >/dev/null 2>&1; then
    echo "$2"
  else
    echo "$3"
  fi
}

set_server() {
  [ -f "$SERVER_DIR/$1.sh" ] || return 1
  . "$SERVER_DIR/$1.sh"
}

show_current() {
  cat "$SERVER_DIR/current" 2>/dev/null
}

process_meta() {
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

init_env() {
  ENV_AUTH=$AUTH
  ENV_PORT=$PORT

  if ! set_server "$(show_current)"; then
    echo 'cannot find config of current server'
    exit 1
  fi

  [ -n "$ENV_AUTH" ] && AUTH=$ENV_AUTH
  [ -n "$ENV_PORT" ] && PORT=$ENV_PORT

  if [ -z "$AUTH" ]; then
    echo 'hostname not supplied'
    exit 1
  fi

  [ -z "$PORT" ] && PORT=22
  [ -z "$SSH" ] && SSH=ssh
  [ -z "$SCP" ] && SCP=scp

  if [ -n "$SSHPASS" ]; then
    SSH='sshpass -e ssh'
    SCP='sshpass -e scp'
    export SSHPASS
  fi

  [ -z "$SSH_LOGIN" ] && SSH_LOGIN="$SSH -t"

  PV=$(cond 'command -v pv' pv cat)
}

main() {
  if [ $# -eq 0 ] || [ "$1" = a ]; then
    $SSH_LOGIN -p $PORT $AUTH -- tmux -u "$@"
    exit
  fi

  local comm=$1
  shift
  local uses_scp=false opt=true arg
  for arg; do
    shift
    if $opt; then
      case $arg in
        --)
          opt=false
          ;;
        --scp)
          uses_scp=true
          continue
          ;;
        */?*)
          uses_scp=true
          ;;
        *)
          [ -L "$arg" ] && uses_scp=true
          ;;
      esac
    fi
    set -- "$@" "$arg"
  done

  case $comm in
    put)
      if $uses_scp; then
        $SCP -r -p "$@" scp://$AUTH:$PORT/
      else
        tar zc "$@" | $PV | $SSH -p $PORT $AUTH -- tar zx --no-same-owner
      fi
      ;;
    get)
      if $uses_scp; then
        eval "set -- $(printf "scp://$AUTH:$PORT/%q\0" "$@" | xargs -0 printf '%q ')"
        $SCP -r -p "$@" .
      else
        $SSH -p $PORT $AUTH -- "$(printf '%q ' tar zc "$@")" | $PV | tar zx
      fi
      ;;
    init)
      < "$BASE_DIR/config/pack.tar.xz" $PV | $SSH -p $PORT $AUTH -- tar Jx --no-same-owner
      ;;
    e)
      $SSH -p $PORT $AUTH "$@"
      ;;
    *)
      echo "unrecognized command \`$comm\`"
      exit 1
  esac
}

process_meta "$@" && exit
init_env
main "$@"

#!/bin/bash
set -e

script_dir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
base_dir=$script_dir
server_dir=$base_dir/auth

set_server() {
  [ -f "$server_dir/$1.sh" ] || return 1
  . "$server_dir/$1.sh"
}

show_current() {
  cat "$server_dir/current" 2>/dev/null
}

process_meta() {
  case $1 in
    ls)
      find "$server_dir" -name '*.sh' ! -type l |
        xargs -d'\n' basename -s .sh |
        awk '{ print "'"$(show_current)"'" == $0 ? "*" : " ", $0 }'
      ;;
    set)
      shift
      if set_server "$1"; then
        basename "$(realpath "$server_dir/$1.sh")" .sh > "$server_dir/current"
      fi
      ;&
    i)
      show_current
      ;;
    *)
      return 1
  esac
}

or() {
  local s
  for s; do
    if [ -n "$s" ]; then
      echo "$s"
      return 0
    fi
  done
  return 1
}

init_env() {
  auth=$AUTH
  port=$PORT

  if ! set_server "$(show_current)"; then
    echo 'cannot find config of current server'
    exit 1
  fi

  auth=$(or "$auth" "$AUTH")
  port=$(or "$port" "$PORT" 22)
  ssh=$(or "$SSH" ssh)
  scp=$(or "$SCP" scp)
  ssh_login=$(or "$SSH_LOGIN" "$ssh -t")

  if [ -n "$SSHPASS" ]; then
    ssh='sshpass -e ssh'
    scp='sshpass -e scp'
    export SSHPASS
  fi

  if [ -z "$auth" ]; then
    echo 'hostname not supplied'
    exit 1
  fi

  pv=pv
  command -v $pv >/dev/null 2>&1 || pv=cat
}

main() {
  if [ $# -eq 0 ] || [ "$1" = a ]; then
    $ssh_login -p $port $auth -- tmux -u "$@"
    exit
  fi

  local comm=$1
  shift
  local uses_scp prefers_scp=false parsing=true arg
  for arg; do
    shift
    if $parsing; then
      case $arg in
        --)
          parsing=false
          ;;
        --scp)
          uses_scp=true
          continue
          ;;
        --tar)
          uses_scp=false
          continue
          ;;
        */?*)
          prefers_scp=true
          ;;
        *)
          [ -L "$arg" ] && prefers_scp=true
          ;;
      esac
    fi
    set -- "$@" "$arg"
  done
  [ -n "$uses_scp" ] || uses_scp=$prefers_scp

  case $comm in
    put)
      if $uses_scp; then
        $scp -r -p "$@" scp://$auth:$port/
      else
        tar zc "$@" | $pv | $ssh -p $port $auth -- tar zx --no-same-owner
      fi
      ;;
    get)
      if $uses_scp; then
        eval "set -- $(printf "scp://$auth:$port/%q\0" "$@" | xargs -0 printf '%q ')"
        $scp -r -p "$@" .
      else
        $ssh -p $port $auth -- "$(printf '%q ' tar zc "$@")" | $pv | tar zx
      fi
      ;;
    init)
      < "$base_dir/config/pack.tar.xz" $pv | $ssh -p $port $auth -- tar Jx --no-same-owner
      ;;
    e)
      $ssh -p $port $auth "$@"
      ;;
    *)
      echo "unrecognized command \`$comm\`"
      exit 1
  esac
}

process_meta "$@" && exit
init_env
main "$@"

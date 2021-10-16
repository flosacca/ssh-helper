#!/bin/bash
set -e

script_dir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
base_dir=$script_dir
profile_dir=$base_dir/auth

resolve() {
  if grep -qE '(^|/)\.{,2}(/|$)' <<< $1; then
    return
  fi
  if [ -f "$profile_dir/alias/$1" ]; then
    resolve "$(< "$profile_dir/alias/$1")"
    return
  fi
  if [ -f "$profile_dir/$1.sh" ]; then
    echo "$1"
  fi
}

show() {
  cat "$profile_dir/current" 2>/dev/null
}

load() {
  local id="$(resolve "$(or "$1" "$(show)")")"
  [ -n "$id" ] && . "$profile_dir/$id.sh"
}

save() {
  local id="$(resolve "$1")"
  if [ -n "$id" ]; then
    echo "$id" > "$profile_dir/current"
  fi
}

process_meta() {
  case $1 in
    ls)
      find "$profile_dir" -name '*.sh' -printf '%P\n' |
        awk -v s="$(show)" '{
          sub(/\.sh$/, "")
          sub(/^/, ($0 == s ? "*" : " ") " ")
        } 1'
      ;;
    set)
      shift
      save "$1"
      show
      ;;
    i)
      show
      ;;
    *)
      return 1
  esac
}

init_env() {
  auth=$AUTH
  port=$PORT

  if ! load; then
    echo 'cannot find current profile'
    exit 1
  fi

  auth=$(or "$auth" "$AUTH")
  port=$(or "$port" "$PORT" 22)
  ssh=$(or "$SSH" ssh)
  scp=$(or "$SCP" scp)
  ssh_login=$(or "$SSH_LOGIN" "$ssh -t")

  if [ -z "$NOPASS" ] && [ -n "$SSHPASS" ]; then
    export SSHPASS
    ssh="sshpass -e $ssh"
    scp="sshpass -e $scp"
    ssh_login="sshpass -e $ssh_login"
  fi

  if [ -z "$auth" ]; then
    echo 'hostname not supplied'
    exit 1
  fi

  pv=$(or "$PV" cat)
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

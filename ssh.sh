#!/bin/bash
set -e

script_dir=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
base_dir=$script_dir
profile_dir=$base_dir/auth/profiles

resolve() {
  if match "$1" '(^|/)\.{,2}(/|$)'; then
    return
  fi
  if [ -f "$profile_dir/../alias/$1" ]; then
    resolve "$(< "$profile_dir/../alias/$1")"
    return
  fi
  if [ -f "$profile_dir/$1.sh" ]; then
    puts "$1"
  fi
}

show() {
  cat -- "$profile_dir/../current" 2>/dev/null
}

with() {
  local id="$(resolve "${1:-$(show)}")"
  [ -n "$id" ] && "$2" "$profile_dir/$id.sh"
}

load() {
  with "$1" .
}

detail() {
  with "$1" cat
}

save() {
  local id="$(resolve "$1")"
  if [ -n "$id" ]; then
    puts "$id" > "$profile_dir/../current"
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
    use)
      shift
      save "$1"
      show
      ;;
    i)
      show
      ;;
    d)
      detail
      ;;
    host)
      load
      puts "$AUTH" | cut -d@ -f2
      ;;
    *)
      return 1
  esac
}

init_env() {
  auth=$AUTH
  port=$PORT

  if ! load "$1"; then
    puts 'cannot find current profile'
    exit 1
  fi

  auth=${auth:-$AUTH}
  port=${port:-${PORT:-22}}
  ssh=${SSH:-ssh}
  scp=${SCP:-scp}
  ssh_login=${SSH_LOGIN:-$ssh -t}

  if [ -z "$NOPASS" ] && [ -n "$SSHPASS" ]; then
    export SSHPASS
    ssh="sshpass -e $ssh"
    scp="sshpass -e $scp"
    ssh_login="sshpass -e $ssh_login"
  fi

  if [ -z "$auth" ]; then
    puts 'hostname not supplied'
    exit 1
  fi

  pv=${PV:-cat}
}

puts() {
  printf '%s\n' "$@"
}

match() {
  awk 'BEGIN { exit ARGV[1] !~ ARGV[2] }' "$@"
}

main() {
  local profile=
  case $1 in
    r|run)
      save "$2"
      ;&
    o|once)
      profile=$2
      shift 2
      ;;
  esac

  init_env "$profile"

  if [ "$#" -eq 0 ] || [ "$1" = a ]; then
    local ssh_args=("$auth" -- tmux -u "$@")
    if match "$ssh_login" '\<ssh\>'; then
      ssh_args=(-p "$port" "${ssh_args[@]}")
    fi
    $ssh_login "${ssh_args[@]}"
    exit
  fi

  local comm uses_scp prefers_scp deref owner_flag parsing arg
  comm=$1
  prefers_scp=false
  parsing=true
  owner_flag=--no-same-owner
  [ -n "$TAR_NO_OWNER_FLAG" ] && owner_flag=
  shift
  for arg; do
    shift
    if "$parsing"; then
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
        --deref)
          deref=h
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
  if [ -z "$uses_scp" ]; then
    uses_scp=$prefers_scp
    [ "$#" = 1 ] && uses_scp=false
  fi

  case $comm in
    put)
      if "$uses_scp"; then
        $scp -r -p "$@" "scp://$auth:$port/"
      else
        [ "$#" = 1 ] && set -- -C "$(dirname -- "$1")" "$(basename -- "$1")"
        tar ${deref}zc "$@" | $pv | $ssh -p "$port" "$auth" -- tar zx $owner_flag
        [ "${PIPESTATUS[*]}" = '0 0 0' ] || return 1
      fi
      ;;
    get)
      if "$uses_scp"; then
        eval "set -- $(printf "scp://$auth:$port/%q\0" "$@" | xargs -0 printf '%q ')"
        $scp -r -p "$@" .
      else
        [ "$#" = 1 ] && set -- -C "$(dirname -- "$1")" "$(basename -- "$1")"
        $ssh -p "$port" "$auth" -- "tar zc $(printf '%q ' "$@")" | $pv | tar zx
      fi
      ;;
    init)
      < "$base_dir/config/pack.tar.xz" $pv | $ssh -p "$port" "$auth" -- tar Jx $owner_flag
      ;;
    e)
      $ssh -p "$port" "$auth" "$@"
      ;;
    *)
      puts "unrecognized command \`$comm\`"
      return 1
  esac
}

IFS=' '
if match "$1" '^[0-9]'; then
  set -- once "$@"
else
  process_meta "$@" && exit
fi
main "$@"

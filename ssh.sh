#!/bin/bash
set -e
IFS=' '

match() {
  awk 'BEGIN { exit ARGV[1] !~ ARGV[2] }' "$@"
}

puts() {
  printf '%s\n' "$@"
}

panic() {
  puts "$@" >&2
  exit 1
}

check_name() {
  if match "$1" '(^|/)\.{,2}(/|$)'; then
    panic "illegal name \`$1\`"
  fi
}

resolve() {
  check_name "$1"
  if [ -f "$alias_dir/$1" ]; then
    resolve "$(cat "$alias_dir/$1")"
  elif [ -f "$profile_dir/$1.sh" ]; then
    profile=$1
    profile_file=$profile_dir/$1.sh
  else
    panic "no such profile \`$1\`"
  fi
}

get_link() {
  link=$(cat -- "$link_file" 2>/dev/null)
  [ -n "$link" ] || panic 'profile is not set'
}

save_link() {
  [ -n "$profile" ] || panic 'nothing to save'
  puts "$profile" > "$link_file"
}

process_meta() {
  case $1 in
    ls)
      get_link
      find "$profile_dir" -name '*.sh' -printf '%P\n' |
        awk -v "k=$link" '{
          sub(/\.sh$/, "")
          sub(/^/, ($0 == k ? "*" : " ") " ")
        } 1'
      ;;
    alias)
      get_link
      shift
      process_alias "$@"
      ;;
    use)
      resolve "$2"
      save_link
      get_link
      puts "$link"
      ;;
    i)
      get_link
      puts "$link"
      ;;
    d)
      get_link
      resolve "$link"
      cat -- "$profile_file"
      ;;
    host)
      get_link
      resolve "$link"
      . -- "$profile_file"
      puts "$AUTH" | cut -d@ -f2
      ;;
    *)
      return 1
  esac
}

process_alias() {
  case $# in
    0)
      find "$alias_dir" ! -type d -exec awk -v "k=$link" '
        FNR == 1 {
          f = FILENAME
          sub(".*/", "", f)
          l = length(f)
          w = l > w ? l : w
          a[++n] = f
          t[n] = $0
        }
        END {
          for (i = 1; i <= n; ++i) {
            printf "%s %-" w "s -> %s\n", t[i] == k ? "*" : " ", a[i], t[i]
          }
        }
      ' {} +
      ;;
    1)
      check_name "$1"
      if [ ! -f "$alias_dir/$1" ]; then
        panic "no such alias \`$1\`"
      fi
      (
        resolve "$1" 2>/dev/null
        puts "$profile"
      ) || panic "broken alias \`$1\`"
      ;;
    2)
      if ! match "$1" '^[[:alnum:]_-]+$'; then
        panic "invalid alias name \`$1\`"
      fi
      if [ "$2" = - ]; then
        rm -f "$alias_dir/$1"
      else
        resolve "$2"
        puts "$2" > $alias_dir/$1
      fi
      ;;
    *)
      panic "usage: ${0##*/} alias [<name> [<target>|-]]"
  esac
}

script_file=${BASH_SOURCE:-$0}
[ -e "$script_file" ] || panic "bad name \`$script_file\`"
script_dir=$(
  path=$(realpath -- "$script_file")
  puts "${path%/*}"
)
[ -d "$script_dir" ] || panic "bad directory \`$script_dir\`"

base_dir=$script_dir
profile_dir=$base_dir/auth/profiles
alias_dir=$base_dir/auth/alias
link_file=$base_dir/auth/current

link=
profile=
profile_file=

if match "$1" '^[0-9]'; then
  set -- once "$@"
elif process_meta "$@"; then
  exit
fi

init_env() {
  auth=$AUTH
  port=$PORT

  . -- "$profile_file"

  auth=${auth:-$AUTH}
  port=${port:-${PORT:-22}}
  ssh=${SSH:-ssh}
  scp=${SCP:-scp}
  if [ -n "$ssh_login" ]; then
    ssh_login=("${ssh_login[@]}")
  else
    ssh_login=("$ssh" -t)
  fi

  if [ -z "$NOPASS" ] && [ -n "$SSHPASS" ]; then
    export SSHPASS
    ssh="sshpass -e $ssh"
    scp="sshpass -e $scp"
    ssh_login=(sshpass -e "${ssh_login[@]}")
  fi

  if [ -z "$auth" ]; then
    panic 'hostname not supplied'
  fi

  pv=${PV:-cat}
}

main() {
  case $1 in
    o|once)
      resolve "$2"
      shift 2
      ;;
    r|run)
      resolve "$2"
      shift 2
      save_link
      ;;
    *)
      get_link
      resolve "$link"
      ;;
  esac

  init_env

  if [ "$#" -eq 0 ] || [ "$1" = a ]; then
    [ -n "$SSH_LOGIN_NO_TMUX" ] || set -- tmux -u "$@"
    set -- "$auth" -- "$@"
    [ -n "$SSH_LOGIN_NO_PORT" ] || set -- -p "$port" "$@"
    "${ssh_login[@]}" "$@"
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
      panic "unrecognized command \`$comm\`"
  esac
}

main "$@"

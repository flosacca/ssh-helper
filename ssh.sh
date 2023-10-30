#!/bin/bash
# This script should *essentially* be POSIX-compliant (could be run with `/bin/sh`),
# with the only exception being the use of `set -o pipefail`, which is not available in
# POSIX as of 2017. Not setting this option would still allow the script to work, but it
# may exit with 0 even in the case of certain errors.
# Note that it is not about whether the use of external utilities is POSIX-compliant.

set -e
set -u
(set -o pipefail 2>/dev/null) && set -o pipefail
IFS=' '

match() {
  awk 'BEGIN { exit ARGV[1] !~ ARGV[2] }' "$@"
}

puts() {
  printf '%s\n' "$@"
}

panic() {
  [ "$#" = 0 ] || puts "$@" >&2
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

usage() {
  panic "usage: ${script_file##*/} $1"
}

process_meta() {
  case ${1-} in
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
      [ "$#" = 2 ] || usage 'use <profile>'
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
      puts "${AUTH#*@}"
      ;;
    *)
      return 0
  esac
  exit
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
      if match "$1" '[^A-Za-z0-9_-]|^-|-$'; then
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
      usage "alias [<name> [<target>|-]]"
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

process_meta "$@"

next() {
  [ -z "${callback-}" ] || set -- "$callback" "$@"
  "$@"
}

ssh_login() {
  next ssh -t "$@"
}

init_env() {
  auth=${AUTH-}
  port=${PORT-}
  [ -z "${SSHPASS+.}" ] || sshpass=$SSHPASS

  . -- "$profile_file"

  auth=${auth:-${AUTH-}}
  [ -n "$auth" ] || panic 'hostname not supplied'
  port=${port:-${PORT:-22}}
  [ -n "${sshpass+.}" ] || sshpass=${SSHPASS-}

  pv=${PV:-cat}
}

_sshpass() {
  [ -z "$sshpass" ] || set -- sshpass -p "$sshpass" "$@"
  "$@"
}

_scp() {
  _sshpass scp "$@"
}

ssh_e() {
  _sshpass ssh -p "$port" "$auth" "$@"
}

ssh_l() {
  set -- "$auth" "$@"
  [ -n "${SSH_LOGIN_NO_PORT-}" ] || set -- -p "$port" "$@"
  callback=_sshpass ssh_login "$@"
}

{
  case ${1-} in
    [0-9]*) set -- o "$@";;
  esac

  case ${1-} in
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

  if [ "$#" = 0 ] && [ -n "${SSH_LOGIN_COMMAND+.}" ]; then
    [ -z "$SSH_LOGIN_COMMAND" ] || set -- -- "$SSH_LOGIN_COMMAND"
    ssh_l "$@"
    exit
  fi

  if [ "$#" = 0 ] || [ "$1" = a ]; then
    ssh_l -- tmux -u "$@"
    exit
  fi

  comm=$1
  shift

  uses_scp=
  has_dir=false
  has_symlink=false
  deref=false
  ssh_tar_x_flags=
  [ -n "${TAR_NO_OWNER_FLAG-}" ] || ssh_tar_x_flags=--no-same-owner

  parsing=true
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
          deref=true
          continue
          ;;
        */?*)
          has_dir=true
          ;;
        *)
          [ -L "$arg" ] && has_symlink=true
          ;;
      esac
    fi
    set -- "$@" "$arg"
  done

  if [ -z "$uses_scp" ]; then
    if "$has_symlink"; then
      uses_scp=true
    elif [ "$#" = 1 ]; then
      uses_scp=false
    else
      uses_scp=$has_dir
    fi
  fi

  tar_c_apply() {
    [ "$#" = 1 ] && set -- -C "$(dirname -- "$1")" "$(basename -- "$1")"
    "$deref" && set -- -h --hard-dereference "$@"
    "$callback" "$@"
  }

  case $comm in
    put)
      [ "$#" = 0 ] && usage 'put <file>...'
      for arg; do
        [ -e "$arg" ] || panic "cannot find \`$arg\`"
      done
      if "$uses_scp"; then
        _scp -r -p "$@" "scp://$auth:$port/"
      else
        tar_put() {
          tar zc "$@" | "$pv" | ssh_e -- "tar zx $ssh_tar_x_flags"
        }
        callback=tar_put tar_c_apply "$@"
      fi
      ;;
    get)
      [ "$#" = 0 ] && usage 'get <file>...'
      if "$uses_scp"; then
        for arg; do
          shift
          set -- "$@" "$(env printf %q "scp://$auth:$port/$arg")"
        done
        _scp -r -p "$@" .
      else
        tar_get() {
          ssh_e -- "tar zc $(env printf '%q ' "$@")" | "$pv" | tar zx
        }
        callback=tar_get tar_c_apply "$@"
      fi
      ;;
    init)
      "$pv" < $base_dir/config/pack.tar.xz | ssh_e -- "tar Jx $ssh_tar_x_flags"
      ;;
    e)
      ssh_e "$@"
      ;;
    *)
      panic "unrecognized command \`$comm\`"
  esac
}

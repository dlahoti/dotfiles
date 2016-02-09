# /etc/skel/.bashrc
#
# This file is sourced by all *interactive* bash shells on startup,
# including some apparently interactive shells such as scp and rcp
# that can't tolerate any output.  So make sure this doesn't display
# anything or bad things will happen !


# Test for an interactive shell.  There is no need to set anything
# past this point for scp and rcp, and it's important to refrain from
# outputting anything in those cases.
if [[ $- != *i* ]] ; then
	# Shell is non-interactive.  Be done now!
	return
fi


# Put your fun stuff here.

alias ls='ls --color=auto -N'

export GOPATH=~/Documents/go
export PATH="$HOME/Documents/Dropbox (MIT)/scripts:$GOPATH:$GOPATH/bin:$PATH"

shopt -s histappend

export PROMPT_COMMAND=__prompt_command

function __prompt_command () {
  local EXIT="$?"

  local red='\[\e[31;1m\]'
  local green='\[\e[32;1m\]'
  local yellow='\[\e[33;1m\]'
  local blue='\[\e[34;1m\]'
  local magenta='\e[35;40m'
  local cyan='\[\e[36;1m\]'
  local white='\[\e[37;1m\]'
  local colorreset='\[\e[0m\]'

  PS1='\[\033]0;\u@\h:\w\007\]'
  PS1+="${yellow}["
  if [[ $EXIT != 0 ]]; then
    PS1+=${red}
  else
    PS1+=${green}
  fi
  PS1+="$(printf '%02x' $EXIT)${yellow}] ${cyan}\u@\h ${blue}\w ${yellow}\$ ${colorreset}"
}

#[[ -z "$SSH_AGENT_PID" ]] && eval $(ssh-agent)

FORTUNE_MOD="zippy paradoxum linux wisdom songs-poems science riddles politics platitudes pets people news medicine literature linuxcookie law goedel fortunes food education drugs definitions cookie computers ascii-art art tao taow chalkboard zx-error kernelcookies"
/usr/bin/fortune $FORTUNE_MOD | ~/Documents/Dropbox\ \(MIT\)/scripts/animalsay.sh # | /usr/bin/lolcat

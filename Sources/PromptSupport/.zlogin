ZDOTDIR=$_banana_user_dotdir
if [[ -r "$ZDOTDIR/.zlogin" ]]; then source "$ZDOTDIR/.zlogin"; fi
_banana_state=$BANANA_THEME_STATE
_banana_fifo=$BANANA_THEME_FIFO
if [[ -n $BANANA_LIMITS_BASE && -x /usr/bin/jq ]] && (( ! $+functions[claude] && ! $+aliases[claude] )); then
  _banana_claude_launcher=$BANANA_STARTUP_DIR/claude-launch.sh
  function claude {
    local binary=${commands[claude]}
    if [[ ! -x $binary ]]; then command claude "$@"; return $?; fi
    /bin/sh "$_banana_claude_launcher" "$binary" "$@"
  }
fi
unset _banana_user_dotdir BANANA_STARTUP_DIR BANANA_THEME_STATE BANANA_THEME_FIFO
_banana_original=$PROMPT
_banana_original_right=$RPROMPT
_banana_last_status=0
_banana_first_prompt=yes

# Engine output is data, not shell code. Protect literal percent signs and
# mark ANSI sequences as zero-width so ZLE preserves the editing cursor.
_banana_escape() {
  setopt localoptions extendedglob
  REPLY=${1//\%/%%}
  REPLY=${REPLY//(#m)$'\e]'[^$'\a']#$'\a'/\%\{$MATCH\%\}}
  REPLY=${REPLY//(#m)$'\e'[\[]([0-9\;:]#)[A-Za-z]/\%\{$MATCH\%\}}
}
_banana_render() {
  local cfg mode value bin output right='' REPLY
  [[ -r $_banana_state ]] || return 0
  cfg=$(<"$_banana_state")
  mode=${cfg%%$'\n'*}
  value=${cfg#*$'\n'}
  case $mode in
    off)
      if [[ $_banana_active == yes ]]; then
        PROMPT=$_banana_original RPROMPT=$_banana_original_right
        _banana_active=no
      else
        _banana_original=$PROMPT _banana_original_right=$RPROMPT
      fi
      return 0 ;;
    starship|oh-my-posh)
      if [[ $value == *$'\n'* ]]; then
        bin=${value#*$'\n'}
        value=${value%%$'\n'*}
      fi
      [[ -x $bin ]] || bin=${commands[$mode]}
      [[ -x $bin ]] || bin=/opt/homebrew/bin/$mode
      [[ -x $bin ]] || bin=/usr/local/bin/$mode
      if [[ ! -x $bin ]]; then
        output="[$mode unavailable] "
      elif [[ $mode == starship ]]; then
        output=$(STARSHIP_CONFIG="$value" STARSHIP_SHELL=unknown "$bin" prompt --terminal-width "$COLUMNS" --status "$_banana_last_status")
        right=$(STARSHIP_CONFIG="$value" STARSHIP_SHELL=unknown "$bin" prompt --right --terminal-width "$COLUMNS" --status "$_banana_last_status")
      else
        local -a args=(--config "$value" --shell uni --escape=false --terminal-width "$COLUMNS" --status "$_banana_last_status")
        output=$("$bin" print primary "${args[@]}")
        right=$("$bin" print right "${args[@]}")
      fi
      # Themes may add blank lines between commands. Skip that separator
      # before the first prompt, but keep any real multiline header.
      if [[ $_banana_first_prompt == yes ]]; then
        while [[ $output == *$'\n'* && -z ${${output%%$'\n'*}//[[:space:]]/} ]]; do
          output=${output#*$'\n'}
        done
      fi
      # A width-padded status row belongs to terminal output. If it is part of
      # PS1, ZLE replays its old padding at each intermediate window width.
      if [[ $output == *$'\n'* ]]; then
        [[ $1 == update ]] && zle -I
        print -r -- "${output%$'\n'*}"
        output=${output##*$'\n'}
      fi
      _banana_escape "$output"; _banana_left=$REPLY
      _banana_escape "$right"; _banana_right=$REPLY ;;
    Classic|Ribbon|Minimal|Stacked)
      _banana_left=$value _banana_right=''
      local env_name=${CONDA_DEFAULT_ENV:-${VIRTUAL_ENV:t}}
      if [[ $mode == Ribbon && -n $env_name && $env_name != *[^[:alnum:]_.-]* ]]; then
        _banana_left="($env_name) $_banana_left"
      fi ;;
    *) return 0 ;;
  esac
  _banana_active=yes
  if [[ -o promptsubst ]]; then
    PROMPT='${_banana_left}' RPROMPT='${_banana_right}'
  else
    PROMPT=$_banana_left RPROMPT=$_banana_right
  fi
}
_banana_precmd() { _banana_last_status=$?; _banana_render; _banana_first_prompt=no; }
_banana_update() {
  local byte
  sysread -i "$1" -s 4096 byte || return
  _banana_render update
  zle reset-prompt
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _banana_precmd
zmodload zsh/system
if sysopen -rw -o cloexec -u _banana_fd "$_banana_fifo"; then
  zle -F "$_banana_fd" _banana_update
fi

ZDOTDIR=$_banana_user_dotdir
if [[ -r "$ZDOTDIR/.zshrc" ]]; then source "$ZDOTDIR/.zshrc"; fi
_banana_user_dotdir=${ZDOTDIR-$HOME}
ZDOTDIR=$BANANA_STARTUP_DIR
if [[ -n $BANANA_AUTOSUGGESTIONS && -r $BANANA_AUTOSUGGESTIONS ]] && (( ! $+functions[_zsh_autosuggest_start] )); then
  source "$BANANA_AUTOSUGGESTIONS"
fi
if [[ -n $BANANA_PAY_RESPECTS && -x $BANANA_PAY_RESPECTS ]]; then
  eval "$("$BANANA_PAY_RESPECTS" zsh --alias --nocnf)"
fi
if [[ -n ${BANANA_EXTENSION_ROOT-} && -n ${BANANA_EXTENSION_SCRIPTS-} ]]; then
  for _banana_script in "${(@s.:.)BANANA_EXTENSION_SCRIPTS}"; do
    [[ -r "$BANANA_EXTENSION_ROOT/$_banana_script" ]] && source "$BANANA_EXTENSION_ROOT/$_banana_script"
  done
  unset _banana_script
fi
unset BANANA_EXTENSION_ROOT BANANA_EXTENSION_SCRIPTS
if [[ -n $BANANA_SYNTAX_HIGHLIGHTING && -r $BANANA_SYNTAX_HIGHLIGHTING ]] && (( ! $+functions[_zsh_highlight] )); then
  source "$BANANA_SYNTAX_HIGHLIGHTING"
fi
unset BANANA_AUTOSUGGESTIONS BANANA_PAY_RESPECTS BANANA_SYNTAX_HIGHLIGHTING

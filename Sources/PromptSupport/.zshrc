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
unset BANANA_AUTOSUGGESTIONS BANANA_PAY_RESPECTS

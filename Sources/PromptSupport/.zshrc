ZDOTDIR=$_banana_user_dotdir
if [[ -r "$ZDOTDIR/.zshrc" ]]; then source "$ZDOTDIR/.zshrc"; fi
_banana_user_dotdir=${ZDOTDIR-$HOME}
ZDOTDIR=$BANANA_STARTUP_DIR

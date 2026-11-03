unset ZDOTDIR
if [[ -r ~/.zshenv ]]; then source ~/.zshenv; fi
_banana_user_dotdir=${ZDOTDIR-$HOME}
ZDOTDIR=$BANANA_STARTUP_DIR

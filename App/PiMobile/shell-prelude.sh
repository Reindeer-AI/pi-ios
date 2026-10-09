# Loaded before every shell command pi runs (AShellBackend.swift): git's everyday forms that lg2 lacks. Commands that
# need no shell (pip, which, cut, ...) are scripts in the app's bin folder instead (Vendor/python-support/pitools.py):
# a-Shell's dash hangs when a pipe feeds a shell function, so only git, which needs the shell, is one.

# git is libgit2's lg2: git's everyday commands with fewer options. Translate the common forms it lacks; everything
# else goes to lg2 as is. (lg2 hangs on `checkout -b`, so that never reaches it.) No subshells: a-Shell's dash crashes
# when a subshell's output is redirected, as in `git init > /dev/null`.
git() {
	git_back=""
	while :; do
		case "$1" in
		--no-pager | --paginate | -P) shift ;;
		-C)
			git_back=${git_back:-$PWD}
			cd "$2" || return
			shift 2
			;;
		-c) shift 2 ;;
		*) break ;;
		esac
	done
	git_command "$@"
	git_status=$?
	if [ -n "$git_back" ]; then cd "$git_back" || :; fi
	return $git_status
}

git_command() {
	case "$1" in
	--version | version)
		echo "git version lg2 (libgit2's git commands)"
		;;
	init)
		shift
		for git_argument in "$@"; do
			case "$git_argument" in -*) ;; *) command git init "$@"; return ;; esac
		done
		command git init "$@" .
		;;
	add)
		case " $* " in
		# New and changed files, then deletions (lg2's -u fails where nothing is tracked yet).
		*" -A "* | *" --all "*) command git add . && { command git add -u . 2>/dev/null || :; } ;;
		*) command git "$@" ;;
		esac
		;;
	log)
		shift
		git_oneline=""
		git_sorted=""
		git_count=$#
		while [ "$git_count" -gt 0 ]; do
			git_argument=$1
			shift
			git_count=$((git_count - 1))
			case "$git_argument" in
			--oneline) git_oneline=1 ;;
			--graph | --decorate | --no-decorate | --color=never) ;;
			--topo-order | --date-order)
				git_sorted=1
				set -- "$@" "$git_argument"
				;;
			-n)
				set -- "$@" "--max-count=$1"
				shift
				git_count=$((git_count - 1))
				;;
			*) set -- "$@" "$git_argument" ;;
			esac
		done
		# Newest first, like git; lg2 otherwise orders commits made in the same second arbitrarily.
		[ -n "$git_sorted" ] || set -- --topo-order "$@"
		if [ -n "$git_oneline" ]; then
			command git log "$@" | awk '
				/^commit / { if (sha != "") print sha " " message; sha = substr($2, 1, 7); message = ""; next }
				/^    / && message == "" { message = substr($0, 5) }
				END { if (sha != "") print sha " " message }'
		else
			command git log "$@"
		fi
		;;
	diff)
		# Options before revisions: lg2 crashes on `diff HEAD~1 --stat`.
		shift
		git_options=""
		git_rest=""
		git_paths=""
		for git_argument in "$@"; do
			git_quote "$git_argument"
			if [ -n "$git_paths" ]; then
				git_rest="$git_rest $git_quoted"
			elif [ "$git_argument" = "--" ]; then
				git_paths=1
				git_rest="$git_rest --"
			else
				case "$git_argument" in
				-*) git_options="$git_options $git_quoted" ;;
				*) git_rest="$git_rest $git_quoted" ;;
				esac
			fi
		done
		eval "command git diff $git_options $git_rest"
		;;
	branch)
		if [ $# -eq 1 ] || [ "$2" = "--list" ] || [ "$2" = "-a" ] || [ "$2" = "-v" ] || [ "$2" = "--show-current" ]; then
			git_repository || return
			git_current=""
			read -r git_head < "$git_dir/.git/HEAD"
			case "$git_head" in "ref: refs/heads/"*) git_current=${git_head#ref: refs/heads/} ;; esac
			if [ "$2" = "--show-current" ]; then
				echo "$git_current"
			else
				command git for-each-ref | awk -v current="$git_current" -v all="$2" '
					$3 ~ /^refs\/heads\// { name = substr($3, 12); print (name == current ? "* " : "  ") name }
					all == "-a" && $3 ~ /^refs\/remotes\// { print "  remotes/" substr($3, 14) }'
			fi
		else
			command git "$@"
		fi
		;;
	remote)
		if [ $# -eq 1 ] || [ "$2" = "-v" ]; then
			git_repository || return
			awk -v verbose="$2" '
				/^\[remote "/ { name = $0; sub(/^\[remote "/, "", name); sub(/"\].*/, "", name); next }
				/^\[/ { name = "" }
				name != "" && $1 == "url" {
					if (verbose == "-v") { print name "\t" $3 " (fetch)"; print name "\t" $3 " (push)" } else print name
				}' "$git_dir/.git/config"
		else
			command git "$@"
		fi
		;;
	checkout)
		if [ "$2" = "-b" ] || [ "$2" = "-B" ]; then
			command git branch "$3" ${4:+"$4"} && command git checkout "$3"
		else
			command git "$@"
		fi
		;;
	switch)
		shift
		case "$1" in
		-c | --create) command git branch "$2" ${3:+"$3"} && command git checkout "$2" ;;
		*) command git checkout "$@" ;;
		esac
		;;
	restore)
		shift
		if [ "$1" = "--staged" ]; then
			shift
			command git reset HEAD "$@"
		else
			command git checkout --force -- "$@"
		fi
		;;
	*)
		command git "$@"
		;;
	esac
}

# Sets git_dir to the repository's top folder, walking up from the working directory.
git_repository() {
	git_dir=$PWD
	while [ ! -d "$git_dir/.git" ]; do
		if [ -z "$git_dir" ]; then
			echo "fatal: not a git repository (or any of the parent directories): .git" >&2
			return 128
		fi
		git_dir=${git_dir%/*}
	done
}

# Sets git_quoted to $1 quoted for eval.
git_quote() {
	git_text=$1
	git_quoted=""
	while :; do
		case "$git_text" in
		*"'"*)
			git_quoted="$git_quoted${git_text%%"'"*}'\\''"
			git_text=${git_text#*"'"}
			;;
		*)
			git_quoted="'$git_quoted$git_text'"
			return
			;;
		esac
	done
}

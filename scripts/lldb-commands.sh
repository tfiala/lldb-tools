# commands to be sourced into shell startup for lldb dev commands
# copyright 2013, Google, Inc.

# reload lldb scripts
function reload_lldb_commands () {
    echo -n "re-sourcing $BASH_SOURCE..."
    source $BASH_SOURCE
    echo "done."
}

# Args:
#   $1 - the variable name in which to return the found directory
#   path.
#
#   $2 - the directory path fragment to find somewhere between `pwd`
#   and somewhere up the parent directory chain.
#
# e.g.
# $ pwd
# /home/tfiala/llvm/work/llvm/tools
# $ find_dir_parent_chain result 'llvm/.git'
# $ echo $?
# 0
# $ echo $result
# /home/tfiala/llvm/work

function find_dir_parent_chain () {
    if [ -z "$1" -o -z "$2" ]; then
        echo "find_dir_parent_chain () requires two arguments"
        return 1
    fi

    local __retvarname=$1
    local dir_suffix=$2

    # find the dir suffix directory.
    # start in current directory, then walk up parent chain.
    local PARENT_DIR=`pwd`
    while test -n "$PARENT_DIR" && test ! -d "$PARENT_DIR/$dir_suffix"; do
        # echo "$dir_suffix dir not found in $PARENT_DIR, checking parent"
        PARENT_DIR=`dirname $PARENT_DIR`
    done

    if [ -d "$PARENT_DIR/$dir_suffix" ]; then
        # echo "found $dir_suffix here: $PARENT_DIR"
        eval $__retvarname="'$PARENT_DIR'"
        return 0
    else
        # echo "failed to find llvm dir starting at $(pwd)"
        return 1
    fi
}

# args:
#   $1: directory in which to run the 'git pull'
#   $2: (optional) the remote to pull from (defaults to: "origin")
#   $3: (optional) the branch mapping to specify (defaults to:
#   "master:master")
#
# Will leave the cwd untouched on exit

function git_pull () {
    local retval

    # validate directory name
    if [ -z "$1" ]; then
        echo "git_pull requires a first argument"
        return 1
    fi
    local command_dir=$1

    # determine remote repo
    local remote_repo
    if [ -n "$2" ]; then
        remote_repo=$2
    else
        remote_repo='origin'
    fi

    # determine branch mapping
    local branch_mapping
    if [ -n "$3" ]; then
        branch_mapping=$3
    else
        branch_mapping=''
    fi

    # do the git pull
    pushd . >/dev/null
    cd $command_dir
    retval=$?
    if [ $retval -ne 0 ]; then
        echo "git_pull: cannot change directory to $command_dir"
        return $retval
    fi

    echo "Executing 'git pull $remote_repo $branch_mapping' in $command_dir"
    git pull $remote_repo $branch_mapping
    retval=$?
    popd >/dev/null

    # indicate result
    return $retval
}

# args:
#   $1: directory in which to run the 'git clone'
#   $2: the git remote path to clone
#
# Will leave the cwd untouched on exit

function git_clone () {
    local retval

    if [ -z "$1" -o -z "$2" ]; then
        echo "usage: git_clone {cwd-for-clone-op} {repo-to-clone}"
        return 1
    fi

    local command_dir=$1
    local remote_repo=$2

    # do the git clone
    pushd . >/dev/null
    cd $command_dir
    retval=$?
    if [ $retval -ne 0 ]; then
        echo "git_clone: cannot change directory to $command_dir"
        return $retval
    fi

    echo "Executing 'git clone $remote_repo' with cwd $command_dir"
    git clone $remote_repo
    retval=$?
    popd >/dev/null

    # indicate result
    return $retval
}

# Do a git clone on the Google-internal lldb/llvm, lldb/clang and
# lldb/lldb directories.  Place them in LLVM standard order:
#
# lldb/llvm  => ./llvm
# lldb/clang => ./llvm/tools/clang
# lldb/lldb  => ./llvm/tools/lldb

function clone_lldb_all () {
    if ! git_clone '.' 'sso://team/lldb/llvm' ; then
        echo "failed to clone llvm"
        return 1
    fi

    if ! git_clone 'llvm/tools' 'sso://team/lldb/clang' ; then
        echo "failed to clone clang"
        return 1
    fi

    if ! git_clone 'llvm/tools' 'sso://team/lldb/lldb' ; then
        echo "failed to clone lldb"
        return 1
    fi
}

# Do a 'git pull origin' from the llvm root directory. Assumes llvm's
# root git directory lies somewhere within the parent directory chain.

function pull_llvm () {
    local llvm_parent_dir
    find_dir_parent_chain "llvm_parent_dir" "llvm/.git"
    local retval=$?
    if [ "$retval" -ne 0 ]; then
        echo "llvm/.git not found within $(pwd)"
        return $retval
    fi
    # echo "llvm/.git found in $llvm_parent_dir"

    # do the git pull
    git_pull "$llvm_parent_dir/llvm"
    retval=$?

    # indicate result
    return $retval
}

# Do a 'git pull origin' from the clang root directory. Assumes the
# current working directory is somewhere under the llvm (although not
# necessarily clang) parent directory chain.

function pull_clang () {
    local llvm_parent_dir
    find_dir_parent_chain "llvm_parent_dir" "llvm/tools/clang/.git"
    local retval=$?
    if [ $retval -ne 0 ]; then
        echo "llvm/tools/clang/.git not found within $(pwd)"
        return $retval
    fi
    # echo "llvm/tools/clang/.git found in $llvm_parent_dir"

    # do the git pull
    git_pull "$llvm_parent_dir/llvm/tools/clang"
    retval=$?

    # indicate result
    return $retval
}

# usage: pull_lldb_rebase [-a|--pull-all] [-r {remote} | --remote
# {remote}] [ -b {local-mirror-branch} | --branch
# {local-mirror-branch} ]
# 
# This command will:
# - stash if any changes exist on the current branch
# - change to the local-mirror-branch branch
# - pull the remote origin (assumed to be the default remote for the
# local-mirror-branch branch)
# - change back to the previous branch
# - rebase the local-mirror-branch onto the working branch
# - apply the latest stash
#
# Assumes the user is somewhere underneath the llvm (although
# not necessarily lldb) directory tree.

function pull_lldb_rebase () {
    local retval
    local overall_retval=0
    local pull_remote='origin'
    local pull_local_branch='master'
    local pull_branch_spec=''
    local pull_related_branches=no

    # parse args
    while [ $# -gt 0 ]; do
        case $1 in
            # handle remote repo name
            --remote | -r )
                if [ -z "$2" ]; then
                    echo "$1 requires remote repo name argument"
                    return 1
                fi
                shift
                pull_remote=$1
                ;;

            # handle name of the local branch to use
            --branch | -b )
                if [ -z "$2" ]; then
                    echo "$1 requires local branch name argument"
                    return 1
                fi
                shift
                pull_local_branch=$1
                ;;

            # handle request to pull everything
            --pull-all | -a )
                pull_related_branches="yes"
                ;;

            -*)
                echo "Unrecognized option: $1"
                return 1
                ;;

            # First command line arg not matching above skips option
            # processing.
            *)
                break
                ;;
        esac
        shift
    done

    # pull related branches if requested
    if [ "$pull_related_branches" = "yes" ]; then
        for pull_cmd in pull_llvm pull_clang ; do
            $pull_cmd
            if [ $? -ne 0 ]; then
                 echo "Failed to pull with $pull_cmd"
                 return 1
            fi
        done
    fi

    # find lldb directory
    local llvm_parent_dir
    find_dir_parent_chain "llvm_parent_dir" "llvm/tools/lldb/.git"
    local retval=$?
    if [ $retval -ne 0 ]; then
        echo "llvm/tools/lldb/.git not found within $(pwd)"
        return $retval
    fi
    # echo "llvm/tools/lldb/.git found in $llvm_parent_dir"

    local lldb_dir="$llvm_parent_dir/llvm/tools/lldb"

    # change into lldb_dir
    pushd . >/dev/null
    cd $lldb_dir
    retval=$?
    if [ $retval -ne 0 ]; then
        echo "failed to change working directory to $lldb_dir: $retval"
        return retval
    fi

    # stash if any changes exist on the branch
    local stash_result=$(git status -s)
    if [ -n "$stash_result" ]; then
        # Stash the changes.
        #
        # Add anything that is unknown.  We do this in case we're
        # adding something that was also added upstream. This will
        # help understand the merge conflict more readily.
        local unknown_wd_files=$(echo "$stash_result" | grep '^??' | \
            awk ' { print $2 } ')
        if [ -n "$unknown_wd_files" ]; then
            echo "$unknown_wd_files" | xargs git add
            retval=$?
            if [ $retval -ne 0 ]; then
                echo "failed to add local changes to the git repo: $retval"
                popd >/dev/null
                return $retval
            fi
        fi

        echo "stashing branch state"
        git stash save
        retval=$?
        if [ $retval -ne 0 ]; then
            echo "failed to save current working directory state: $?"
            popd >/dev/null
            return $retval
        fi
    else
        echo "no local changes need to be stashed"
    fi

    # get the current branch so we can restore it later
    local old_branch=$(git branch | grep '^*' | awk ' { print $2 } ')
    echo "old branch: $old_branch"

    # checkout the master branch
    git checkout "$pull_local_branch"
    retval=$?
    if [ $retval -ne 0 ]; then
        echo "switching to branch $pull_local_branch failed"
        # mark the call as failing, but allow orderly cleanup
        overall_retval=1
    else
        # do the pull
        git pull $pull_remote $pull_branch_spec
        if [ $retval -ne 0 ]; then
            echo "git pull "$pull_remote" "$pull_branch_spec" failed: $retval"
            overall_retval=1
        fi
    fi

    # change back to the old branch
    git checkout "$old_branch"
    retval=$?
    if [ $retval -ne 0 ]; then
        echo "switching back to branch $old_branch failed: $retval"
        overall_retval=1
    else
        # rebase from the local pull branch
        git rebase "$pull_local_branch"
        retval=$?
        if [ $retval -ne 0 ]; then
            echo "failed to rebase $pull_local_branch onto $old_branch: $retval"
            overall_retval=1
        else
            # reapply the stash
            if [ -n "$stash_result" ]; then
                git stash pop
                retval=$?
                if [ $retval -ne 0 ]; then
                    echo "git stash pop failed: $retval"
                    echo "It is likely you will need to resolve conflicts."
                    overall_retval=1
                fi
            fi
        fi
    fi

    # restore dir
    popd >/dev/null

    return $overall_retval
}

# make_lldb_tags [tags-path, default: LLVM-PARENT:TAGS]
function make_lldb_tags () {
    # find llvm root dir
    local llvm_parent_dir
    find_dir_parent_chain "llvm_parent_dir" "llvm/.git"
    local retval=$?
    if [ "$retval" -ne 0 ]; then
        echo "llvm/.git not found within $(pwd)"
        return $retval
    fi
    echo "Found llvm parent dir: $llvm_parent_dir"

    # figure out tags path name
    local tags_path
    if [ -n "$1" ]; then
	tags_path=$1
    else
	tags_path="$llvm_parent_dir/TAGS"
    fi
    echo "Writing tags file to: $tags_path"

    # run ctags on .h/.cpp files in llvm tree and
    # .h files in /usr/include
    { find /usr/include -name '*.h' -exec echo '"{}"' \; ; \
	find "$llvm_parent_dir/llvm" -name '*.h' -o -name '*cpp' -exec echo '"{}"' \; ; \
    } | xargs ctags -e --c++-kinds=+p --fields=+iaS --extra=+q \
	--language-force=C++ -f $tags_path
    local retval=$?
    if [ $retval -ne 0 ]; then
	echo "failed to generate tags file"
    fi
    return $retval
}

alias mklog lldb-mklog.py
alias mkilog lldb-mkilog.py

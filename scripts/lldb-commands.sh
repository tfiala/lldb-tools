# commands to be sourced into shell startup for lldb dev commands

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

# This command will:
# - stash if any changes exist on the branch
# - change to the master branch
# - pull the remote origin onto master
# - change back to the previous branch
# - rebase the master onto the working branch
# - apply the latest stash

function pull_lldb_rebase () {
    local retval
    local overall_retval=0
    local pull_remote='origin'
    local pull_local_branch='master'
    # assume the local branch is tracking upstream, and a 'git pull
    # $pull_remote' is sufficient.
    # local pull_branch_spec="master:$pull_local_branch"
    local pull_branch_spec=''

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
        local unknown_wd_files=$(echo "$stash_result" | grep '^??' | awk ' { print $2 } ')
        if [ -n "$unknown_wd_files" ]; then
            echo "$unknown_wd_files" | xargs git add
            retval=$?
            if [ $retval -ne 0 ]; then
                echo "failed to add changes from working directory to the git repo: $retval"
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
        git pull "$pull_remote" "$pull_branch_spec"
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

function cfglldb () {
    local INSTALL_DIR
    if [ -n "$1" ]; then
        INSTALL_DIR=$1
    else
        INSTALL_DIR=install
    fi
    echo Using install dir $INSTALL_DIR
    ../llvm/configure --enable-cxx11 --prefix=`pwd`/../$INSTALL_DIR
}

function mklog () {
    make $@ 2>&1 | tee make.log
}

function mkilog () {
    make $@ install 2>&1 | tee make_install.log
}

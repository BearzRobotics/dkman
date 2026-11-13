# bash completion for dkman. Page names come from dkman's own index (-k '').
_dkman() {
    local cur prev words cword
    _init_completion -s 2>/dev/null || {
        cur=${COMP_WORDS[COMP_CWORD]}
        prev=${COMP_WORDS[COMP_CWORD-1]}
    }
    case $prev in
        -M|--manpath|-l|--local-file) _filedir 2>/dev/null; return ;;
        -s|-S|--sections)
            COMPREPLY=($(compgen -W "1 2 3 4 5 6 7 8 9 n l" -- "$cur")); return ;;
        -L|--locale|-P|--pager|--width) return ;;
    esac
    if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W "-l -w -f -k -K -b -a -s -S -M -L -P -V -h -7
            --local-file --where --path --whatis --apropos --global-apropos
            --browse --all --sections --manpath --locale --pager --width
            --ascii --color --no-color --no-pager --update-index --version
            --help" -- "$cur"))
        return
    fi
    local names
    names=$(dkman -k '' 2>/dev/null | sed 's/ (.*//' | sort -u)
    COMPREPLY=($(compgen -W "$names" -- "$cur"))
}
complete -F _dkman dkman

# fish completion for dkman. Page names come from dkman's own index (-k '').
function __dkman_pages
    dkman -k '' 2>/dev/null | sed 's/ (\(.*\)) *- /\t/; s/\t.*//' | sort -u
end
complete -c dkman -f -a '(__dkman_pages)'
complete -c dkman -s l -l local-file -r -F -d 'Show a file'
complete -c dkman -s w -l where -d 'Print the path of the page'
complete -c dkman -s f -l whatis -d 'One-line descriptions'
complete -c dkman -s k -l apropos -d 'Search names and descriptions'
complete -c dkman -s K -l global-apropos -d 'Search page text'
complete -c dkman -s b -l browse -d 'Browse pages'
complete -c dkman -s a -l all -d 'Show every matching page'
complete -c dkman -s s -s S -l sections -x -a '1 2 3 4 5 6 7 8 9 n l' -d 'Only these sections'
complete -c dkman -s M -l manpath -r -d 'Manual directories'
complete -c dkman -s L -l locale -x -d 'Language of the pages'
complete -c dkman -s P -l pager -x -d 'Pager command'
complete -c dkman -l width -x -d 'Line width'
complete -c dkman -s 7 -l ascii -d 'ASCII characters only'
complete -c dkman -l color -d 'Always use colors'
complete -c dkman -l no-color -d 'No colors'
complete -c dkman -l no-pager -d 'Write to standard output'
complete -c dkman -l update-index -d 'Rebuild the description cache'
complete -c dkman -s V -l version -d 'Print the version'
complete -c dkman -s h -l help -d 'Print usage'

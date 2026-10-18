# This bash script is an filtering tool that directly from terminal filters all the contents with a ripgrep and also intelligently formats
# and detects exactly if the string (in this case the argument after the <command> that is searched for) searched for is avaliable in the
# command's man page or not.

_manq_box() {
        local title="$1"
        local body="$2"

        local cols
        cols="$(tput cols 2>/dev/null || printf '80')"

        local margin=6
        local max_width=$((cols - margin))
        ((max_width < 20)) && max_width=20

        local h_char="-"
        local v_char="|"
        local tl="+"
        local tr="+"
        local bl="+"
        local br="+"

        local inner_width=$((max_width - 4))

        # -- Top Border Calculation --
        local title_str=" $title "
        local title_len=${#title_str}
        local dashes_len=$((inner_width - title_len + 1))

        if ((dashes_len < 2)); then
                title_str="${title_str:0:inner_width-2}"
                title_len=${#title_str}
                dashes_len=$((inner_width - title_len))
        fi

        local top_dashes=$(printf "%${dashes_len}s" "" | tr ' ' "$h_char")
        local horizontal=$(printf "%${inner_width}s--" "" | tr ' ' "$h_char")

        printf '%s%s%s%s%s\n' "$tl" "$h_char" "$title_str" "$top_dashes" "$tr"
        printf '%s %-*s %s\n' "$v_char" "$inner_width" "" "$v_char"
        printf '%s%s%s\n' "$tl" "$horizontal" "$tr"

        # Process the body in awk
        printf '%s\n' "$body" | awk -v w="$inner_width" -v vc="$v_char" '
    function print_line(prefix, text,    space_left, visible_text) {
        visible_text = text
        gsub(/\001/, "", visible_text)
        gsub(/\002/, "", visible_text)
        
        space_left = w - length(prefix) - length(visible_text)
        if (space_left < 0) space_left = 0
        
        gsub(/\001/, "\033[1;33m", text)
        gsub(/\002/, "\033[0m", text)
        
        printf "%s %s%s%*s %s\n", vc, prefix, text, space_left, "", vc
    }
    {
        if (length($0) == 0) {
            print_line("", "")
            next
        }

        prefix = ""
        text = $0
        if (match($0, /^[> ] *[0-9]+ \| /)) {
            prefix = substr($0, 1, RLENGTH)
            text = substr($0, RLENGTH + 1)
        }

        cont_prefix = ""
        if (prefix != "") {
            cont_prefix = prefix
            gsub(/[^|]/, " ", cont_prefix)
        }

        max_text_len = w - length(prefix)
        if (max_text_len < 1) max_text_len = 1

        first = 1
        while (length(text) > max_text_len) {
            vis_len = 0
            split_pos = 0
            for (i = 1; i <= length(text); i++) {
                c = substr(text, i, 1)
                if (c != "\001" && c != "\002") vis_len++
                if (vis_len == max_text_len) {
                    split_pos = i
                    break
                }
            }
            
            if (split_pos == 0) split_pos = length(text)
            
            backtrack_pos = split_pos
            for (i = split_pos; i > 0; i--) {
                c = substr(text, i, 1)
                if (c ~ /[[:space:]]/) {
                    backtrack_pos = i
                    break
                }
            }
            
            if (backtrack_pos > 0) {
                chunk = substr(text, 1, backtrack_pos - 1)
                text = substr(text, backtrack_pos + 1)
            } else {
                chunk = substr(text, 1, split_pos)
                text = substr(text, split_pos + 1)
            }

            if (first) {
                print_line(prefix, chunk)
                first = 0
            } else {
                print_line(cont_prefix, chunk)
            }
        }
        if (first) {
            print_line(prefix, text)
        } else {
            print_line(cont_prefix, text)
        }
    }
    '

        printf '%s%s%s\n' "$bl" "$horizontal" "$br"
}

manq() {
        local context=4
        local range=""

        if [[ $# -eq 0 ]]; then
                set -- -h
        fi

        while [[ $# -gt 0 ]]; do
                case "$1" in
                -c | --context)
                        [[ $# -ge 2 ]] || {
                                printf 'manq: -c requires a number\n' >&2
                                return 2
                        }
                        context="$2"
                        shift 2
                        ;;
                -r | --range)
                        [[ $# -ge 2 ]] || {
                                printf 'manq: -r requires a range\n' >&2
                                return 2
                        }
                        range="$2"
                        shift 2
                        ;;
                -h | --help)
                        cat <<'EOF'
usage:
    manq [-c lines] [-r start:end] section [pattern]

options:
    -c, --context N      lines before and after each match
    -r, --range A:B      show only hits A through B
    -h, --help           show help

examples:
    manq ls              show description and all available flags
    manq cp --reflink    search for a specific flag
EOF
                        return 0
                        ;;
                -*)
                        printf 'manq: unknown option: %s\n' "$1" >&2
                        return 2
                        ;;
                *)
                        break
                        ;;
                esac
        done

        [[ $# -ge 1 ]] || {
                printf 'manq: missing section\n' >&2
                return 2
        }

        local section="$1"
        local pattern="${2:-}"

        [[ "$context" =~ ^[0-9]+$ ]] || {
                printf 'manq: context must be a non-negative integer\n' >&2
                return 2
        }

        local source_name
        source_name="$(man -w "$section" 2>/dev/null | head -n 1 | xargs -r basename)"

        if [[ -z "$source_name" ]]; then
                _manq_box "Error" "Manual page for '$section' not found."
                return 1
        fi

        local tmp
        tmp="$(mktemp)" || return 1
        trap 'rm -f "$tmp"' RETURN

        if ! MANWIDTH="$(tput cols 2>/dev/null || printf '80')" \
        MANPAGER=cat \
        PAGER=cat \
                man "$section" 2>/dev/null |
                col -bx | sed 's/\x1b\[[0-9;]*[mK]//g' >"$tmp"; then

                _manq_box "Error" "Could not render manual for '$section'."
                return 1
        fi

        # 2. If no pattern is provided, show intro + flags
        if [[ -z "$pattern" ]]; then
                local desc flags body
                # Extract NAME section
                desc="$(awk '/^NAME/{f=1;next}/^[A-Z]/{f=0}f' "$tmp" | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//' | tr '\n' ' ')"

                # Extract flags cleanly: Look for lines starting with a dash, isolate the left column
                flags="$(awk '
            /^[[:space:]]+-/ {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                # Find the first occurrence of 2 or more spaces (separates flag from description)
                if (match(line, /[[:space:]]{2,}/)) {
                    print substr(line, 1, RSTART - 1)
                } else {
                    print line
                }
            }
        ' "$tmp" | sort -u | paste -sd ", " -)"

                if [[ -z "$flags" ]]; then
                        flags="No flags detected."
                fi

                # Use printf -v to insert actual newlines instead of literal \n
                printf -v body "Description:\n%s\n\nAvailable Flags:\n%s" "$desc" "$flags"

                _manq_box "$source_name | Overview" "$body"
                return 0
        fi

        # 3. Pattern searching logic
        local -a hits
        local grep_cmd="grep"
        command -v rg >/dev/null 2>&1 && grep_cmd="rg"

        mapfile -t hits < <("$grep_cmd" -n -- "$pattern" "$tmp" | cut -d: -f1)
        local total="${#hits[@]}"

        if ((total == 0)); then
                local err_msg
                printf -v err_msg "Pattern: %s\nFile:    %s\n\nNo matches found." "$pattern" "$source_name"

                if [[ "$pattern" == -* ]]; then
                        printf -v err_msg "Flag:    %s\nFile:    %s\n\nFlag not found in this manual.\nRun 'manq %s' to see all available flags." "$pattern" "$source_name" "$section"
                fi

                _manq_box "No Matches" "$err_msg"
                return 0
        fi

        local first=1
        local last="$total"

        if [[ -n "$range" ]]; then
                if [[ "$range" =~ ^([0-9]+)?(:([0-9]+)?)?$ ]]; then
                        [[ -n "${BASH_REMATCH[1]}" ]] && first="${BASH_REMATCH[1]}"
                        [[ -n "${BASH_REMATCH[3]}" ]] && last="${BASH_REMATCH[3]}"
                        [[ "$range" == *:* ]] || last="$first"
                else
                        printf 'manq: invalid range: %s\n' "$range" >&2
                        return 2
                fi
        fi

        if ((first < 1 || first > total || last < first)); then
                printf 'manq: invalid range: %s (%d hits found)\n' "$range" "$total" >&2
                return 2
        fi

        ((last > total)) && last="$total"

        local i hit start end body

        for ((i = first; i <= last; i++)); do
                hit="${hits[i - 1]}"
                start=$((hit - context))
                end=$((hit + context))
                ((start < 1)) && start=1

                body="$(
                        awk -v start="$start" -v end="$end" -v hit="$hit" -v pat="$pattern" '
                NR >= start && NR <= end {
                    line = $0
                    if (pat != "") {
                        gsub(pat, "\001&\002", line)
                    }
                    if (NR == hit)
                        printf "> %6d | %s\n", NR, line
                    else
                        printf "  %6d | %s\n", NR, line
                }
            ' "$tmp"
                )"

                _manq_box "$source_name | hit $i/$total | line $hit" "$body"
                ((i < last)) && printf '\n'
        done
}

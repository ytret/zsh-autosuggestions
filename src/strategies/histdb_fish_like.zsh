
(( ! ${+ZSH_AUTOSUGGEST_HISTDB_CWD_WEIGHT} )) && typeset -gi ZSH_AUTOSUGGEST_HISTDB_CWD_WEIGHT=100
(( ! ${+ZSH_AUTOSUGGEST_HISTDB_PARENT_WEIGHT} )) && typeset -gi ZSH_AUTOSUGGEST_HISTDB_PARENT_WEIGHT=50
(( ! ${+ZSH_AUTOSUGGEST_HISTDB_RECENCY_WEIGHT} )) && typeset -gi ZSH_AUTOSUGGEST_HISTDB_RECENCY_WEIGHT=30
(( ! ${+ZSH_AUTOSUGGEST_HISTDB_FREQUENCY_WEIGHT} )) && typeset -gi ZSH_AUTOSUGGEST_HISTDB_FREQUENCY_WEIGHT=20
(( ! ${+ZSH_AUTOSUGGEST_HISTDB_SUCCESS_WEIGHT} )) && typeset -gi ZSH_AUTOSUGGEST_HISTDB_SUCCESS_WEIGHT=10
(( ! ${+ZSH_AUTOSUGGEST_HISTDB_FAILURE_PENALTY} )) && typeset -gi ZSH_AUTOSUGGEST_HISTDB_FAILURE_PENALTY=15
(( ! ${+ZSH_AUTOSUGGEST_HISTDB_MIN_SCORE} )) && typeset -gi ZSH_AUTOSUGGEST_HISTDB_MIN_SCORE=10
(( ! ${+ZSH_AUTOSUGGEST_HISTDB_MAX_ROWS} )) && typeset -gi ZSH_AUTOSUGGEST_HISTDB_MAX_ROWS=500
(( ! ${+ZSH_AUTOSUGGEST_HISTDB_RECENCY_HALFLIFE} )) && typeset -gi ZSH_AUTOSUGGEST_HISTDB_RECENCY_HALFLIFE=604800

_zsh_autosuggest_strategy_histdb_fish_like() {
	emulate -L zsh
	setopt EXTENDED_GLOB

	local prefix="$1"

	(( ${+functions[_histdb_query]} )) || { typeset -g suggestion=""; return }
	[[ -n "${HISTDB_FILE}" ]] || { typeset -g suggestion=""; return }
	(( ${+functions[sql_escape]} )) || { typeset -g suggestion=""; return }
	[[ -n "$prefix" ]] || { typeset -g suggestion=""; return }

	local escaped_prefix="$(sql_escape "$prefix")"
	local escaped_pwd="$(sql_escape "$PWD")"
	local escaped_parent_dir="$(sql_escape "${PWD:h}")"

	local weight_cwd=$ZSH_AUTOSUGGEST_HISTDB_CWD_WEIGHT \
	      weight_parent=$ZSH_AUTOSUGGEST_HISTDB_PARENT_WEIGHT \
	      weight_recency=$ZSH_AUTOSUGGEST_HISTDB_RECENCY_WEIGHT \
	      weight_freq=$ZSH_AUTOSUGGEST_HISTDB_FREQUENCY_WEIGHT \
	      weight_success=$ZSH_AUTOSUGGEST_HISTDB_SUCCESS_WEIGHT \
	      penalty_failure=$ZSH_AUTOSUGGEST_HISTDB_FAILURE_PENALTY \
	      min_score=$ZSH_AUTOSUGGEST_HISTDB_MIN_SCORE \
	      max_rows=$ZSH_AUTOSUGGEST_HISTDB_MAX_ROWS \
	      halflife=$ZSH_AUTOSUGGEST_HISTDB_RECENCY_HALFLIFE

	local query="
		SELECT commands.argv
		FROM (
			SELECT command_id, (
				CASE WHEN cwd_match = 1 THEN ${weight_cwd} ELSE 0 END
				+ CASE WHEN parent_match = 1 THEN ${weight_parent} ELSE 0 END
				+ ${weight_freq} * cnt
				+ MAX(0.0, 1.0 - (strftime('%s','now') - max_start) * 1.0 / ${halflife}) * ${weight_recency}
				+ CASE WHEN last_status = 0 THEN ${weight_success} ELSE 0 END
				- CASE WHEN last_status IS NOT NULL AND last_status != 0 THEN ${penalty_failure} ELSE 0 END
			) AS score
			FROM (
				SELECT
					history.command_id,
					COUNT(*) AS cnt,
					MAX(history.start_time) AS max_start,
					(SELECT h2.exit_status FROM history h2 WHERE h2.command_id = history.command_id ORDER BY h2.start_time DESC LIMIT 1) AS last_status,
					(SELECT 1 FROM history h3 JOIN places p3 ON h3.place_id = p3.id WHERE h3.command_id = history.command_id AND p3.dir = '${escaped_pwd}' LIMIT 1) AS cwd_match,
					(SELECT 1 FROM history h4 JOIN places p4 ON h4.place_id = p4.id WHERE h4.command_id = history.command_id AND p4.dir = '${escaped_parent_dir}' LIMIT 1) AS parent_match
				FROM history
				JOIN commands ON history.command_id = commands.id
				JOIN places ON history.place_id = places.id
				WHERE commands.argv LIKE '${escaped_prefix}%'
				GROUP BY history.command_id
				ORDER BY max_start DESC
				LIMIT ${max_rows}
			)
			ORDER BY score DESC
			LIMIT 1
		) AS scored
		JOIN commands ON scored.command_id = commands.id
		WHERE score >= ${min_score}
	"

	local result="$(_histdb_query "$query")"

	[[ "$result" == "$prefix"* ]] || { typeset -g suggestion=""; return }

	if [[ -n "$ZSH_AUTOSUGGEST_HISTORY_IGNORE" ]] && [[ "$result" == ${~ZSH_AUTOSUGGEST_HISTORY_IGNORE} ]]; then
		typeset -g suggestion=""
		return
	fi

	typeset -g suggestion="$result"
}

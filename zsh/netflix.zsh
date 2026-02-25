# Netflix-specific zsh configuration
# This file contains Netflix work-related settings, aliases, and functions

# Netflix environment variables
export DGI_ARTIFACT_PATH=$HOME/repos/dgi-artifact
export KV_REPO_PATH="$HOME/repos/cde-dgw-kv"

# Netflix-specific aliases
alias agclean='pynt clean && newt dev-setup &&  newt start-local-deps && pynt lock-deps'
alias rb_all='~/repos/fun-bash-automations/rebase-all-branches/rebaseAllBranches.sh'
alias bcc='mint build'
alias rbcc='rb_all && testbcc'
alias dpl='./gradlew -PdependencyLock.includeTransitives=true -Pstatus=release generateLock saveLock'
alias pydpl='newt deps lock --upgrade'
alias qb='./gradlew build -x integTest -x smokeTest -x test'
alias grp='git -C ~/repos/cde-dgw-kv rev-parse'
alias ui_lint="npm run lint-fix -w client && npm run format-fix -w client && npm run type-check -w client"
alias vpnk="sudo kill -SEGV $(ps auwx | grep dsAccessService | grep Ss | awk '{print $2}')"

# CRDB aliases
alias crdb-control-prod='newt --app-type secure-db-proxy -- -s 5433:postgres://crdb_dgw_control.us-east-1.prod'
alias crdb-control-test='newt --app-type secure-db-proxy -- -s 5433:postgres://crdb_dgw_control.us-east-1.test'
alias crdb-sql='psql --host=127.0.0.1 --port=5433 --dbname=dgi_kv --username=root'

# jq aliases for namespace inspection
alias by_cluster="jq '.namespaces[] | {namespace_name, cluster: .persistence_configurations.persistence_configuration[].physical_storage}'"
alias by_cluster_name="jq '.namespaces[] | {namespace_name, cluster: .persistence_configurations.persistence_configuration[].physical_storage.cluster}'"
alias desires="jq '.namespaces[0].provision_desires_v2'"

# AWS credentials
alias awscreds='newt --app-type awscreds refresh -r persistence_prod_cde'

# Crontab -e
# 0 45/60 10-5 * MON,TUE,WED,THU,FRI * osascript -e 'display notification "Take a stretch break!" with title "Break reminder" sound name "Glass"'

function shard() {
  grpc -a dgwcontrol.kv -e $1 -r us-east-1 com.netflix.dgw.control.DgwControlService/GetNamespaces -d "{\"shard_identity\": \"$2\"}"
}

function watch() {
  grpc -a dgwcontrol.kv -e "$1" com.netflix.dgw.control.DgwControlService/WatchNamespaces -d "{\"getNamespacesRequest\": { \"shardIdentity\": \"$2\" }}"
}

function handshake() {
  grpc -a dgwkv.$2 -r eu-west-1 -e $1 com.netflix.dgw.kv.v2.KeyValueServiceV2/Handshake -d '{}'
}

function cluster() {
  grpc -a dgwcontrol.kv -e "$1" com.netflix.dgw.control.DgwControlService/GetNamespaces -d "{\"namespaceFilters\": [ { \"physicalClusterName\": \"$2\", \"include_shard_info\": true} ]}"
}

function namespace () {
	grpc -a dgwcontrol.kv -e "$1" com.netflix.dgw.control.DgwControlService/GetNamespaces -d "{\"namespaceFilters\": [ { \"match_name\": \"$2\", \"include_shard_info\": true }, { \"include_provision_desires\": true } ], \"includeClosed\": true}"
}

function routing () {
	JSON=$(grpc -e "$1" -a dgwkv."$2" -r "$3" -s routing com.netflix.dgw.kv.KeyValueRoutingService.GetRouting -d "{\"routingMode\": \"$4\"}")
	echo $JSON | jq ".namespaces_routing_info | .[] | select(.namespace == \"$5\")"
	echo "Version:"
	echo $JSON | jq ".version"
}


function clone_ns() {
  # Check if the number of arguments is not equal to 5
  if [ "$#" -ne 4 ]; then
      echo "USAGE: clone_ns ENV SHARD SRC_NS TARGET_NS"
      return 1
  fi

  grpc -a dgwkv.$2 -e $1 com.netflix.dgw.kv.KeyValueControlService/CloneNamespace -d "{\"source_namespace\": \"$3\",\"target_namespace\": \"$4\"}"
}

function heap_dump() {
  # Check if the instance ID is provided
  if [ -z "\$1" ]; then
    echo "Usage: heap_dump <instance_id>"
    return 1
  fi

  # Define variables
  local INSTANCE="$1"
  local REMOTE_PATH="/mnt/data/stateful-compute/shared"
  local LOCAL_PATH="."
  local CONTAINER_NAME="kv"
  local USER="www-data"
  local TIMESTAMP=$(date +%s)
  local DUMP_FILE="heap_dump_${INSTANCE}_${TIMESTAMP}.hprof"

  # Print the local file name
  echo "Local file name will be: $DUMP_FILE"

  # SSH into the instance and execute commands
  ssh $INSTANCE << EOF
    echo "Executing commands on the instance..."

    # Get the process ID
    PID=\$(sudo docker exec $CONTAINER_NAME jps | grep DgwKv | awk '{print \$1}')

    echo "Found Dgw container at PID=\$PID"

    # Change permissions
    sudo chmod 777 -R $REMOTE_PATH

    # Generate heap dump with the new file name
    sudo docker exec $CONTAINER_NAME sudo -u $USER jcmd \$PID GC.heap_dump $REMOTE_PATH/$DUMP_FILE

    # Change permissions again
    sudo chmod 777 -R $REMOTE_PATH
EOF

  # Copy the heap dump to local machine
  echo "Copying heap dump to local machine..."
  scp -C "$INSTANCE:$REMOTE_PATH/$DUMP_FILE" $LOCAL_PATH

  # Print the local file name after copying
  echo "Heap dump has been copied to local machine as: $DUMP_FILE"
  # echo "Heap dump process completed successfully."
}

function cql() {
  cqlsh3 --cluster="$2" --env="$1"
}

function put_item() {
  # Convert the ASCII key and value to base64
  local base64_key=$(echo -n "$4" | base64)
  local base64_value=$(echo -n "$5" | base64)

  # Run the gRPC command with the base64-encoded key and value
  grpc -a "dgwkv.$2" -e "$1" -r us-east-1 com.netflix.dgw.kv.v2.KeyValueServiceV2/PutItems -d "{\"namespace\": \""$3"\", \"id\": \"$4\", \"items\": [{\"key\": \"$base64_key\", \"value\": \"$base64_value\", \"ttl\": 130}], \"idempotencyToken\": {}}"
}

function get_item() {
  grpc -a "dgwkv.$2" -e "$1" -r us-east-1 com.netflix.dgw.kv.v2.KeyValueServiceV2/GetItems -d "{\"namespace\": \""$3"\", \"id\": \"$4\", \"predicate\":{\"match_all\": true}, \"selection\":{\"page_size_bytes\":200000, \"include\": [\"METADATA\"]}}" | jq '.items[] | {key: .key | @base64d, value: .value | @base64d}'
}

function put_get() {
  put_item $1 $2 $3 $4 $5
  get_item $1 $2 $3
}

function deployment_sha() {
  export TEMPORAL_NAMESPACE="antigravity-dabp-prod.hzun2"
  nflx-temporal workflow show --workflow-id="$1" --run-id "$2" --output json  2>&1 | jq '.events[] | select(.eventId == "1") | .workflowExecutionStartedEventAttributes.input.payloads[].data'  -r | base64 --decode | jq '.version_set.artifacts."dgw-kv".value' -r | jq '.n' -r | awk -F'-' '{print $4}' | awk -F'.' '{print $1}'
}

function kv() {
  local command=$1;
  shift;
  dgw-cli kv --shard acceptanceddb $command acceptance_dynamo $@
}

export EASY_CASS_LAB_SSH_KEY=~/.ssh/cassandra_workship

eval "$(fnm env --use-on-cd)"

#compdef temporal
compdef _temporal temporal

# zsh completion for temporal                             -*- shell-script -*-

__temporal_debug()
{
    local file="$BASH_COMP_DEBUG_FILE"
    if [[ -n ${file} ]]; then
        echo "$*" >> "${file}"
    fi
}

_temporal()
{
    local shellCompDirectiveError=1
    local shellCompDirectiveNoSpace=2
    local shellCompDirectiveNoFileComp=4
    local shellCompDirectiveFilterFileExt=8
    local shellCompDirectiveFilterDirs=16
    local shellCompDirectiveKeepOrder=32

    local lastParam lastChar flagPrefix requestComp out directive comp lastComp noSpace keepOrder
    local -a completions

    __temporal_debug "\n========= starting completion logic =========="
    __temporal_debug "CURRENT: ${CURRENT}, words[*]: ${words[*]}"

    # The user could have moved the cursor backwards on the command-line.
    # We need to trigger completion from the $CURRENT location, so we need
    # to truncate the command-line ($words) up to the $CURRENT location.
    # (We cannot use $CURSOR as its value does not work when a command is an alias.)
    words=("${=words[1,CURRENT]}")
    __temporal_debug "Truncated words[*]: ${words[*]},"

    lastParam=${words[-1]}
    lastChar=${lastParam[-1]}
    __temporal_debug "lastParam: ${lastParam}, lastChar: ${lastChar}"

    # For zsh, when completing a flag with an = (e.g., temporal -n=<TAB>)
    # completions must be prefixed with the flag
    setopt local_options BASH_REMATCH
    if [[ "${lastParam}" =~ '-.*=' ]]; then
        # We are dealing with a flag with an =
        flagPrefix="-P ${BASH_REMATCH}"
    fi

    # Prepare the command to obtain completions
    requestComp="${words[1]} __complete ${words[2,-1]}"
    if [ "${lastChar}" = "" ]; then
        # If the last parameter is complete (there is a space following it)
        # We add an extra empty parameter so we can indicate this to the go completion code.
        __temporal_debug "Adding extra empty parameter"
        requestComp="${requestComp} \"\""
    fi

    __temporal_debug "About to call: eval ${requestComp}"

    # Use eval to handle any environment variables and such
    out=$(eval ${requestComp} 2>/dev/null)
    __temporal_debug "completion output: ${out}"

    # Extract the directive integer following a : from the last line
    local lastLine
    while IFS='\n' read -r line; do
        lastLine=${line}
    done < <(printf "%s\n" "${out[@]}")
    __temporal_debug "last line: ${lastLine}"

    if [ "${lastLine[1]}" = : ]; then
        directive=${lastLine[2,-1]}
        # Remove the directive including the : and the newline
        local suffix
        (( suffix=${#lastLine}+2))
        out=${out[1,-$suffix]}
    else
        # There is no directive specified.  Leave $out as is.
        __temporal_debug "No directive found.  Setting do default"
        directive=0
    fi

    __temporal_debug "directive: ${directive}"
    __temporal_debug "completions: ${out}"
    __temporal_debug "flagPrefix: ${flagPrefix}"

    if [ $((directive & shellCompDirectiveError)) -ne 0 ]; then
        __temporal_debug "Completion received error. Ignoring completions."
        return
    fi

    local activeHelpMarker="_activeHelp_ "
    local endIndex=${#activeHelpMarker}
    local startIndex=$((${#activeHelpMarker}+1))
    local hasActiveHelp=0
    while IFS='\n' read -r comp; do
        # Check if this is an activeHelp statement (i.e., prefixed with $activeHelpMarker)
        if [ "${comp[1,$endIndex]}" = "$activeHelpMarker" ];then
            __temporal_debug "ActiveHelp found: $comp"
            comp="${comp[$startIndex,-1]}"
            if [ -n "$comp" ]; then
                compadd -x "${comp}"
                __temporal_debug "ActiveHelp will need delimiter"
                hasActiveHelp=1
            fi

            continue
        fi

        if [ -n "$comp" ]; then
            # If requested, completions are returned with a description.
            # The description is preceded by a TAB character.
            # For zsh's _describe, we need to use a : instead of a TAB.
            # We first need to escape any : as part of the completion itself.
            comp=${comp//:/\\:}

            local tab="$(printf '\t')"
            comp=${comp//$tab/:}

            __temporal_debug "Adding completion: ${comp}"
            completions+=${comp}
            lastComp=$comp
        fi
    done < <(printf "%s\n" "${out[@]}")

    # Add a delimiter after the activeHelp statements, but only if:
    # - there are completions following the activeHelp statements, or
    # - file completion will be performed (so there will be choices after the activeHelp)
    if [ $hasActiveHelp -eq 1 ]; then
        if [ ${#completions} -ne 0 ] || [ $((directive & shellCompDirectiveNoFileComp)) -eq 0 ]; then
            __temporal_debug "Adding activeHelp delimiter"
            compadd -x "--"
            hasActiveHelp=0
        fi
    fi

    if [ $((directive & shellCompDirectiveNoSpace)) -ne 0 ]; then
        __temporal_debug "Activating nospace."
        noSpace="-S ''"
    fi

    if [ $((directive & shellCompDirectiveKeepOrder)) -ne 0 ]; then
        __temporal_debug "Activating keep order."
        keepOrder="-V"
    fi

    if [ $((directive & shellCompDirectiveFilterFileExt)) -ne 0 ]; then
        # File extension filtering
        local filteringCmd
        filteringCmd='_files'
        for filter in ${completions[@]}; do
            if [ ${filter[1]} != '*' ]; then
                # zsh requires a glob pattern to do file filtering
                filter="\*.$filter"
            fi
            filteringCmd+=" -g $filter"
        done
        filteringCmd+=" ${flagPrefix}"

        __temporal_debug "File filtering command: $filteringCmd"
        _arguments '*:filename:'"$filteringCmd"
    elif [ $((directive & shellCompDirectiveFilterDirs)) -ne 0 ]; then
        # File completion for directories only
        local subdir
        subdir="${completions[1]}"
        if [ -n "$subdir" ]; then
            __temporal_debug "Listing directories in $subdir"
            pushd "${subdir}" >/dev/null 2>&1
        else
            __temporal_debug "Listing directories in ."
        fi

        local result
        _arguments '*:dirname:_files -/'" ${flagPrefix}"
        result=$?
        if [ -n "$subdir" ]; then
            popd >/dev/null 2>&1
        fi
        return $result
    else
        __temporal_debug "Calling _describe"
        if eval _describe $keepOrder "completions" completions $flagPrefix $noSpace; then
            __temporal_debug "_describe found some completions"

            # Return the success of having called _describe
            return 0
        else
            __temporal_debug "_describe did not find completions."
            __temporal_debug "Checking if we should do file completion."
            if [ $((directive & shellCompDirectiveNoFileComp)) -ne 0 ]; then
                __temporal_debug "deactivating file completion"

                # We must return an error code here to let zsh know that there were no
                # completions found by _describe; this is what will trigger other
                # matching algorithms to attempt to find completions.
                # For example zsh can match letters in the middle of words.
                return 1
            else
                # Perform file completion
                __temporal_debug "Activating file completion"

                # We must return the result of this command, so it must be the
                # last command, or else we must store its result to return it.
                _arguments '*:filename:_files'" ${flagPrefix}"
            fi
        fi
    fi
}

# don't run the completion function when being source-ed or eval-ed
if [ "$funcstack[1]" = "_temporal" ]; then
    _temporal
fi

[ -f $HOME/.sbn_aliases ] && source $HOME/.sbn_aliases
export PATH=/opt/nflx:/opt/nflx/bin:$PATH

#compdef _nflxlog nflxlog

# zsh completion for nflxlog                              -*- shell-script -*-

__nflxlog_debug()
{
    local file="$BASH_COMP_DEBUG_FILE"
    if [[ -n ${file} ]]; then
        echo "$*" >> "${file}"
    fi
}

_nflxlog()
{
    local shellCompDirectiveError=1
    local shellCompDirectiveNoSpace=2
    local shellCompDirectiveNoFileComp=4
    local shellCompDirectiveFilterFileExt=8
    local shellCompDirectiveFilterDirs=16

    local lastParam lastChar flagPrefix requestComp out directive comp lastComp noSpace
    local -a completions

    __nflxlog_debug "\n========= starting completion logic =========="
    __nflxlog_debug "CURRENT: ${CURRENT}, words[*]: ${words[*]}"

    # The user could have moved the cursor backwards on the command-line.
    # We need to trigger completion from the $CURRENT location, so we need
    # to truncate the command-line ($words) up to the $CURRENT location.
    # (We cannot use $CURSOR as its value does not work when a command is an alias.)
    words=("${=words[1,CURRENT]}")
    __nflxlog_debug "Truncated words[*]: ${words[*]},"

    lastParam=${words[-1]}
    lastChar=${lastParam[-1]}
    __nflxlog_debug "lastParam: ${lastParam}, lastChar: ${lastChar}"

    # For zsh, when completing a flag with an = (e.g., nflxlog -n=<TAB>)
    # completions must be prefixed with the flag
    setopt local_options BASH_REMATCH
    if [[ "${lastParam}" =~ '-.*=' ]]; then
        # We are dealing with a flag with an =
        flagPrefix="-P ${BASH_REMATCH}"
    fi

    # Prepare the command to obtain completions
    requestComp="${words[1]} __complete ${words[2,-1]}"
    if [ "${lastChar}" = "" ]; then
        # If the last parameter is complete (there is a space following it)
        # We add an extra empty parameter so we can indicate this to the go completion code.
        __nflxlog_debug "Adding extra empty parameter"
        requestComp="${requestComp} \"\""
    fi

    __nflxlog_debug "About to call: eval ${requestComp}"

    # Use eval to handle any environment variables and such
    out=$(eval ${requestComp} 2>/dev/null)
    __nflxlog_debug "completion output: ${out}"

    # Extract the directive integer following a : from the last line
    local lastLine
    while IFS='\n' read -r line; do
        lastLine=${line}
    done < <(printf "%s\n" "${out[@]}")
    __nflxlog_debug "last line: ${lastLine}"

    if [ "${lastLine[1]}" = : ]; then
        directive=${lastLine[2,-1]}
        # Remove the directive including the : and the newline
        local suffix
        (( suffix=${#lastLine}+2))
        out=${out[1,-$suffix]}
    else
        # There is no directive specified.  Leave $out as is.
        __nflxlog_debug "No directive found.  Setting do default"
        directive=0
    fi

    __nflxlog_debug "directive: ${directive}"
    __nflxlog_debug "completions: ${out}"
    __nflxlog_debug "flagPrefix: ${flagPrefix}"

    if [ $((directive & shellCompDirectiveError)) -ne 0 ]; then
        __nflxlog_debug "Completion received error. Ignoring completions."
        return
    fi

    while IFS='\n' read -r comp; do
        if [ -n "$comp" ]; then
            # If requested, completions are returned with a description.
            # The description is preceded by a TAB character.
            # For zsh's _describe, we need to use a : instead of a TAB.
            # We first need to escape any : as part of the completion itself.
            comp=${comp//:/\\:}

            local tab=$(printf '\t')
            comp=${comp//$tab/:}

            __nflxlog_debug "Adding completion: ${comp}"
            completions+=${comp}
            lastComp=$comp
        fi
    done < <(printf "%s\n" "${out[@]}")

    if [ $((directive & shellCompDirectiveNoSpace)) -ne 0 ]; then
        __nflxlog_debug "Activating nospace."
        noSpace="-S ''"
    fi

    if [ $((directive & shellCompDirectiveFilterFileExt)) -ne 0 ]; then
        # File extension filtering
        local filteringCmd
        filteringCmd='_files'
        for filter in ${completions[@]}; do
            if [ ${filter[1]} != '*' ]; then
                # zsh requires a glob pattern to do file filtering
                filter="\*.$filter"
            fi
            filteringCmd+=" -g $filter"
        done
        filteringCmd+=" ${flagPrefix}"

        __nflxlog_debug "File filtering command: $filteringCmd"
        _arguments '*:filename:'"$filteringCmd"
    elif [ $((directive & shellCompDirectiveFilterDirs)) -ne 0 ]; then
        # File completion for directories only
        local subDir
        subdir="${completions[1]}"
        if [ -n "$subdir" ]; then
            __nflxlog_debug "Listing directories in $subdir"
            pushd "${subdir}" >/dev/null 2>&1
        else
            __nflxlog_debug "Listing directories in ."
        fi

        local result
        _arguments '*:dirname:_files -/'" ${flagPrefix}"
        result=$?
        if [ -n "$subdir" ]; then
            popd >/dev/null 2>&1
        fi
        return $result
    else
        __nflxlog_debug "Calling _describe"
        if eval _describe "completions" completions $flagPrefix $noSpace; then
            __nflxlog_debug "_describe found some completions"

            # Return the success of having called _describe
            return 0
        else
            __nflxlog_debug "_describe did not find completions."
            __nflxlog_debug "Checking if we should do file completion."
            if [ $((directive & shellCompDirectiveNoFileComp)) -ne 0 ]; then
                __nflxlog_debug "deactivating file completion"

                # We must return an error code here to let zsh know that there were no
                # completions found by _describe; this is what will trigger other
                # matching algorithms to attempt to find completions.
                # For example zsh can match letters in the middle of words.
                return 1
            else
                # Perform file completion
                __nflxlog_debug "Activating file completion"

                # We must return the result of this command, so it must be the
                # last command, or else we must store its result to return it.
                _arguments '*:filename:_files'" ${flagPrefix}"
            fi
        fi
    fi
}

# don't run the completion function when being source-ed or eval-ed
if [ "$funcstack[1]" = "_nflxlog" ]; then
        _nflxlog
fi

export NFLX_CLAUDE_FORCE_CHANNEL=latest
NFLX_CLAUDE_FORCE_CHANNEL=latest

#!/bin/bash

# Clone through Git's transport instead of copying object files across a
# host bind mount and the container filesystem. Retry transient mount errors
# during bootstrap without consuming the agent session's retry budget.
swarm_clone_upstream() {
    local source="$1" destination="$2"
    local log_fn="$3" log_err_fn="$4"
    local max_attempts=5 attempt=1 delay=1

    "$log_fn" "cloning upstream"
    while true; do
        if git clone -q --no-local "$source" "$destination"; then
            return 0
        fi

        if [ "$attempt" -ge "$max_attempts" ]; then
            "$log_err_fn" \
                "upstream clone failed after ${attempt} attempts"
            return 1
        fi

        "$log_err_fn" \
            "upstream clone attempt ${attempt}/${max_attempts} failed;" \
            "retrying in ${delay}s"
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

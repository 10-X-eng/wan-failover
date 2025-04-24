#!/usr/bin/env bash
# WAN fail-over: only adjust PRIMARY metric;

################## CONFIG – edit what’s between the lines #############
PRIMARY_IF="enp3s0"
SECONDARY_IF="enp0s21f0u1"

PRI_METRIC_ACTIVE=10     # lower  → preferred
PRI_METRIC_STANDBY=400   # higher → ignored
# whatever metric DHCP gave SECONDARY stays exactly as it is

TEST_HOSTS=(1.1.1.1 9.9.9.9)
PING_COUNT=4
PING_TIMEOUT=1
CHECK_INTERVAL=3
BAD_CYCLES=2
GOOD_CYCLES=10
LATENCY_LIMIT=100   
LOSS_LIMIT=5   # ms / %
#######################################################################

LOG_FILE=/var/log/wan-failover.log
mkdir -p "$(dirname "$LOG_FILE")"; : >"$LOG_FILE"
log(){ echo "$(date '+%F %T') - $*" | tee -a "$LOG_FILE" >&2; }

########################################################################
# replace_primary_metric  <metric>
########################################################################
replace_primary_metric() {
    local new=$1

    local route
    route=$(ip -o -4 route show dev "$PRIMARY_IF" | awk '$1=="default"{print;exit}')
    [[ -z $route ]] && { log "NO default on $PRIMARY_IF"; return 1; }

    local base=${route% metric *}
    local old=${route##* metric }; old=${old//[[:space:]]/}

    [[ "$old" == "$new" ]] && { log "metric $PRIMARY_IF already $new"; return 0; }

    ip route replace $base metric "$new"          # add/overwrite new metric
    ip route del $base metric "$old" 2>/dev/null  # drop old metric (ignore if gone)

    log "metric $PRIMARY_IF $old → $new"
}

########################################################################
# check_link IFACE  → good|degraded|failed   (pings logged)
########################################################################
check_link(){
    local ifc=$1 lost=0 rtt_sum=0 probes=0
    local pkts=$((PING_COUNT*${#TEST_HOSTS[@]}))

    for h in "${TEST_HOSTS[@]}"; do
        out=$(ping -q -c $PING_COUNT -W $PING_TIMEOUT -I "$ifc" "$h" 2>&1)
        if (( $?==0 )); then
            loss=$(awk -F',' '/packet loss/{sub(/%/,"",$3);print $3+0}' <<<"$out")
            rtt=$(awk -F'/'  '/^rtt/{print $5}'                     <<<"$out")
            log "$ifc → $h : ${loss}% loss, ${rtt} ms"
            lost=$((lost+PING_COUNT*loss/100)); rtt_sum=$(bc <<<"$rtt_sum+$rtt")
            ((probes++))
        else
            log "$ifc → $h : ping FAILED"
            lost=$((lost+PING_COUNT))
        fi
    done
    ((probes==0)) && { echo failed; return; }

    pl=$(bc <<<"$lost*100/$pkts"); rt=$(bc <<<"scale=1;$rtt_sum/$probes")
    ((pl==100)) && { echo failed; return; }
    (( $(bc <<<"$pl>$LOSS_LIMIT") || $(bc <<<"$rt>$LATENCY_LIMIT") )) \
        && { echo degraded; return; }
    echo good
}

########## INIT ##########
SEC_METRIC=$(ip -o -4 route show dev "$SECONDARY_IF" \
             | awk '$1=="default"{for(i=1;i<=NF;i++)if($i=="metric"){print $(i+1);exit}}')

log "Start WAN-failover   primary=$PRIMARY_IF  secondary=$SECONDARY_IF"
log "Secondary metric stays at $SEC_METRIC"

replace_primary_metric "$PRI_METRIC_ACTIVE"

active_primary=true bad=0 good=0

########## MAIN LOOP ##########
while :; do
    pri_state=$(check_link "$PRIMARY_IF")
    sec_state=$(check_link "$SECONDARY_IF")

    if $active_primary; then
        [[ $pri_state == good ]] && bad=0 || ((bad++))
        if (( bad>=BAD_CYCLES )) && [[ $sec_state == good ]]; then
            log "FAIL-OVER – demote primary"
            replace_primary_metric "$PRI_METRIC_STANDBY"
            active_primary=false; bad=0; good=0
        fi
    else
        if [[ $pri_state == good ]]; then
            ((good++))
        else
            good=0
        fi

        if (( good >= GOOD_CYCLES )); then
            log "RESTORE – promote primary"
            replace_primary_metric "$PRI_METRIC_ACTIVE"
            active_primary=true
            bad=0; good=0
        fi
    fi
    sleep $CHECK_INTERVAL
done

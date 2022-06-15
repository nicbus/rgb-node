#!/bin/bash

#CLOSING_METHOD="opret1st"
CLOSING_METHOD="tapret1st"

BCLI='docker-compose exec -u blits bitcoind bitcoin-cli -regtest '
RGB0='docker-compose exec -u rgbd rgb-node-0 rgb-cli -n regtest '
RGB1='docker-compose exec -u rgbd rgb-node-1 rgb-cli -n regtest '
RGB2='docker-compose exec -u rgbd rgb-node-2 rgb-cli -n regtest '

addr=""         # filled by calling gen_addr()
asset=""        # filled by calling get_asset_id()
txid=""         # filled by calling gen_utxo()
vout=""         # filled by calling gen_utxo()
txid_rcpt=""    # filled by transfer_asset
vout_rcpt=""    # filled by transfer_asset
txid_change=""  # filled by transfer_asset
vout_change=""  # filled by transfer_asset
balance=0       # filled by get_balance
exp_asset=""    # filled by export_asset

DEBUG=0
MAX_RETRIES=5
C1='\033[0;32m' # green
C2='\033[0;33m' # orange
C3='\033[0;34m' # blue
NC='\033[0m'    # No Color

_die() {
    echo >&2 "$@"
    exit 1
}

_tit() {
    echo
    printf "${C1}==== %-20s ====${NC}\n" "$@"
}

_subtit() {
    printf "${C2} > %s${NC}\n" "$@"
}

_log() {
    printf "${C3}%s${NC}\n" "$@"
}

_trace() {
    { local trace=0; } 2>/dev/null
    { [ -o xtrace ] && trace=1; } 2>/dev/null
    { [ "$DEBUG" != 0 ] && set -x; } 2>/dev/null
    "$@"
    { [ "$trace" == 0 ] && set +x; } 2>/dev/null
}

prepare_wallets() {
    for wallet in 'miner' 'issuer' 'rcpt1' 'rcpt2'; do
        _subtit "creating wallet $wallet"
        _trace $BCLI createwallet $wallet >/dev/null
    done
}

gen_blocks() {
    local count="$1"
    _subtit "mining $count block(s)"
    _trace $BCLI -rpcwallet=miner -generate "$count" >/dev/null
    sleep 1     # give electrs time to index
}

gen_addr() {
    local wallet="$1"
    _subtit "generating new address for wallet \"$wallet\""
    addr=$(_trace $BCLI -rpcwallet="$wallet" getnewaddress | tr -d '\r')
    _log "$addr"
}

gen_utxo() {
    local wallet="$1"
    # generate an address
    gen_addr "$wallet"
    # send and mine
    _subtit "sending funds to wallet \"$wallet\""
    txid="$(_trace $BCLI -rpcwallet=miner sendtoaddress ${addr} 1 | tr -d '\r')"
    gen_blocks 1
    # extract vout
    _subtit "extracting vout"
    local filter=".[] | select(.txid == \"$txid\") | .vout"
    vout="$(_trace $BCLI -rpcwallet=$wallet listunspent | jq "$filter")"
    _log "$txid:$vout"
}

issue_asset() {
    _subtit 'issuing asset'
    _log "unspents before issuance" && _trace $BCLI -rpcwallet=issuer listunspent
    gen_utxo issuer
    txid_issue=$txid
    vout_issue=$vout
    gen_utxo issuer
    txid_issue_2=$txid
    vout_issue_2=$vout
    _trace $RGB0 fungible issue USDT "USD Tether" "1000@$txid_issue:$vout_issue" "1000@$txid_issue_2:$vout_issue_2"
    _log "unspents after issuance" && _trace $BCLI -rpcwallet=issuer listunspent
}

get_asset_id() {
    _subtit 'retrieving asset id'
    asset=$(_trace $RGB0 fungible list -f json | jq -r '.[] | .id')
    _log "$asset"
}

export_asset() {
    exp_asset="$(_trace $RGB0 fungible export $asset | tail -1 | tr -d '\r')"
    _log "exp_asset: $exp_asset"
}

import_asset() {
    local cli="$1"
    _trace $cli fungible import "$exp_asset"
}

get_balance() {
    local wallet="$1"           # wallet name
    local cli="$2"              # rgb-node cli alias

    local utxos=($(_trace $BCLI -rpcwallet="$wallet" listunspent | tr -d '\r' \
        | jq -r '.[] | "\(.txid):\(.vout)"'))
    balance=0
    _log "utxos: ${utxos[*]}"
    for utxo in "${utxos[@]}"; do
        local amount=$(_trace $cli fungible list -l -f json | tr -d '\r' \
            | jq -r ".[] |.knownAllocations |.[] |select (.outpoint == \"$utxo\") |.revealedAmount |.value")
        balance=$((balance + amount))
    done
}

transfer_asset() {
    # params
    local send_wlt="$1"         # sender wallet name
    local rcpt_wlt="$2"         # recipient wallet name
    local send_cli="$3"         # sender rgb-node cli alias
    local rcpt_cli="$4"         # recipient rgb-node cli alias
    local send_data="$5"        # sender rgb-node data dir
    local rcpt_data="$6"        # recipient rgb-node data dir
    local txid_send="$7"        # sender txid
    local vout_send="$8"        # sender vout
    local num="$9"              # transfer number
    local amt_send="${10}"      # asset amount to send
    local amt_change="${11}"    # asset amount to get back as change
    local txid_send_2="${12}"   # sender txid n. 2
    local vout_send_2="${13}"   # sender vout n. 2

    _log "spending $amt_send from $txid_send:$vout_send ($send_wlt) with $amt_change change"
    if [ -n "$txid_send_2" ] && [ -n "$vout_send_2" ]; then  # handle double input case
        _log "also using $txid_send_2:$vout_send_2 as input"
    fi
    _log "unspents before transfer" && _trace $BCLI -rpcwallet="$send_wlt" listunspent
    # starting situation
    _subtit "initial balances"
    get_balance "$send_wlt" "$send_cli"
    _log "sender balance: $balance"
    get_balance "$rcpt_wlt" "$rcpt_cli"
    _log "receiver balance: $balance"
    ## generate utxo to receive assets
    gen_utxo "$rcpt_wlt"
    txid_rcpt=$txid
    vout_rcpt=$vout
    ## blind receiving utxo
    _subtit "blinding UTXO for transfer n. $num"
    local blinding="$(_trace $rcpt_cli fungible blind $txid_rcpt:$vout_rcpt)"
    local blind_utxo_rcpt=$(echo $blinding | awk '{print $3}' | tr -d '\r')
    local blind_secret_rcpt=$(echo $blinding | awk '{print $NF}' | tr -d '\r')
    ## generate addresses for transfer asset change and tx btc output
    if [ "$amt_change" -gt 0 ]; then
        gen_utxo "$send_wlt"
        txid_change=$txid
        vout_change=$vout
        [ "$DEBUG" != 0 ] && _log "change outpoint $txid_change:$vout_change"
    else
        unset txid_change
        unset vout_change
        [ "$DEBUG" != 0 ] && _log "change amount is 0, skipping change outpoint creation"
    fi
    gen_addr "$send_wlt"
    local addr_send=$addr
    ## create psbt
    _subtit "creating PSBT"
    [ "$DEBUG" != 0 ] && _trace $BCLI -rpcwallet="$send_wlt" listunspent
    local filter=".[] |select(.txid == \"$txid_send\") |.amount"
    local amnt="$(_trace $BCLI -rpcwallet=$send_wlt listunspent | tr -d '\r' | jq -r "$filter")"
    if [ -n "$txid_send_2" ] && [ -n "$vout_send_2" ]; then  # handle double input case
        filter=".[] |select(.txid == \"$txid_send_2\") |.amount"
        local amnt_2="$(_trace $BCLI -rpcwallet=$send_wlt listunspent | tr -d '\r' | jq -r "$filter")"
        amnt=$((amnt + amnt_2))
    fi
    local psbt=tx${num}.psbt
    local cons=consignment${num}.rgb
    local disc=discolsure${num}.rgb
    local wtns=witness${num}.psbt
    local in="["
    in="${in} {\"txid\": \"$txid_send\", \"vout\": $vout_send}"
    if [ -n "$txid_send_2" ] && [ -n "$vout_send_2" ]; then  # handle double input case
        in="${in}, {\"txid\": \"$txid_send_2\", \"vout\": $vout_send_2}"
    fi
    in="${in} ]"
    local out="[{\"$addr_send\": \"$amnt\"}]"
    local opts="{\"subtractFeeFromOutputs\": [0]}"
    _trace $BCLI -rpcwallet="$send_wlt" walletcreatefundedpsbt "$in" "$out" 0 "$opts" \
        | jq -r '.psbt' | base64 -d >"$send_data/$psbt"
    if [ "$DEBUG" != 0 ]; then
        _subtit "showing inputs from psbt"
        _trace $BCLI decodepsbt "$(base64 -w0 "$send_data/$psbt")" | tr -d '\r' | jq '.tx | .vin'
        _subtit "showing outputs from psbt"
        _trace $BCLI decodepsbt "$(base64 -w0 "$send_data/$psbt")" | tr -d '\r' | jq '.outputs'
    fi
    sleep 1
    ## transfer
    _subtit "transferring asset"
    local input="-i $txid_send:$vout_send"
    if [ "$amt_change" -gt 0 ]; then
        local change="-a $amt_change@$CLOSING_METHOD:$txid_change:$vout_change"
    else
        local change=""
    fi
    if [ -n "$txid_send_2" ] && [ -n "$vout_send_2" ]; then  # handle double input case
        input="$input -i $txid_send_2:$vout_send_2"
    fi
    _trace $send_cli fungible transfer \
        $blind_utxo_rcpt $amt_send $asset \
        $psbt $cons $disc $wtns \
        $input \
        $change
    _subtit "waiting for witness psbt to appear"
    local tries=0
    while [ ! -f "$send_data/$wtns" ]; do
        tries=$((tries + 1))
        [ $tries -gt $MAX_RETRIES ] && _die " max retries reached"
        echo -n '.'
        sleep 1
    done
    echo "found"
    _trace cp {$send_data,$rcpt_data}/$cons
    _log 'known allocations after transfer'
    _trace $RGB0 fungible list -l -f json | tr -d '\r' | jq -r '.[] |.knownAllocations'
    if [ "$DEBUG" != 0 ]; then
        _subtit "showing inputs from witness"
        _trace $BCLI decodepsbt "$(base64 -w0 "$send_data/$wtns")" | tr -d '\r' | jq '.tx | .vin'
        _subtit "showing outputs from witness"
        _trace $BCLI decodepsbt "$(base64 -w0 "$send_data/$wtns")" | tr -d '\r' | jq '.outputs'
    fi
    ## validate transfer (tx will be still unresolved)
    _subtit "validating transfer (recipient)"
    local vldt="$(_trace $rcpt_cli fungible validate $cons | tr -d '\r')"
    _log "$vldt"
    if ! echo "$vldt" | grep -q 'failures: \[\],'; then
        _die "validation error (failure)"
    fi
    ## complete psbt + broadcast
    _subtit "finalizing and broadcasting tx"
    local base64_psbt=$(_trace $BCLI -rpcwallet="$send_wlt" walletprocesspsbt \
        "$(base64 -w0 "$send_data/$wtns")" | jq -r '.psbt')
    local psbt_final=$(_trace $BCLI -rpcwallet="$send_wlt" finalizepsbt "$base64_psbt" \
        | jq -r '.hex')
    _trace $BCLI -rpcwallet="$send_wlt" sendrawtransaction "$psbt_final"
    gen_blocks 1
    ## accept (tx is now broadcast and confirmed, so it has to resolve)
    _subtit "accepting transfer (recipient)"
    local vldt="$(_trace $rcpt_cli fungible validate $cons | tr -d '\r')"
    _log "$vldt"
    for issue in failures unresolved_txids; do
        if ! echo "$vldt" | grep -q "$issue: \[\],"; then
            _die "validation error ($issue)"
        fi
    done
    _trace $rcpt_cli fungible accept "$cons" "$txid_rcpt:$vout_rcpt" "$blind_secret_rcpt"
    _log 'known allocations before enclose'
    _trace $RGB0 fungible list -l -f json | tr -d '\r' | jq -r '.[] |.knownAllocations'
    ## enclose
    _subtit "enclosing transfer (sender)"
    _trace $send_cli fungible enclose "$disc"
    ## show transfer result
    if [ "$DEBUG" != 0 ]; then
        _subtit "listing assets (sender)"
        _trace $send_cli fungible list -l
        _subtit "listing assets (recipient)"
        _trace $rcpt_cli fungible list -l
    fi
    # ending situation
    _subtit "final balances"
    get_balance "$send_wlt" "$send_cli"
    _log "sender balance: $balance"
    get_balance "$rcpt_wlt" "$rcpt_cli"
    _log "receiver balance: $balance"
    _log "unspents after transfer" && _trace $BCLI -rpcwallet="$send_wlt" listunspent
}

# cmdline options
[ "$1" = "-v" ] && DEBUG=1

# initial setup
_tit 'preparing bitcoin wallets'
prepare_wallets
gen_blocks 103

# asset issuance
_tit 'issuing "USDT" asset'
issue_asset
get_asset_id
export_asset

# asset transfer to self test
#_tit 'transferring asset from issuer to itself'
#transfer_asset issuer issuer "$RGB0" "$RGB0" data0 data0 $txid_issue $vout_issue 1 100 900
#exit 0

# asset transfer 100% -> no change self test
#_tit 'transferring asset completely (0 change) from issuer to recipient 1'
##import_asset "$RGB1"
#transfer_asset issuer rcpt1 "$RGB0" "$RGB1" data0 data1 "$txid_issue" "$vout_issue" 1 2000 0 "$txid_issue_2" "$vout_issue_2"
#exit 0

# asset transfer no. 1
_tit 'transferring asset from issuer to recipient 1'
#import_asset "$RGB1"
transfer_asset issuer rcpt1 "$RGB0" "$RGB1" data0 data1 "$txid_issue" "$vout_issue" 1 100 1900 "$txid_issue_2" "$vout_issue_2"
exit 0

# change spending test
#_tit 'transferring asset from issuer to recipient 1 - 2nd time (spending change)'
#transfer_asset issuer rcpt1 "$RGB0" "$RGB1" data0 data1 $txid_change $vout_change 1 200 1700
#exit 0

# asset transfer no. 2
_tit 'transferring asset from recipient 1 to recipient 2'
#import_asset "$RGB2"
transfer_asset rcpt1 rcpt2 "$RGB1" "$RGB2" data1 data2 "$txid_rcpt" "$vout_rcpt" 2 42 58

# asset transfer no. 3
_tit 'transferring asset from recipient 2 to issuer'
#import_asset "$RGB0"
transfer_asset rcpt2 issuer "$RGB2" "$RGB0" data2 data0 "$txid_rcpt" "$vout_rcpt" 3 32 10

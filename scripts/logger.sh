# Color codes for bash output
BLUE='\033[34m'
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
CLEAR='\033[39m'


#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2155
#
# Filename: logger.sh
# Description: A simple bash logger utility
# Author: ADoyle <adoyle.h@gmail.com>
# LICENSE: Apache License, Version 2.0
# First Created: 2017-06-30T07:09:59Z
# Last Modified: 2021-01-19T11:04:08Z
# Version: 0.2.1
# Bash Version: 4.x
# Source: https://github.com/adoyle-h/bash-logger/blob/v0.2.0/src/logger.sh
# Project: https://github.com/adoyle-h/bash-logger
# Inspired by:
#   - http://www.cubicrace.com/2016/03/efficient-logging-mechnism-in-shell.html


#######################################################################
#                           initialization                            #
#######################################################################

LOG_TARGET=${1:-}

if [[ -n "$LOG_TARGET" ]] ;then
    touch "$LOG_TARGET"
fi


#######################################################################
#                           private methods                           #
#######################################################################

# NO NEED TO LOG INTO FILE
#if [[ -n "$LOG_TARGET" ]] ;then
#  function _echo() {
#    printf "$1" | tee -a "$LOG_TARGET"
#  }
#else
  function _echo() {
    printf "$1"
  }
#fi

function _date_time() {
    date +"%Y/%m/%d %H:%M:%S"
}

function _utc_date_time() {
    date -u +"%Y/%m/%dT%H:%M:%SZ"
}

function _log() {
    { local function_name date_time msg level
    msg="$1"
    local color="$2"
    level="${3:-${FUNCNAME[1]}}"
    date_time=$(_date_time)
    function_name="${FUNCNAME[2]}"
    _echo "${!color} [$date_time][$level]($function_name) $msg ${CLEAR}\n"; } 2> /dev/null
}

function _CTX() {
    local ctx ctx_name ctx_type

    ctx_name="${FUNCNAME[2]}"

    if [[ $ctx_name == main ]]; then
        ctx_name=$0
        ctx_type="script"
    else
        ctx_type="function"
    fi

    ctx=($ctx_name $ctx_type)

    echo "${ctx[@]}"
}


#######################################################################
#                           public methods                            #
#######################################################################

scripts::logger::ENTER() {
    local ctx ctx_name date_time
    ctx=($(_CTX))
    DEBUG "${ctx[1]}: ${ctx[0]}"
}

scripts::logger::EXIT() {
    local ctx date_time
    ctx=($(_CTX))
    DEBUG "${ctx[1]}: ${ctx[0]}"
}

scripts::logger::DEBUG() {
    _log "$1"
}

scripts::logger::INFO() {
    { _log "$1" BLUE ; } 2> /dev/null
}

scripts::logger::WARN() {
  { _log "$1" YELLOW ; } 2> /dev/null
}

scripts::logger::ERROR() {
    { _log "$1" RED ; } 2> /dev/null
}

scripts::logger::ERR_MSG_N_DIE() {
    { _log "$1" RED ; } 2> /dev/null
    exit 1
}

scripts::logger::SUCCESS_MSG() {
    { _log "$1" GREEN ; } 2> /dev/null
}

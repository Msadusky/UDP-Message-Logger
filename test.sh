#!/bin/bash

BINARY=$1
export PATH="./:$PATH"
export CURDIR=$(pwd)

export FAILURES=0
export SHUTDOWNCLEAN=0

export PIDFILE="$CURDIR/udplogd.pid"
export UDPLOGFILE="$CURDIR/udplogd.log"

#Pre-flight checks
if [ -x /bin/nc ]; then
    NCBIN=/bin/nc
elif [ -x /usr/bin/nc ]; then
    NCBIN=/usr/bin/nc
else
    echo "Couldn't find netcat program!!"
    exit 127
fi

#check if I can determine defined port number from code
PORTDEF=$(grep UDP_LOGGER_PORT udplogd.*|grep define|awk '{print $3}'|grep -E '[0-9]+'||echo BADPORT)
if [ "$PORTDEF" == "BADPORT" ]; then
    echo "ERROR: Can't find the port you defined in your code!"
    echo "Can not run tests. Please make sure the port you are using is"
    echo "defined like:"
    echo "#define UDP_LOGGER_PORT 12345"
    echo ""
    echo "Where you replace 12345 with the port number you plan to use!!"
    exit
fi
export PORTDEF

##
# Perform some pre-flight checks
SRC="$CURDIR/udplogd.c"
if [ ! -f $SRC ]; then
    echo "Failed to find source code!"
    echo $SRC
    exit 1
fi

if [ "$USER" == "" ]; then
    USER=$(dd if=/dev/urandom bs=8 count=2 2>/dev/null|md5sum|awk '{print $1}'|cut -b-8)
    export USER
fi

TMPWORKDIR=$(mktemp -d /tmp/$USER-udplogd-test-XXXXXX)
export TMPWORKDIR
if [ ! -d $TMPWORKDIR ]; then
    echo "Temp Dir not found!"
    exit 1
fi
echo $TMPWORKDIR|grep '^/tmp/' >/dev/null
STATUS=$?
if [ $STATUS -ne 0 ]; then
    echo "Something went wrong creating tmp dir!"
    exit 1
fi

export TMPREPORT="$TMPWORKDIR/report.txt"

function log {
    echo $1 >> $TMPREPORT
}

function emergencycleanup {
    echo ""
    echo "Severe error occurred which prevents test script from"
    echo "being able to run correctly. If you're seeing this and the problem"
    echo "Isn't something you can easily clean up, please file a bug report"
    echo "Or at least, inform your instructor ASAP!"
    echo ""
    echo "For more details, here are the logs:"
    echo ""
    cat $TMPREPORT
    rm -rf $TMPWORKDIR
    isrunning
    RUNNING=$?
    if [ $RUNNING -eq 1 ]; then
        cleanup
    fi

    exit 127
}

function runtest {
    TEST=$1
    if [ "$2" != "" ]; then
        MSG=$2
    else
        MSG=$1
    fi
    echo -n "[    ] $MSG"
    $TEST >/dev/null 2>&1
    STATUS=$?
    if [ ${STATUS} -ge 127 ]; then
        emergencycleanup
    elif [ ${STATUS} -ne 0 ]; then
        echo -e "\r[[31mFAIL[0m] $MSG - return status ${STATUS}"
        FAILURES=$(( $FAILURES + 1 ))
    else
        echo -e "\r[[32m OK [0m] $MSG"
    fi
}

#This test checks to make sure comment
#header was updated appropriately.
function headercheck {
    ERROR=0
    grep 'Date:' "$SRC"|grep -v 3015 
    STATUS=$?
    if [ ${STATUS} -ne 0 ]; then
        ERROR=1
        log "Header check failed, you didn't update the Date!"
    fi
    grep Author "$SRC" |grep -v 'Doug Stan'|grep -v 'some.student'
    STATUS=$?
    if [ ${STATUS} -ne 0 ]; then
        ERROR=2
        log "Header check failed, you didn't change the Author!"
    fi

    return $ERROR
}

function checkfordaemoncall {
    ERROR=0
    grep 'daemon(' "$SRC"
    STATUS=$?
    if [ ${STATUS} -ne 1 ]; then
        ERROR=1
        log "Found call to daemon()!"
    fi

    return $ERROR
}

function checkpid {
	ERROR=0

	# Check if the udplogd.pid file exists.
	# If it does, save and export the PID.
    usleep 10
    if [ -s $PIDFILE ]; then
		export DAEMONPID = `cat $PIDFILE`
	else
		log "udplogd.pid file is missing or empty!"
		ERROR=1
	fi
	
    grep -E '^[0-9]+$' $PIDFILE >/dev/null
    STATUS=$?
	# Check to see if the udplogd.pid file contains the PID for the server.
	if [ ${STATUS} -ne 0 ]; then
		log "udplogd.pid does not contain a valid PID number!"
		ERROR=2
	fi
	
	# Check to see if a process called "udplogd" exists with the correct PID.
	ps -ef | pgrep udplogd | grep $DAEMONPID
	STATUS = $?
	if [ ${STATUS} -eq 1 ]; then
		log "udplogd is not running!"
		ERROR=3
	fi
    return ${ERROR}
}

function checklog {
    ERROR=0

    if [ ! -f "$UDPLOGFILE" ]; then
        log "Log file hasn't been created!"
        ERROR=1
    fi

    return ${ERROR}
}

function checkpidfilefail {
    ERROR=0

    if [ -f "$PIDFILE" ]; then
        log "PID file already exists, please clean up and run tests again."
        return 127
    fi
    
    touch $PIDFILE
    STATUS=$?
	if [ ${STATUS} -ne 0 ]; then
        log "Something when really wrong, I couldn't create a a file at:"
        log $PIDFILE
        return 127
	fi

    #We created a dummy pidfile, now make sure the daemon exits with failure
    $BINARY
    STATUS=$?
	if [ ${STATUS} -eq 0 ]; then
        log "Code didn't exit with error when PID file already exists!"
        ERROR=1
	fi
    rm -f $PIDFILE

    return ${ERROR}
}

function checkportinusefail {
    ERROR=0

    if [ -z "$PORTDEF" ]; then
        log "Don't know what port you are using! Is it defined properly?"
        return 127
    fi
    portinuse
    PORTUSED=$?
    if [ $PORTUSED -ne 0 ]; then
        log "port already in use?!?! Something else is listening on your port"
        log "and it isn't the test script or your daemon!"
        log $(netstat -ulnp 2>/dev/null|grep $PORTDEF)
        return 127
    fi

    #use nc to bind the port so udplogd can't bind it
    $NCBIN -u -l $PORTDEF &
    NCPID=$!
    sleep 1

    portinuse
    PORTUSED=$?
    if [ $PORTUSED -ne 1 ]; then
        log "netcat can't seem to bind port! Tests can't continue!"
        kill -9 $NCPID
        wait $NCPID
        return 127
    fi

    #We bound the port, now make sure the daemon exits with failure
    $BINARY
    STATUS=$?
	if [ ${STATUS} -eq 0 ]; then
        log "Code didn't exit with error when the port was in use!"
        ERROR=1
        isrunning
        STATUS=$?
	fi

    kill -9 $NCPID
    STATUS=$?
	if [ ${STATUS} -ne 0 ]; then
        log "Couldn't kill nc command it seems."
        ERROR=128
	fi

    wait $NCPID
    return ${ERROR}
}
function checksigignore {
    ERROR=0
    
    for s in 1 2 3 6 10; do
        kill -$s $(cat $PIDFILE)
        isrunning
        RUN=$?
        if [ $RUN -eq 0 ]; then
            ERROR=1
            log "Process exited with signal -$s"
            break
        fi
    done

    sleep 1
    isrunning
    RUN=$?
    if [ $RUN -eq 0 ]; then
        log "Seems daemon exited with a signal other than TERM!"
        log "Should ignore all signals except TERM!"
        ERROR=1
    fi

    return ${ERROR}
}

function isrunning {
    RUNNING=0
    if [ -f udplogd.pid ]; then
        PID=$(cat udplogd.pid)
        ps -eLo pid,tid,cmd |grep " "$PID" "|grep -v 'grep' |grep udplog >/dev/null
        STATUS=$?
        if [ "$STATUS" -eq 0 ];then
            RUNNING=1
        fi
    fi

    return $RUNNING
}

#Run the daemon and verify it exits with success, then leave it
#running for futher tests
function checkexit {
    ERROR=0
    
    $BINARY
    STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        ERROR=1
        log "Your daemon should exit with success after fork."
        log "Something must have went wrong!"
    fi

    return ${ERROR}
}

function onlyonerunning {
    ERROR=0
    diff <(ps -ef|grep $USER|grep " "`cat $PIDFILE`" "|grep -v grep) <(ps -ef|grep udplogd|grep $USER|grep -v grep)
    STATUS=$?
    if [ "$STATUS" -ne 0 ];then
        ERROR=1
        log "Mismatch in number of proccess running vs what SHOULD be running"
        log $(diff <(ps -ef|grep $USER|grep " "`cat $PIDFILE`" "|grep -v grep) <(ps -ef|grep udplogd|grep $USER|grep -v grep))
    fi

    return ${ERROR}
}

function portinuse {
    PORTUSED=0

    if [ -z "$PORTDEF" ]; then
        log "Port to use isn't defined?"
        return 127
    fi

    netstat -ulnp 2>/dev/null|grep $PORTDEF
    STATUS=$?
    if [ "$STATUS" -eq 0 ];then
        PORTUSED=1
    fi

    return $PORTUSED
}

function checknthreads {
    ERROR=0

    log "Checking number of threads used..."
    if [ -f udplogd.pid ]; then
        PID=$(cat udplogd.pid)
        N=$(ps -eLo pid,tid,cmd,nlwp |grep " "$PID" " |grep -v grep|awk '{print $4}'|sort|uniq)
        C=$(ps -eLo pid,tid,cmd,nlwp |grep " "$PID" " |grep -v grep|awk '{print $4}'|sort|uniq|wc -l)

        if [ "$C" -ne 1 ]; then
            log " Something is wrong with checking process list!"
            log $(ps -eLo pid,tid,cmd,nlwp |grep " "$PID" " |grep -v grep|awk '{print $4}'|sort|uniq)
            ERROR=$(( $ERROR + 1 ))
        elif [ "$N" -gt 1 ]; then
            log " Found $N threads running, looks good."
            ERROR=0
        fi

    else
        log "Checking number of threads failed because I couldn't find the pidfile!"
        ERROR=127
    fi

    return ${ERROR}
}

function checkshutdown {
    ERROR=0

    kill -TERM $(cat $PIDFILE)
    STATUS=$?
    if [ "$STATUS" -ne 0 ];then
        log "Kill failed??"
        ERROR=1
    fi

    COUNT=0
    isrunning
    RUNNING=$?
    while [ $RUNNING -gt 0 && $COUNT -lt 5 ]; do
        sleep 1
        isrunning
        RUNNING=$?
        COUNT=$(( $COUNT + 1 ))
    done
    if [ $COUNT -gt 0 ]; then
        ERROR=127
        log "Server doesn't seem to shutdown!!"
    fi

    #If no errors, set flag that code shuts down cleanly
    #so future tests know to continue.
    if [ "${ERROR}" -eq 0 ]; then
        export SHUTDOWNCLEAN=1
        rm -f $PIDFILE
    fi

    return ${ERROR}
}

function checkshutdownintegrity {
    #Don't run this test if previous shutdown
    #tests failed
    if [ "$SHUTDOWNCLEAN" -eq 0 ]; then
        log "Previous shutdown seems to have failed! I can't perform this\
        test unless I can start and stop the process multiple times without\
        issue!"
        return 127
    fi

    #Need to send several packets, request shutdown, then verify our packets
    #were successfully logged.

    #first see if the server is already running, and start it if it isn't.
    ERROR=0
    isrunning
    RUNNING=$?
    if [ $RUNNING -eq 1 ]; then
        cleanup >/dev/null  2>&1
        ERROR=$?
    fi

    cleanfiles
    STATUS=$?
    if [ "$STATUS" -ne 0 ];then
        log "File cleanup failed!"
        ERROR=$(( $ERROR + $STATUS ))
    fi

    if [ "$ERROR" -gt 0 ]; then
        log "Cleanup failed, can't verify shutdown integrity!"
        return 127
    fi

    #So at this point, everything should be nice and clean, no logs
    #or anything to interfere with out tests.

    #start up server and make sure it exits
    checkexit
    STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        log "It seems we failed to start server. Can't run log integrity tests!"
        ERROR=$(( $ERROR + 2 ))
    fi

    #Send 3 messages and shutdown server
    LMSG="Testing log integrity part "
    send_udp_packet "$LMSG 1"
    PIDA=$!
    send_udp_packet "$LMSG 2"
    PIDB=$!
    send_udp_packet "$LMSG 3"
    PIDC=$!

    checkshutdown
    STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        log "It seems we failed to shutdown the server. Can't run log integrity tests!"
        ERROR=$(( $ERROR + 4 ))
    fi

    #Make sure the packet sending commands exit
    wait $PIDA $PIDB $PIDC

    #Now make sure those messages went to the log file...
    grep "$LMSG" $UDPLOGFILE
    STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        log "Log integrity check failed, failed to find message sent in log!"
        ERROR=$(( $ERROR + 8 ))
    fi

    N=$(grep "$LMSG" $UDPLOGFILE |wc -l)
    if [ "$N" -ne 3 ]; then
        log "Log seems to be missing some messages, expected 3, found $N"
        ERROR=$(( $ERROR + 16 ))
    fi

    return ${ERROR}
}

function checkport {
    ERROR=0
    netstat -ulnp 2>/dev/null|grep $PORTDEF|grep udplog
    STATUS=$?
    if [ ${STATUS} -ne 0 ]; then
        ERROR=1
        log "Port not open! You sure you bound the socket?"
    fi

    return ${ERROR}
}
function checklogappend {
    #Don't run this test if previous shutdown
    #tests failed
    if [ "$SHUTDOWNCLEAN" -eq 0 ]; then
        return 127
    fi

    #Need to send several packets, request shutdown, then verify our packets
    #were successfully logged.

    #first see if the server is already running, and start it if it isn't.
    ERROR=0
    isrunning
    RUNNING=$?
    if [ $RUNNING -eq 1 ]; then
        cleanup >/dev/null  2>&1
        ERROR=$?
    fi

    cleanfiles
    STATUS=$?
    if [ "$STATUS" -ne 0 ];then
        log "File cleanup failed!"
        ERROR=$(( $ERROR + $STATUS ))
    fi

    if [ "$ERROR" -gt 0 ]; then
        log "Cleanup failed, can't perform append test!"
        return 127
    fi

    #Basically this test does the same as the integrity check, only it
    #runs it twice to make sure that the logfile persists and is appended to

    #So at this point, everything should be nice and clean, no logs
    #or anything to interfere with out tests.

    #start up server and make sure it exits
    checkexit
    STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        log "It seems we failed to start server. Can't run log append tests!"
        ERROR=$(( $ERROR + 2 ))
    fi

    #Send 3 messages and shutdown server
    LMSG="Testing log integrity part A, MSG"
    send_udp_packet "$LMSG #1"
    PIDA=$!
    send_udp_packet "$LMSG #2"
    PIDB=$!

    checkshutdown
    STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        log "It seems we failed to shutdown the server. Can't run log append tests!"
        ERROR=$(( $ERROR + 4 ))
    fi

    #Make sure the packet sending commands exit
    wait $PIDA $PIDB $PIDC

    #Now make sure those messages went to the log file...
    grep "$LMSG" $UDPLOGFILE
    STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        log "Log append check part A failed, failed to find message sent in log!"
        ERROR=$(( $ERROR + 8 ))
    fi

    N=$(grep "$LMSG" $UDPLOGFILE |wc -l)
    if [ "$N" -ne 2 ]; then
        log "Log seems to be missing some messages, expected 2, found $N"
        ERROR=$(( $ERROR + 16 ))
    fi

    #remove pidfile, and start again
    if [ -f "$PIDFILE" ]; then
        rm -f "$PIDFILE"
    fi

    if [ ! -s "$UDPLOGFILE" ]; then
        log "Expected the log file to exit, but it seems to be missing or empty!"
        return 127
    fi

    #start up server and make sure it exits
    checkexit
    STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        log "It seems we failed to start server. Can't run log append tests!"
        return 127
    fi

    #Send 3 messages and shutdown server
    OLDMSG="Testing log integrity part A, MSG"
    NEWMSG="Testing log integrity part B, MSG"
    send_udp_packet "$NEWMSG #1"
    PIDA=$!
    send_udp_packet "$NEWMSG #2"
    PIDB=$!

    checkshutdown
    STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        log "It seems we failed to shutdown the server. Can't run log append tests!"
        return 127
    fi

    #Make sure the packet sending commands exit
    wait $PIDA $PIDB $PIDC

    #Now make sure those messages went to the log file...
    LMSG="$OLDMSG"
    grep "$LMSG" $UDPLOGFILE
    STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        log "Log append check part A failed, failed to find message sent in log!"
        ERROR=$(( $ERROR + 8 ))
    fi

    N=$(grep "$LMSG" $UDPLOGFILE |wc -l)
    if [ "$N" -ne 2 ]; then
        log "Log seems to be missing some messages, expected 2, found $N"
        ERROR=$(( $ERROR + 16 ))
    fi
    LMSG="$NEWMSG"
    grep "$LMSG" $UDPLOGFILE
    STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        log "Log append check part A failed, failed to find message sent in log!"
        ERROR=$(( $ERROR + 8 ))
    fi

    N=$(grep "$LMSG" $UDPLOGFILE |wc -l)
    if [ "$N" -ne 2 ]; then
        log "Log seems to be missing some messages, expected 2, found $N"
        ERROR=$(( $ERROR + 16 ))
    fi

    return ${ERROR}
}

#functions used by test functions
function send_udp_packet {
    CMD="nc -u -w 1 127.0.0.1 $PORTDEF"
    if [ -z "$1" ]; then
        cat | $CMD
    else
        echo "$@" | $CMD
    fi
}

function killserver {
    if [ -z "$1" ]; then
        SIG="-TERM"
    else
        SIG=$1
    fi
    if [ -f udplogd.pid ]; then
        kill $SIG $(cat udplogd.pid)
    else
        log "Tried to kill server, but couldn't find pid file!"
        return 1
    fi

    return 0
}

#kill all processes we may have left behind
function cleanallprocs {
    if [ -x "$BINARY" ]; then
        killp "$BINARY"
    fi
    killp "nc -"
}

function killp {
    if [ ! -z "$1" ]; then
        WHAT=$1
        CMD="ps -ef|grep $WHAT|grep $USER |grep -v grep|grep -v 'ps -ef'\
             |grep -v defunct | grep -v test.sh
             |awk '{print $2}'"
        log $( $CMD )
        $CMD
    fi
}

function numprocsleft {
    NUM=0
    CMD="ps -ef | grep $USER|grep -v grep|grep -v defunct|grep -v 'test\.sh'"
    NBIN=$( $CMD | grep $BINARY|wc -l )
    NOTHER=$( $CMD |grep "nc -"|wc -l )
    NUM=$(( $NBIN + $NOTHER ))
    return $NUM
}

function cleanfiles {
    ERROR=0

    if [ -f "$PIDFILE" ]; then
        echo "Removing $PIDFILE"
        rm -f "$PIDFILE"
        STATUS=$?
        if [ "$STATUS" -ne 0 ];then
            log "Failed to remove $PIDFILE!"
            ERROR=$(( $ERROR + 2 ))
        fi
    fi
    if [ -f "$UDPLOGFILE" ]; then
        echo "Removing $UDPLOGFILE"
        rm -f "$UDPLOGFILE"
        STATUS=$?
        if [ "$STATUS" -ne 0 ];then
            log "Failed to remove $UDPLOGFILE!"
            ERROR=$(( $ERROR + 4 ))
        fi
    fi

    return ${ERROR}
}

function cleanup {
    ERROR=0

    cleanallprocs
    sleep 1
    numprocsleft
    NUM=$?
    if [ "$NUM" -gt 0 ];then
        CMD="ps -ef | grep $USER |\
             grep -v grep|grep -v defunct | \
             grep -v 'test\.sh'"
        log "Failed to kill off all processes. Please clean up manually!"
        log "$( $CMD |grep $BINARY )"
        log "$( $CMD |grep "nc -" )"
        ERROR=1
    fi

    #attempt to clean up files
    cleanfiles
    STATUS=$?
    if [ "$STATUS" -ne 0 ];then
        log "File cleanup failed!"
        ERROR=$(( $ERROR + $STATUS ))
    fi

    return ${ERROR}
}

log "udplogd Tests Starting $(date)"
log "###################################################"

##
# Run all tests
if [ -f "$SRC" ]; then
    runtest headercheck "Checking Comment Header"
    runtest checkfordaemoncall "Making sure daemon() not used."
else
    echo "Can't find $SRC to check it!"
    log "$SRC missing!"
    exit 127
fi

if [ -x "$BINARY" ]; then
    #pre-run checks
    runtest checkpidfilefail "Whether code fails if pid file already exists."
    runtest checkportinusefail "Whether code fails if port already in use."
    #run the code and test it while it's running.
    runtest checkexit "Make sure daemon parent exits properly."
    runtest checkpid "Checking pid file gets written and is valid."
    runtest checklog "Checking log file is created"
    runtest checkport "Checking if port is open."
    runtest checknthreads "Checking if multiple threads running"
    #finally test signals
    runtest checksigignore "Verify that signals are being ignored."
    runtest checkshutdown "Verify clean shutdown with SIGTERM signal."
    #tests to see if code breaks down
    runtest checkshutdownintegrity "Verify integrity of log (no data lost)."
    runtest checklogappend "Checking if log is appended to..."
else
    echo "$BINARY not executable or not found!"
    log "$BINARY missing!"
    exit 127
fi

runtest cleanup "Testing finished, cleaning up logs and pidfiles..."

#Clean up
log "###################################################"
log ""
log "udplogd Tests Finished..."
log ""
if [ $FAILURES -gt 0 ]; then
    echo -e "\nErrors reported, following is the error report:\n"
    cat $TMPREPORT
else
    echo "No errors reported, you're good to go!"
fi

echo "All done, removing temporary files in $TMPWORKDIR"
rm -rf $TMPWORKDIR

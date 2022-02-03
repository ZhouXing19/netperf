#!/bin/bash
#  Copyright 2021 Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
#
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
# DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
# USE OR OTHER DEALINGS IN THE SOFTWARE.

# this is a quick and dirty migration of runemomniagg2.sh to the
# --enable-demo mode of aggregate testing

DURATION=${DURATION:=180}
TEST_MODE=${TEST_MODE:="cross-region"}
mkdir -p $TEST_MODE
MACHINE_NAME=${MACHINE_NAME:="unknown machine"}
# do not have a uuidgen? then use the one in netperf
MY_UUID=`uuidgen`
# with top-of-trunk we could make this 0 and run forever
# but two hours is something of a failsafe if the signals
# get lost
LENGTH="-l 7200"
OUTPUT="-o all"

function kill_netperfs {
    pkill -ALRM netperf

    pgrep -P 1 -f netperf > /dev/null
    while [ $? -eq 0 ]
    do
	sleep 1
	pgrep -P 1 -f netperf > /dev/null
    done
}

# run_cmd is to start get the best number of streams for a throughput test.
# It increment the number of streams, run for a given period, record the throughput
# of each stream every 0.5 second. At each second, it sums up the throughput of
# all streams to get the aggregate throughput. At the end of this given period,
# it calculate the average aggregate throughput (AAT) across this period.
# If the standard deviation of the latest AATs is lower than a certain threshold,
# the throughput is considered converged and we take the n-2*step as the best
# number of stream. If not converged, repeat back to adding new streams.
# e.g. during [t_1, t_2], there are n streams running. The throughput for the
# i_{th} throughput is a function of time -- f_i(t).
# The aggregate throughput is defined by f(t) = f_1(t) + ... + f_n(t).
# The average aggregated throughput is defined by
# AAT=(f(t_1) + f(t_1 + 1) + ... f(t_2)) / (t_2 - t_1)
function run_cmd {

    NOW=`date +%s.%N`
    echo "Starting netperfs at $NOW for $TEST" | tee $TESTLOG

    # i denotes the number of running streams.
    i=0;

    # When i == PAUSE_AT, pause for a period, and at the end of it, collect
    # the AAT of i streams during this period.
    PAUSE_AT=1

    # NUM_STREAMS_FILE is the file to save the best number of stream.
    NUM_STREAMS_FILE="./${TEST_MODE}_num_streams"
    rm -f $NUM_STREAMS_FILE

    THROUGHPUT_ARR=()
    STREAMS_ARR=()

    # Increment the number of streams until the total number hit $MAX_INSTANCES.
    while [ $i -lt $MAX_INSTANCES ]
    do
      # Get the ip of the remote server.
      TARGET=${REMOTE_HOSTS[`expr $i % $NUM_REMOTE_HOSTS`]}
      echo "Starting netperfs on localhost targeting ${TARGET} for $TEST" | tee -a $TESTLOG
      id=`printf "%.5d" $i`
      # Start a new stream and output the interim results to and .out file.

      ($NETPERF -H $TARGET -t TCP_STREAM -l 120 > /dev/null;\
      $NETPERF -H $TARGET $NETPERF_CMD 2>&1 > ./${TEST_MODE}/netperf_${TEST}_${id}_to_${TARGET}.out;\
      $NETPERF -H $TARGET -t TCP_STREAM -l 120 > /dev/null;) &

      # $NETPERF -H $TARGET $NETPERF_CMD 2>&1 > ./${TEST_MODE}/netperf_${TEST}_${id}_to_${TARGET}.out &

      sleep 1

      i=`expr $i + 1`

      if [ $i -eq $PAUSE_AT ]
      then
         until [ $(ls ./${TEST_MODE} | grep ".out" | wc -l) -ge $PAUSE_AT ]
         do
           echo "Waiting, true_started_cnt=$(ls ./${TEST_MODE} | grep ".out" | wc -l)"
           sleep 2
         done

     ###wait for our test duration
         sleep $DURATION

          NOW=`date +%s.%N`
          echo "Pausing for $DURATION seconds at $NOW with $i netperfs running for $TEST" | tee -a $TESTLOG
          sleep $DURATION
          # We increment the number of streams by 2 at each step.
          PAUSE_AT=`expr $PAUSE_AT + 2`
          NOW=`date +%s.%N`
          echo "Resuming at $NOW for $TEST" | tee -a $TESTLOG

          if [ $TEST == "search_best_num_streams" ] && [ -n "$SEARCH_BEST_NUM_STREAMS" ]; then
              # LAST_INTERVAL_OUTPUT contains the avg/min/max aggregated throughout during the last pause period.
              LAST_INTERVAL_OUTPUT=$(./proc_last_interval.py --intervals "$TESTLOG")
              IFS=', ' read -r -a OUTPUT_ARR <<< "$LAST_INTERVAL_OUTPUT"
              # CUR_THROUGHPUT is the AAT during the last pause period.
              CUR_THROUGHPUT=${OUTPUT_ARR[0]}

              re='^[0-9]+([.][0-9]+)?$'
              if ! [[ $CUR_THROUGHPUT =~ $re ]] ; then
                 echo "error: CUR_THROUGHPUT $CUR_THROUGHPUT not a number, exit now" > "get_best_stream_error"
                 break
              fi

              THROUGHPUT_ARR+=( "$CUR_THROUGHPUT" )
              STREAMS_ARR+=( "$i" )

              for (( k=0; k<${#THROUGHPUT_ARR[*]}; k++ ));
              do
                 printf 'k:%s,strm:%s,thrpt:%s; ' $k ${STREAMS_ARR[$k]} ${THROUGHPUT_ARR[$k]}
              done

              if [[ ${#THROUGHPUT_ARR[*]} -ge 3 ]]; then
                export LAST_THREE_THROUGHPUT=( ${THROUGHPUT_ARR[*]:${#THROUGHPUT_ARR[*]}-3} )
                echo "last three throughput=${LAST_THREE_THROUGHPUT[*]}"
                # Don't quota ${LAST_THREE_THROUGHPUT[*]}
                # Get the std of the latest 3 AATs.
                STD_LAST_3_THRPT=$( python3 ./calc_std.py ${LAST_THREE_THROUGHPUT[*]} )
                echo "STD_LAST_3_THRPT=$STD_LAST_3_THRPT"

                THRESHOLD=0.35

                # If the throughput results converge or the number of streams reach the limit, we
                # save the BEST_NUM_STREAMS and break the while loop.
                if (( $(echo "$STD_LAST_3_THRPT<$THRESHOLD" | bc -l) )) || [ $PAUSE_AT -gt $MAX_INSTANCES ]; then
                    BEST_NUM_STREAMS=${STREAMS_ARR[${#STREAMS_ARR[*]}-3]}
                    echo "Got the best number of streams: $BEST_NUM_STREAMS"
                    echo $BEST_NUM_STREAMS>$NUM_STREAMS_FILE
                    chmod 777 $NUM_STREAMS_FILE
                    break
                else
                    echo "stop adding new streams until STD_LAST_3_THRPT < $THRESHOLD"
                fi
              fi
          fi
      fi
    done

#    if [[  $i -ge $MAX_INSTANCES ]]; then
#      BEST_NUM_STREAMS=${STREAMS_ARR[${#STREAMS_ARR[*]}-3]}
#      echo "Got the best number of streams: $BEST_NUM_STREAMS"
#      echo $BEST_NUM_STREAMS>$NUM_STREAMS_FILE
#      chmod 777 $NUM_STREAMS_FILE
#    fi

    NOW=`date +%s.%N`
    echo "Netperfs started by $NOW for $TEST" | tee -a $TESTLOG

    sleep 3

    # Stop all the netperfs.
    NOW=`date +%s.%N`
    echo "Netperfs stopping $NOW for $TEST" | tee -a $TESTLOG
    kill_netperfs

    NOW=`date +%s.%N`
    echo "Netperfs stopped $NOW for $TEST" | tee -a $TESTLOG

}

# very much like run_cmd, but it runs the tests one at a time rather
# than in parallel.  We keep the same logging strings to be compatible
# (hopefully) with the post processing script, even though they don't
# make all that much sense :)
function run_cmd_serial {

    NOW=`date +%s.%N`
    echo "Starting netperfs at $NOW for $TEST" | tee $TESTLOG
    i=0;

# the starting point for our load level pauses
    PAUSE_AT=1


    while [ $i -lt $NUM_REMOTE_HOSTS ]
    do
	TARGET=${REMOTE_HOSTS[`expr $i % $NUM_REMOTE_HOSTS`]}
	echo "Starting netperfs on localhost targeting ${TARGET} for $TEST" | tee -a $TESTLOG
	id=`printf "%.5d" $i`
	$NETPERF -H $TARGET $NETPERF_CMD 2>&1 > ./${TEST_MODE}/netperf_${TEST}_${id}_to_${TARGET}.out &

    # give it a moment to get going
	sleep 1

	i=`expr $i + 1`

	NOW=`date +%s.%N`
	echo "Pausing for $DURATION seconds at $NOW with $i netperfs running for $TEST" | tee -a $TESTLOG
	# the plus two is to make sure we have a full set of interim
	# results.  probably not necessary here but we want to be
	# certain
	sleep `expr $DURATION + 1`
	kill_netperfs
	NOW=`date +%s.%N`
	THEN=`echo $NOW | awk -F "." '{printf("%d.%d",$1-1,$2)}'`
	echo "Resuming at $THEN for $TEST" | tee -a $TESTLOG

    done

    NOW=`date +%s.%N`
    echo "Netperfs started by $NOW for $TEST" | tee -a $TESTLOG

# stop all the netperfs - of course actually they have all been
# stopped already, we just want the log entries
    NOW=`date +%s.%N`
    echo "Netperfs stopping $NOW for $TEST" | tee -a $TESTLOG
    kill_netperfs
    NOW=`date +%s.%N`
    echo "Netperfs stopped $NOW for $TEST" | tee -a $TESTLOG
}

# run_cmd_no_echelon is to start multiple streams for the TCP_STREAM test for
# a given duration. At the end of this period, it plots the aggregate throughput
# time series to a svg file, and outputs its min/avg/max.
function run_cmd_no_echelon {
    echo "********** start multistream_netperf.sh $(date +"%m/%d/%Y %T")************"
    echo "NUMBER_OF_STREAM=$1"
    echo "DURATION=$DURATION"
    i=0;

# the starting point for our load level pauses
    PAUSE_AT=$1

    if [[ -z $PAUSE_AT ]] || [[ $PAUSE_AT -lt 1 ]]; then
      echo "run_cmd_no_echelon must specify a positive number of streams"
    fi

    echo "Entering run_cmd_no_echelon at $(date +%s.%N)" | tee $TESTLOG

    while [ $i -lt $PAUSE_AT ]
    do
      TARGET=${REMOTE_HOSTS[`expr $i % $NUM_REMOTE_HOSTS`]}
      #echo "Starting netperfs on localhost targeting ${TARGET} for $TEST" | tee -a $TESTLOG
      id=`printf "%.5d" $i`
      # To avoid skew error, we have each of the streams of tests to actually
      # be three sequential runs of netperf, with the length of the first and
      # last of each long enough to be longer than any skew, and their results
      # ignored.
      ($NETPERF -H $TARGET -t TCP_STREAM -l 120 > /dev/null;\
      $NETPERF -H $TARGET $NETPERF_CMD 2>&1 > ./${TEST_MODE}/netperf_${TEST}_${id}_to_${TARGET}.out;\
      $NETPERF -H $TARGET -t TCP_STREAM -l 120 > /dev/null;) &

      i=`expr $i + 1`

      if [ $i  -eq $PAUSE_AT ]
      then
          NOW=`date +%s.%N`
          echo "Pausing for `expr $DURATION + 2 \* 120` seconds at $NOW with $i netperfs running for $TEST" | tee -a $TESTLOG
      fi
    done

    until [ $(ls ./${TEST_MODE} | grep ".out" | wc -l) -ge $PAUSE_AT ]
    do
      echo "Waiting, true_started_cnt=$(ls ./${TEST_MODE} | grep ".out" | wc -l)"
      sleep 2
    done

    echo "Starting netperfs at $(date +%s.%N) for $TEST" | tee $TESTLOG;
    echo "Number of streams: $PAUSE_AT" | tee -a $TESTLOG
    echo "Netperfs started by $(date +%s.%N) for $TEST" | tee -a $TESTLOG

###wait for our test duration
    sleep $DURATION

#kludgey but this sleep should mean that another interim result will be emitted
    sleep 3

# stop all the netperfs that connect to the current remote host
    NOW=`date +%s.%N`
    echo "Netperfs stopping $NOW for $TEST" | tee -a $TESTLOG
    kill_netperfs

    NOW=`date +%s.%N`
    echo "Netperfs stopped $NOW for $TEST" | tee -a $TESTLOG

}

rm ./${TEST_MODE}/*.{log,out,rrd,svg}

# here then is the "main" part

if [ ! -f ./${TEST_MODE}_remote_hosts ]
then
    echo "This script requires a ${TEST_MODE}_remote_hosts file"
    exit -1
fi
. ./${TEST_MODE}_remote_hosts

# how many processors are there on this system
NUM_CPUS=`grep processor /proc/cpuinfo | wc -l`

# the number of netperf instances we will run will be up to 2x the
# number of CPUs
MAX_INSTANCES=`expr $NUM_CPUS \* 3`

# but at least as many as there are entries in remote_hosts
if [ $MAX_INSTANCES -lt $NUM_REMOTE_HOSTS ]
then
    MAX_INSTANCES=$NUM_REMOTE_HOSTS
fi

# allow the netperf binary to be used to be overridden
NETPERF=${NETPERF:="netperf"}

if [ $NUM_REMOTE_HOSTS -lt 2 ]
then
    echo "The list of remote hosts is too short.  There must be at least 2."
    exit -1
fi

# we assume that netservers are already running on all the load generators

DO_STREAM=0;
DO_MAERTS=0;
# NOTE!  The Bidir test depends on being able to set a socket buffer
# size greater than 13 * 64KB or 832 KB or there is a risk of the test
# hanging.  If you are running linux, make certain that
# net.core.[r|w]mem_max are sufficiently large
DO_BIDIR=0;
DO_RRAGG=0;
DO_RR=0;
DO_ANCILLARY=0;

if [ -n "$SEARCH_BEST_NUM_STREAMS" ]; then
  echo "==== getting best stream mode enabled ===="
fi

# UDP_RR for TPC/PPS using single-byte transactions. we do not use
# TCP_RR any longer because any packet losses or other matters
# affecting the congestion window will break our desire that there be
# a one to one correspondence between requests/responses and packets.
if [ $DO_RRAGG -eq 1 ]; then
    BURST=`find_max_burst.sh ${REMOTE_HOSTS[0]}`
    if [ $BURST -eq -1 ]; then
        # use a value that find_max_burst will not have picked
        BURST=9
        echo "find_max_burst.sh returned -1 so picking a burst of $BURST"
    fi
    TEST="tps"
    TESTLOG="netperf_tps.log"
    NETPERF_CMD="-D 0.5 -c -C -f x -P 0 -t omni $LENGTH -v 2 -- -r 1 -b $BURST -e 1 -T udp -u $MY_UUID $OUTPUT"
    run_cmd
fi

# Bidirectional using burst-mode TCP_RR and large request/response size
if [ $DO_BIDIR -eq 1 ]; then
    TEST="bidirectional"
    TESTLOG="netperf_bidirectional.log"
    NETPERF_CMD="-D 0.5 -c -C -f m -P 0 -t omni $LENGTH -v 2 -- -r 64K -s 1M -S 1M -b 12 -u $MY_UUID $OUTPUT"
    run_cmd
fi

# TCP_STREAM aka outbound with a 64K send size
# the netperf command is everything but netperf -H mumble
if [ $DO_STREAM -eq 1 ];then
    TEST="outbound"
    TESTLOG="netperf_outbound.log"
    NETPERF_CMD="-D 0.5 -c -C -f m -P 0 -t omni $LENGTH -v 2 -- -m 64K -u $MY_UUID $OUTPUT"
    run_cmd
fi

if [[ $SEARCH_BEST_NUM_STREAMS -eq 1 ]]; then
  TEST="search_best_num_streams"
  TESTLOG="./${TEST_MODE}/netperf_search_best_num_streams.log"
  NETPERF_CMD="-D 0.5 -c -C $LENGTH -t TCP_STREAM -P 0 -f g -- -u $MY_UUID -b 2 -D -o throughput,throughput_units"
  run_cmd
fi

if [[ -n $DRAW_PLOT ]]; then
  num_streams_file="${TEST_MODE}_num_streams"
  if [[ ! -f "${num_streams_file}" ]]; then
    echo "cannot find ${num_streams_file}"
    exit 1
  fi

  NUMBER_OF_STREAM=$(<$num_streams_file)
  TEST="draw_plot"
  TESTLOG="./${TEST_MODE}/netperf_draw_plot.log"
  NETPERF_CMD="-D 0.5 -c -C $LENGTH -t TCP_STREAM -P 0 -f g -- -u $MY_UUID -b 2 -D -o throughput,throughput_units"
  CURRENT_TIME=$(date +"%D %T")
  run_cmd_no_echelon $NUMBER_OF_STREAM

  set -ex
  ./post_proc.py --intervals --title="$MACHINE_NAME-$CURRENT_TIME" $TESTLOG
  set +ex

  logdir="$HOME/${TEST_MODE}-netperf-results"
  mv ./${TEST_MODE}/*.{svg,log,rrd,out} $logdir
  touch "$logdir/plot_success"
fi

# TCP_MAERTS aka inbound with a 64K send size - why is this one last?
# because presently when I pkill the netperf of a "MAERTS" test, the
# netserver does not behave well and it may not be possible to get it
# to behave well.  but we will still have all the interim results even
# if we don't get the final results, the useful parts of which will be
# the same as the other tests anyway
if [ $DO_MAERTS -eq 1 ]; then
    TEST="inbound"
    TESTLOG="netperf_inbound.log"
    NETPERF_CMD="-D 0.5 -c -C -f m -P 0 -t omni $LENGTH -v 2 -- -m ,64K -u $MY_UUID $OUTPUT"
    run_cmd
fi

# A single-stream of synchronous, no-burst TCP_RR in an "aggregate"
# script?  Yes, because the way the aggregate tests work, while there
# is a way to see what the performance of a single bulk transfer was,
# there is no way to see a basic latency - by the time
# find_max_burst.sh has completed, we are past a burst size of 0
if [ $DO_RR -eq 1 ]; then
    if [ $DURATION -lt 60 ]; then
	DURATION=60
    fi
    TEST="sync_tps"
    TESTLOG="netperf_sync_tps.log"
    NETPERF_CMD="-D 0.5 -c -C -f x -P 0 -t omni $LENGTH -v 2 -- -r 1 -u $MY_UUID $OUTPUT"
    run_cmd_serial
fi


# now some ancillary things which may nor may not work on your platform
if [ $DO_ANCILLARY -eq 1 ];then
    dmidecode 2>&1 > dmidecode.txt
    uname -a 2>&1 > uname.txt
    cat /proc/cpuinfo 2>&1 > cpuinfo.txt
    cat /proc/meminfo 2>&1 > meminfo.txt
    ifconfig -a 2>&1 > ifconfig.txt
    netstat -rn 2>&1 > netstat.txt
    dpkg -l 2>&1 > dpkg.txt
    rpm -qa 2>&1 > rpm.txt
    cat /proc/interrupts 2>&1 > interrupts.txt
    i=0
    while [ $i -lt `expr $NUM_REMOTE_HOSTS - 1` ]
    do
	traceroute ${REMOTE_HOSTS[$i]} > traceroute_${REMOTE_HOSTS[$i]}.txt
	i=`expr $i + 1`
    done
fi

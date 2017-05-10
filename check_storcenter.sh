#!/bin/bash
#################################################################################
# Script:       check_storcenter                                                #
# Author:       Claudio Kuenzler www.claudiokuenzler.com                        #
# Description:  Plugin for Nagios (and forks) to check an EMC/Iomega            #
#               Storcenter device with SNMP (v3).                               #
# License:      GPLv2                                                           #
# History:                                                                      #
# 20111010      Created plugin (types: disk, raid, cpu, mem)                    #
# 20111011      Added info type                                                 #
# 20111013.0    Corrected uptime (but device returns strange value?)            #
# 20111013.1    Corrected uptime (using hrSystemUptime.0 now)                   #
# 20111020      Disk type now doesnt return CRITICAL anymore if disks missing   #
# 20111031      Using vqeU in mem type (if response comes with kB string)       #
# 20140120      Added snmp authentication                                       #
# 20140317      Added temp, fan types (ramonromancastro@gmail.com)              #
# 20150910      Repair mem, cpu types (ramonromancastro@gmail.com)              #
#################################################################################
# Usage:        ./check_storcenter -H host -U user -P password -t type [-w warning] [-c critical]
#################################################################################
help="check_storcenter (c) 2011-2014 Claudio Kuenzler published under GPL license
Usage: ./check_storcenter -H host -U user -P password -t type [-w warning] [-c critical]
Requirements: snmpwalk, tr

Options:	-H hostname
		-U user (to be defined in snmp settings on Storcenter)
		-P password (to be defined in snmp settings on Storcenter)
		-t Type to check, see list below
		-w Warning Threshold (optional)
		-c Critical Threshold (optional)

Types: 		disk -> Checks hard disks for their current status
		raid -> Checks the RAID status
		cpu -> Check current CPU load (thresholds possible)
		mem -> Check current memory (RAM) utilization (thresholds possible)
		info -> Outputs some general information of the device
		temp -> Check current temperature sensors
		fan -> Check current fan sensors"

# Nagios exit codes and PATH
STATE_OK=0              # define the exit code if status is OK
STATE_WARNING=1         # define the exit code if status is Warning
STATE_CRITICAL=2        # define the exit code if status is Critical
STATE_UNKNOWN=3         # define the exit code if status is Unknown
PATH=$PATH:/usr/local/bin:/usr/bin:/bin # Set path

# If the following programs aren't found, we don't launch the plugin
for cmd in snmpwalk tr [
do
 if ! `which ${cmd} 1>/dev/null`
 then
 echo "UNKNOWN: ${cmd} does not exist, please check if command exists and PATH is correct"
 exit ${STATE_UNKNOWN}
 fi
done
#################################################################################
# Check for people who need help - aren't we all nice ;-)
if [ "${1}" = "--help" -o "${#}" = "0" ];
       then
       echo -e "${help}";
       exit 1;
fi
#################################################################################
# Get user-given variables
while getopts "H:U:P:t:w:c:" Input;
do
       case ${Input} in
       H)      host=${OPTARG};;
       U)      user=${OPTARG};;
       P)      password=${OPTARG};;
       t)      type=${OPTARG};;
       w)      warning=${OPTARG};;
       c)      critical=${OPTARG};;
       *)      echo "Wrong option given. Please use options -H for host, -U for SNMP-User, -t for type, -w for warning and -c for critical"
               exit 1
               ;;
       esac
done
#################################################################################
# Newer StorCenter FW versions require a password
if [[ -n $password ]]; then passinfo="-l authnopriv -a MD5 -A $password"
else passinfo=""
fi
#################################################################################
# Let's check that thing
case ${type} in

# Disk Check
disk)   disknames=($(snmpwalk -v 3 -u ${user} ${passinfo} -O vqe ${host} .1.3.6.1.4.1.11369.10.4.3.1.2 | tr ' ' '-'))
        countdisks=${#disknames[*]}
        diskstatus=($(snmpwalk -v 3 -u ${user} ${passinfo} -O vqe ${host} .1.3.6.1.4.1.11369.10.4.3.1.4 | tr '"' ' '))
        diskstatusok=0
        diskstatusforeign=0
        diskstatusfaulted=0
        diskstatusmissing=0
        disknumber=0

        for status in ${diskstatus[@]}
        do
                if [ $status = "NORMAL" ]; then diskstatusok=$((diskstatusok + 1)); fi
                if [ $status = "FOREIGN" ]; then diskstatusforeign=$((diskstatusforeign + 1)); diskproblem[${disknumber}]=${disknames[${disknumber}]}; fi
                if [ $status = "FAULTED" ]; then diskstatusfaulted=$((diskstatusfaulted + 1)); diskproblem[${disknumber}]=${disknames[${disknumber}]}; fi
                if [ $status = "MISSING" ]; then diskstatusmissing=$((diskstatusmissing + 1)); fi
        let disknumber++
        done

        if [ $diskstatusforeign -gt 0 ] || [ $diskstatusfaulted -gt 0 ]
        then echo "DISK CRITICAL - ${#diskproblem[@]} disk(s) failed (${diskproblem[@]})"; exit ${STATE_CRITICAL};
        elif [ $diskstatusmissing -gt 0 ]
        then echo "DISK OK - ${countdisks} disks found, ${diskstatusmissing} disks missing/empty"; exit ${STATE_OK}
        else echo "DISK OK - ${countdisks} disks found, no problems"; exit ${STATE_OK}
        fi
;;

# Fan Check
fan)    fannames=($(snmpwalk -v 3 -u ${user} ${passinfo} -O vqe ${host} .1.3.6.1.4.1.11369.10.6.1.1.2 | tr ' ' '-' | tr '"' ' '))
        countfans=${#fannames[*]}
        fanvalue=($(snmpwalk -v 3 -u ${user} ${passinfo} -O vqe ${host} .1.3.6.1.4.1.11369.10.6.1.1.3 | tr '"' ' '))
        fannumber=0
        fanwarning=0
        fancritical=0
	message=""
	perf=""

        for value in ${fanvalue[@]}
        do
		status="OK"
		perf="'fan_${fannames[${fannumber}]}'=$value $perf"
	        if [ -n "${warning}" ] || [ -n "${critical}" ]
	        then
	                if [ ${value} -ge ${warning} ] && [ ${value} -lt ${critical} ]; then
				status="WARNING"
				let fanwarning++
	                elif [ ${value} -ge ${warning} ] && [ ${value} -ge ${critical} ]; then
				status="CRITICAL"
				let fancritical++
        	        fi
		fi
		message="FAN $status - ${fannames[${fannumber}]}: $value RPM\n$message"
	        let fannumber++
        done
	if [ $fancritical -gt 0 ]; then echo -e "FAN CRITICAL - One or more fans are in critical state\n$message|$perf"; exit ${STATE_CRITICAL}; fi
	if [ $fanwarning -gt 0 ]; then echo -e "FAN WARNING - One or more fans are in warning state\n$message|$perf"; exit ${STATE_CRITICAL}; fi
	echo -e "FAN OK - All fans are ok\n$message|$perf"; exit ${STATE_OK}
;;

# Temp Check
temp)   tempnames=($(snmpwalk -v 3 -u ${user} ${passinfo} -O vqe ${host} .1.3.6.1.4.1.11369.10.6.2.1.2 | tr ' ' '-' | tr '"' ' '))
        tempfans=${#fannames[*]}
        tempvalue=($(snmpwalk -v 3 -u ${user} ${passinfo} -O vqe ${host} .1.3.6.1.4.1.11369.10.6.2.1.3 | tr '"' ' '))
        tempnumber=0
        tempwarning=0
        tempcritical=0
        message=""
        perf=""

        for value in ${tempvalue[@]}
        do
                status="OK"
                perf="'temp_${tempnames[${tempnumber}]}'=$value $perf"
                if [ -n "${warning}" ] || [ -n "${critical}" ]
                then
                        if [ ${value} -ge ${warning} ] && [ ${value} -lt ${critical} ]; then
                                status="WARNING"
                                let tempwarning++
                        elif [ ${value} -ge ${warning} ] && [ ${value} -ge ${critical} ]; then
                                status="CRITICAL"
                                let tempcritical++
                        fi
                fi
                message="TEMP $status - ${tempnames[${tempnumber}]}: $value ยบC\n$message"
                let tempnumber++
        done
        if [ $tempcritical -gt 0 ]; then echo -e "TEMP CRITICAL - One or more temps are in critical state\n$message|$perf"; exit ${STATE_CRITICAL}; fi
        if [ $tempwarning -gt 0 ]; then echo -e "TEMP WARNING - One or more temps are in warning state\n$message|$perf"; exit ${STATE_CRITICAL}; fi
        echo -e "TEMP OK - All temps are ok\n$message|$perf"; exit ${STATE_OK}
;;


# Raid Check
raid)   raidstatus=$(snmpwalk -v 3 -u ${user} ${passinfo} -O vqe ${host} .1.3.6.1.4.1.11369.10.4.1.0 | tr '"' ' ')
        raidtype=$(snmpwalk -v 3 -u ${user} ${passinfo} -O vqe ${host} .1.3.6.1.4.1.11369.10.4.2.0)

        if [ $raidstatus = "REBUILDING" ] || [ $raidstatus = "DEGRADED" ] || [ $raidstatus = "REBUILDFS" ]
        then echo "RAID WARNING - RAID $raidstatus"; exit ${STATE_WARNING}
        elif [ $raidstatus = "FAULTED" ]
        then echo "RAID CRITICAL - RAID $raidstatus"; exit ${STATE_CRITICAL}
        else echo "RAID OK (Raid $raidtype)"; exit ${STATE_OK}
        fi
;;


# Temp Check
cpu)    cpuvalue=($(snmpwalk -v 3 -u ${user} ${passinfo} -O vqe ${host} .1.3.6.1.2.1.25.3.3.1.2 | tr '"' ' '))
        cpunumber=0
        cpuwarning=0
        cpucritical=0
        message=""
        perf=""

        for value in ${cpuvalue[@]}
        do
                status="OK"
                perf="'cpu_${cpunumber}'=$value% $perf"
                if [ -n "${warning}" ] || [ -n "${critical}" ]
                then
                        if [ ${value} -ge ${warning} ] && [ ${value} -lt ${critical} ]; then
                                status="WARNING"
                                let cpuwarning++
                        elif [ ${value} -ge ${warning} ] && [ ${value} -ge ${critical} ]; then
                                status="CRITICAL"
                                let cpucritical++
                        fi
                fi
                message="$status - cpu_${cpunumber}: $value%\n$message"
                let cpunumber++
        done
        if [ $cpucritical -gt 0 ]; then echo -e "CPU CRITICAL - One or more cpus are in critical state\n$message|$perf"; exit ${STATE_CRITICAL}; fi
        if [ $cpuwarning -gt 0 ]; then echo -e "CPU WARNING - One or more cpus are in warning state\n$message|$perf"; exit ${STATE_CRITICAL}; fi
        echo -e "CPU OK - All cpus are ok\n$message|$perf"; exit ${STATE_OK}
;;

# Memory (RAM) usage
mem)    memtotal=$(snmpwalk -v 3 -u ${user} ${passinfo} -O vqeU ${host} .1.3.6.1.2.1.25.2.3.1.5.1)
        memused=$(snmpwalk -v 3 -u ${user} ${passinfo} -O vqeU ${host} .1.3.6.1.2.1.25.2.3.1.6.1)
        memfree=$(( $memtotal - $memused))
        memusedpercent=$(expr $memused \* 100 / $memtotal)
        memtotalperf=$(expr $memtotal \* 1024)
        memfreeperf=$(expr $memfree \* 1024)
        memusedperf=$(expr $memused \* 1024)

        if [ -n "${warning}" ] || [ -n "${critical}" ]
        then
                if [ ${memusedpercent} -ge ${warning} ] && [ ${memusedpercent} -lt ${critical} ]
                then echo "MEMORY WARNING - Current memory usage is at $memusedpercent%|mem_total=$memtotalperf;mem_used=$memusedperf;mem_free=$memfreeperf"; exit ${STATE_WARNING}
                elif [ ${memusedpercent} -ge ${warning} ] && [ ${memusedpercent} -ge ${critical} ]
                then echo "MEMORY CRITICAL - Current memory usage is at $memusedpercent%|mem_total=$memtotalperf;mem_used=$memusedperf;mem_free=$memfreeperf"; exit ${STATE_CRITICAL}
                else echo "MEMORY OK - Current memory usage is at $memusedpercent%|mem_total=$memtotalperf;mem_used=$memusedperf;mem_free=$memfreeperf"; exit ${STATE_OK}
                fi
        else echo "MEMORY OK - Current memory usage is at $memusedpercent%|mem_total=$memtotalperf;mem_used=$memusedperf;mem_free=$memfreeperf"; exit ${STATE_OK}
        fi
;;


# General Information
info)   uptime=$(snmpwalk -v 3 -u ${user} ${passinfo} -O vqt ${host} .1.3.6.1.2.1.25.1.1.0)
        hostname=$(snmpwalk -v 3 -u ${user} ${passinfo} -O vqt ${host} .1.3.6.1.2.1.1.5.0)
        description=$(snmpwalk -v 3 -u ${user} ${passinfo} -O vqt ${host} .1.3.6.1.4.1.11369.10.1.1.0)
        uptimed=$(expr $uptime / 100 / 60 / 60 / 24)

        echo "${hostname} (${description}), Uptime: ${uptime} ($uptimed days)|'uptime'=${uptime}s"; exit ${STATE_OK}
;;

esac

echo "Unknown error"; exit ${STATE_UNKNOWN}

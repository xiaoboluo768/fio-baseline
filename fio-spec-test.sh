#!/bin/bash 

if [ "$EUID" -ne 0 ]; then
    echo "The script must be run as root"
    exit 1
fi

if [ -e "functions" ]; then
    source functions
else
    echo "Dependency file 'functions' not found."
    exit 1
fi

declare -a disks=()
comp_ratio=${comp_ratio:-0}
runtime=${runtime:-0}
declare -a cpus_allowed_list=()
skip_check=${skip_check:-0}

ramp_time=${ramp_time:-60}

usage() {
    echo "Usage: $0 -d \"disk1 disk2 ...\" -t runtime [-c comp_ratio] [-b \"cpus1 cpus2 ...\"] [-f] [-o result_name]"
    echo "Options:"
    echo "  -d  Specify NVMe device names (required, space-separated, e.g. \"nvme0n1 nvme1n1\")"
    echo "  -c  Compression ratio (default: 0)"
    echo "  -t  Runtime duration in seconds (required, must be > 0)"
    echo "  -b  CPU binding ranges (space-separated, must match device count)"
    echo "  -f  Force skip device status check"
    echo "  -o  Specify the name of output directrory (default to timestamp)"
    exit 1
}

while getopts ":d:c:t:b:o:f" opt; do
    case $opt in
        d)
            IFS=' ' read -ra disks <<< "$OPTARG"
            ;;
        c)
            comp_ratio=$OPTARG
            ;;
        t)
            runtime=$OPTARG
            ;;
        b)
            IFS=' ' read -ra cpus_allowed_list <<< "$OPTARG"
            ;;
        f)
            skip_check=1
            echo -e "Warning: Device status will be skipped!"
            ;;
        o)
            output_dir=$OPTARG
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
        :)
            echo "Option -$OPTARG requires an argument" >&2
            usage
            ;;
    esac
done

# Validate parameters
disks_length=${#disks[@]}
cpus_allowed_list_length=${#cpus_allowed_list[@]}

if [ ${disks_length} -eq 0 ] || [ -z ${disks[0]} ]; then
    echo -e "Error: The disks array is empty."
    usage
fi

if [ $runtime -le 0 ]; then
    echo -e "Error: runtime must be larger than 0"
    usage
fi

if [ ${cpus_allowed_list_length} -ne 0 ] && [ ${cpus_allowed_list_length} -ne ${disks_length} ]; then
    echo -e "Error: The length of cpus_allowed_list does not match the length of disks"
    usage
fi

# check device
for ((i=0; i<$disks_length; i++)); do
    ls /dev/${disks[$i]} > /dev/null
    if [ $? != 0 ];then
       echo "Error: Check ${disks[$i]} is not exsit!"
       exit 1
    fi
done
wait

my_dir="$( cd "$( dirname "$0"  )" && pwd  )"
if [ -z ${output_dir} ];then
    timestamp=`date +%Y%m%d_%H%M%S`
    output_dir=${my_dir}/${timestamp}
fi

if [ ! -d "${output_dir}" ]; then mkdir -p ${output_dir}; fi
iostat_dir=${output_dir}/iostat
result_dir=${output_dir}/result
drv_info=${output_dir}/drv_info
mkdir -p ${result_dir}
mkdir -p ${iostat_dir}
mkdir -p ${drv_info}

sys_info_log=${output_dir}/sys_info.log
test_log=${output_dir}/run_test.log
result_csv_log=${result_dir}/result.csv
collect_test_config $test_log "${disks[*]}" $comp_ratio $runtime $ramp_time $skip_check "${cpus_allowed_list[*]}" 
collect_sys_info $sys_info_log

if [ "${comp_ratio}" != "" ]; 
then
    comp_opt_str=" --buffer_compress_chunk=4k --buffer_compress_percentage=${comp_ratio} "
else 
    comp_opt_str=""
fi

# Device status check loop
error_flag=0
for ((i=0; i<$disks_length; i++)); do
    collect_drv_before_info ${disks[$i]}
    
    # if set check, skip status check
    if [[ "${skip_check}" != "1" ]]; then
        check_PCIe_status ${disks[$i]}
        if [ $? -ne 0 ];then
            error_flag=$((error_flag+1))
        fi
    fi
done
wait

if (( $error_flag != 0 )); then
    while true; do
        read -p "Warning: Do you still continue to proceed? (yes/no): " user_input
        
        user_input=$(echo "$user_input" | tr '[:upper:]' '[:lower:]')
        
        case "$user_input" in
            yes|y)
                break
                ;;
            no|n)
                exit 1
                ;;
            *)
                ;;
        esac
    done
fi

# test config
function Run_test(){
    disk=$1
    cpus_allowed_set=$2

    #format
    echo "[`date`] [${disk}] Format Start" >> ${test_log}
    sudo nvme format /dev/${disk} -s 1 > /dev/null
    echo "[`date`] [${disk}] Format End" >> ${test_log}

    #Seq write precondition
    mode="precondition";rw="write";bs=128k;job=1;qd=128;rwmixread=0;loops=1;
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd Start" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_${mode}_${rw}_${bs}_${job}job_QD${qd}.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap \
    --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk \
    --name=${mode}_${rw}_${bs}_${job}job_QD${qd} --rw=${rw} --bs=${bs} --numjobs=${job} --iodepth=${qd} --loops=$loops ${cpus_allowed_set} > ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log
    kill $iostat_pid > /dev/null
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd End" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log $result_csv_log $disk $comp_ratio $mode

    #Seq write 
    mode="perf";rw="write";bs=128k;job=1;qd=128;rwmixread=0;
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd Start" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_${mode}_${rw}_${bs}_${job}job_QD${qd}.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap \
    --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk \
    --name=${mode}_${rw}_${bs}_${job}job_QD${qd} --rw=${rw} --bs=${bs} --numjobs=${job} --iodepth=${qd} --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log
    kill $iostat_pid > /dev/null
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd End" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log $result_csv_log $disk $comp_ratio $mode

    #Seq read 
    mode="perf";rw="read";bs=128k;job=1;qd=128;rwmixread=0;
    echo "[`date`] [${disk}] ${mode} ${bs} ${job}job ${qd}qd Start" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_${mode}_${rw}_${bs}_${job}job_QD${qd}.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap \
    --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk \
    --name=${mode}_${rw}_${bs}_${job}job_QD${qd} --rw=${rw} --bs=${bs} --numjobs=${job} --iodepth=${qd} --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log
    kill $iostat_pid > /dev/null
    echo "[`date`] [${disk}] ${mode} ${bs} ${job}job ${qd}qd End" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log $result_csv_log $disk $comp_ratio $mode

    #Latency Seq write 
    mode="latency";rw="write";bs=4k;job=1;qd=1;rwmixread=0;
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd Start" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_${mode}_${rw}_${bs}_${job}job_QD${qd}.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap \
    --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk \
    --name=${mode}_${rw}_${bs}_${job}job_QD${qd} --rw=${rw} --bs=${bs} --numjobs=${job} --iodepth=${qd} --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log
    kill $iostat_pid > /dev/null
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd End" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log $result_csv_log $disk $comp_ratio $mode

    #Latency Seq read 
    mode="latency";rw="read";bs=4k;job=1;qd=1;rwmixread=0;
    echo "[`date`] [${disk}] ${mode} ${bs} ${job}job ${qd}qd Start" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_${mode}_${rw}_${bs}_${job}job_QD${qd}.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap \
    --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk \
    --name=${mode}_${rw}_${bs}_${job}job_QD${qd} --rw=${rw} --bs=${bs} --numjobs=${job} --iodepth=${qd} --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log
    kill $iostat_pid > /dev/null
    echo "[`date`] [${disk}] ${mode} ${bs} ${job}job ${qd}qd End" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log $result_csv_log $disk $comp_ratio $mode

    #Random write precondition
    mode="precondition";rw="randwrite";bs=4k;job=1;qd=128;rwmixread=0;loops=2;
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd Start" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_${mode}_${rw}_${bs}_${job}job_QD${qd}.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap \
    --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk \
    --name=${mode}_${rw}_${bs}_${job}job_QD${qd} --rw=${rw} --bs=${bs} --numjobs=${job} --iodepth=${qd} --loops=$loops ${cpus_allowed_set} > ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log
    kill $iostat_pid > /dev/null
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd End" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log $result_csv_log $disk $comp_ratio $mode
    
    #Random write
    mode="perf";rw="randwrite";bs=4k;job=4;qd=128;rwmixread=0;
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd Start" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_${mode}_${rw}_${bs}_${job}job_QD${qd}.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap \
    --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk \
    --name=${mode}_${rw}_${bs}_${job}job_QD${qd} --rw=${rw} --bs=${bs} --numjobs=${job} --iodepth=${qd} --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log
    kill $iostat_pid > /dev/null
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd End" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log $result_csv_log $disk $comp_ratio $mode

    #Latency random write
    mode="latency";rw="randwrite";bs=4k;job=1;qd=1;rwmixread=0;
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd Start" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_${mode}_${rw}_${bs}_${job}job_QD${qd}.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap \
    --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk \
    --name=${mode}_${rw}_${bs}_${job}job_QD${qd} --rw=${rw} --bs=${bs} --numjobs=${job} --iodepth=${qd} --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log
    kill $iostat_pid > /dev/null
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd End" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log $result_csv_log $disk $comp_ratio $mode

    #Random mix
    mode="perf";rw="randrw";bs=4k;job=4;qd=128;rwmixread=70;
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd Start" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_${mode}_${rw}_${bs}_${job}job_QD${qd}.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap \
    --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk \
    --name=${mode}_${rw}_${bs}_${job}job_QD${qd} --rw=${rw} --bs=${bs} --numjobs=${job} --iodepth=${qd} --rwmixread=${rwmixread} --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log
    kill $iostat_pid > /dev/null
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd End" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log $result_csv_log $disk $comp_ratio $mode

    #Random read
    mode="perf";rw="randread";bs=4k;job=4;qd=128;rwmixread=0;
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd Start" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_${mode}_${rw}_${bs}_${job}job_QD${qd}.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap \
    --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk \
    --name=${mode}_${rw}_${bs}_${job}job_QD${qd} --rw=${rw} --bs=${bs} --numjobs=${job} --iodepth=${qd} --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log
    kill $iostat_pid > /dev/null
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd End" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log $result_csv_log $disk $comp_ratio $mode

    #Latency random read
    mode="latency";rw="randread";bs=4k;job=1;qd=1;rwmixread=0;
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd Start" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_${mode}_${rw}_${bs}_${job}job_QD${qd}.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap \
    --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk \
    --name=${mode}_${rw}_${bs}_${job}job_QD${qd} --rw=${rw} --bs=${bs} --numjobs=${job} --iodepth=${qd} --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log
    kill $iostat_pid > /dev/null
    echo "[`date`] [${disk}] ${mode} ${rw} ${bs} ${job}job ${qd}qd End" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_${mode}_${rw}_${bs}_${job}job_${qd}qd.log $result_csv_log $disk $comp_ratio $mode

    collect_drv_after_info ${disk}
    echo "[`date`] [${disk}] Test End" >> ${test_log}
}

echo -e "Spec test is running, see ${test_log}"

# main test loop
for ((i=0; i<$disks_length; i++)); do
    if [ ${cpus_allowed_list_length} -eq 0 ]; then
        # no bind core
        Run_test ${disks[$i]} "" &
    else
        # bind core
        Run_test ${disks[$i]} "--cpus_allowed=${cpus_allowed_list[$i]}" &
    fi
done

wait
echo -e "Spec test is done, see result at ${output_dir}"
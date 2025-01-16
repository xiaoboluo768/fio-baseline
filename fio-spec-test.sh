#!/bin/bash 

#========================Setting========================#
# example disks=(nvme0n1 nvme1n1 nvme2n1 nvme3n1)
disks=(nvme0n1)

# set compression
comp_ratio=1

# set runtime
runtime=600

# set ramp_time
ramp_time=60

# set cpus_allowed, the list must match with disks
# example disks=("1-15" "16-31")
cpus_allowed_list=()
#======================Setting End======================#



#=======================================================#
# !!!Do Not Modify Codes Below!!!
#=======================================================#
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

disks_length=${#disks[@]}
cpus_allowed_list_length=${#cpus_allowed_list[@]}

if [ ${disks_length} -eq 0 ] || [ -z ${disks[0]} ]; then
    echo -e "The disks array is empty."
    exit 1
fi

if [ ${cpus_allowed_list_length} -ne 0 ] && [ ${cpus_allowed_list_length} -ne ${disks_length} ]; then
    echo -e "The length of cpus_allowed_list does not match the length of disks"
    exit 1
fi

my_dir="$( cd "$( dirname "$0"  )" && pwd  )"
timestamp=`date +%Y%m%d_%H%M%S`
output_dir=${my_dir}/${timestamp}
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
echo "Disk,IO,BS,QD,Jobs,KIOPS,BW (MB/s),Latency,Unit" > $result_csv_log

collect_sys_info $sys_info_log

if [ "${comp_ratio}" != "" ]; 
then
    comp_opt_str=" --buffer_compress_chunk=4k --buffer_compress_percentage=${comp_ratio} "
else 
    comp_opt_str=""
fi

# test config
function Run_test(){
    disk=$1
    cpus_allowed_set=$2

    #format
    echo "==========[`date`] [0/9] [${disk}] Format Start==========" >> ${test_log}
    sudo nvme format /dev/${disk} -s 1 > /dev/null
    echo "==========[`date`] [0/9] [${disk}] Format End==========" >> ${test_log}

    #Seq write precondition
    echo "==========[`date`] [1/9] [${disk}] Seq write precondition Start==========" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_seq_precondition_iostat_seq_write.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk --name=seq_precondition_128k_j1_q128 --rw=write --bs=128k --numjobs=1 --iodepth=128 --loops=1 ${cpus_allowed_set} > ${result_dir}/${disk}_fio_seq_precondition.log
    kill $iostat_pid > /dev/null
    echo "==========[`date`] [1/9] [${disk}] Seq write precondition End==========" >> ${test_log}

    #Seq write 
    echo "==========[`date`] [2/9] [${disk}] Seq write 128k 1job qd128 Start==========" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_128kB_seq_write_1job_QD128.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk --name=128kB_seq_write_1job_QD128 --rw=write  --bs=128k --numjobs=1 --iodepth=128 --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_seq_write.log
    kill $iostat_pid > /dev/null
    echo "==========[`date`] [2/9] [${disk}] Seq write 128k 1job qd128 End==========" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_seq_write.log $result_csv_log $disk

    #Seq read 
    echo "==========[`date`] [3/9] [${disk}] Seq read 128k 1job qd128 Start==========" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_128kB_seq_read_1job_QD128.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk --name=128kB_seq_read_1job_QD128 --rw=read  --bs=128k --numjobs=1 --iodepth=128 --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_seq_read.log
    kill $iostat_pid > /dev/null
    echo "==========[`date`] [3/9] [${disk}] Seq read 128k 1job qd128 End==========" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_seq_read.log $result_csv_log $disk

    #Random write precondition
    echo "==========[`date`] [4/9] [${disk}] Random write precondition Start==========" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_ran_precondition_iostat_rand_write.log &
    iostat_pid=$!
    sudo fio --ioengine=libaio --direct=1 --norandommap --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk --name=rand_precondition --rw=randwrite --bs=4k --numjobs=1 --iodepth=128 --loops=2 ${cpus_allowed_set} > ${result_dir}/${disk}_fio_random_precondition.log
    kill $iostat_pid > /dev/null
    echo "==========[`date`] [4/9] [${disk}] Random write precondition End==========" >> ${test_log}
    
    #Random write
    echo "==========[`date`] [5/9] [${disk}] Random write 4k 4job qd128 Start==========" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_4kB_random_write_4job_QD128.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk --name=4kB_random_write_4job_QD128 --rw=randwrite --bs=4k --numjobs=4 --iodepth=128 --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_random_write.log
    kill $iostat_pid > /dev/null
    echo "==========[`date`] [5/9] [${disk}] Random write 4k 4job qd128 End==========" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_random_write.log $result_csv_log $disk

    #Random mix
    echo "==========[`date`] [6/9] [${disk}] Random mix 70-30 4k 4job qd128 Start=========="  >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_4kB_random_mix-70-30_4job_QD128.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk --name=4kB_random_mix-70-30_4job_QD128 --rw=randrw --rwmixread=70 --bs=4k --numjobs=4 --iodepth=128 --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_random_mix.log
    kill $iostat_pid > /dev/null
    echo "==========[`date`] [6/9] [${disk}] Random mix 70-30 4k 4job qd128 End==========" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_random_mix.log $result_csv_log $disk

    #Latency write
    echo "==========[`date`] [7/9] [${disk}] Random write 4k 1job qd1 Start==========" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_4kB_random_write_1job_QD1.log &
    iostat_pid=$!
    sudo fio  --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk --name=4kB_random_write_1job_QD1 --rw=randwrite --bs=4k --numjobs=1 --iodepth=1 --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_lat_write.log
    kill $iostat_pid > /dev/null
    echo "==========[`date`] [7/9] [${disk}] Random write 4k 1job qd1 End==========" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_lat_write.log $result_csv_log $disk

    #Random read
    echo "==========[`date`] [8/9] [${disk}] Random read 4k 4job qd128 Start==========" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_4kB_random_read_4job_QD128.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk --name=4kB_random_read_4job_QD128 --rw=randread --bs=4k --numjobs=4 --iodepth=128 --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_random_read.log
    kill $iostat_pid > /dev/null
    echo "==========[`date`] [8/9] [${disk}] Random read 4k 4job qd128 End==========" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_random_read.log $result_csv_log $disk 

    #Latency read
    echo "==========[`date`] [9/9] [${disk}] Random read 4k 1job qd1 Start==========" >> ${test_log}
    iostat -xmdct $disk 1 > ${iostat_dir}/${disk}_iostat_4kB_random_read_1job_QD1.log &
    iostat_pid=$!
    sudo fio --percentile_list=10:20:30:40:50:60:70:80:90:99:99.9:99.99:99.999:99.9999:99.99999:99.999999:99.9999999 --ioengine=libaio --direct=1 --norandommap --randrepeat=0 --log_avg_msec=1000 --group_reporting --buffer_compress_percentage=$comp_ratio --buffer_compress_chunk=4k --filename=/dev/$disk --name=4kB_random_read_1job_QD1 --rw=randread --bs=4k --numjobs=1 --iodepth=1 --ramp_time=$ramp_time --time_based --runtime=$runtime ${cpus_allowed_set} > ${result_dir}/${disk}_lat_read.log
    kill $iostat_pid > /dev/null
    echo "==========[`date`] [9/9] [${disk}] Random read 4k 1job qd1 End==========" >> ${test_log}
    collect_fio_result ${result_dir}/${disk}_lat_read.log $result_csv_log $disk

    echo "==========[`date`] [${disk}] Test End==========" >> ${test_log}
}

echo -e "Spec test is running, see ${test_log}"

# main test loop
for ((i=0; i<$disks_length; i++)); do
    collect_drv_info ${disks[$i]}

    if [ ${cpus_allowed_list_length} -eq 0 ]; then
        # no bind core
        Run_test ${disks[$i]} "" &
    else
        # bind core
        Run_test ${disks[$i]} "--cpus_allowed=${cpus_allowed_list[$i]}" &
    fi
done





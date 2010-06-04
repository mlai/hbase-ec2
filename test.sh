#!/bin/bash

set -x

NUM_SLAVES=${NUM_SLAVES:=5}
NUM_ZOOS=${NUM_ZOOS:=1}
CLIENTS=${CLIENTS:="1 5 10 15"}
MAX_CLIENTS=${MAX_CLIENTS:=15}
TESTS=${TESTS:="randomWrite sequentialWrite randomRead sequentialRead scan"}
RUNS=${RUNS:=`seq 1 10`}

#INIT_PEFLAGS=${INIT_PEFLAGS:="--nomapred"}
INIT_PEFLAGS=${INIT_PEFLAGS:="--nomapred --writeToWAL=false"}
PEFLAGS=${PEFLAGS:=""}

# HBase 0.20.3, Hadoop 0.20.2
#ZOO_AMI=${ZOO_AMI:=ami-df0ee1b6}         # must be i386 (for m1.small)
#MASTER_AMI=${MASTER_AMI:=ami-db0ee1b2}   # must be x86_64 (for c1.xlarge)
#SLAVE_AMI=${SLAVE_AMI:=ami-db0ee1b2}     # must be x86_64 (for c1.xlarge)
#HBASE_VERSION="0.20.3"

# HBase/Hadoop tm-1
#ZOO_AMI=${ZOO_AMI:=ami-a7648ace}         # must be i386 (for m1.small)
#MASTER_AMI=${MASTER_AMI:=ami-89648ae0}   # must be x86_64 (for c1.xlarge)
#SLAVE_AMI=${SLAVE_AMI:=ami-89648e0}     # must be x86_64 (for c1.xlarge)
ZOO_AMI=${ZOO_AMI:=ami-534ca23a}         # must be i386 (for m1.small)
MASTER_AMI=${MASTER_AMI:=ami-054ca26c}   # must be x86_64 (for c1.xlarge)
SLAVE_AMI=${SLAVE_AMI:=ami-054ca26c}     # must be x86_64 (for c1.xlarge)
HBASE_VERSION="0.20-tm-1"

NAME=${NAME:=$HBASE_VERSION}
HBASE_HOME="/usr/local/hbase-$HBASE_VERSION"
#HBASE_HOME="/home/ekoontz/hbase-tm-2"

# need EC2_ROOT_SSH_KEY in the environment
ssh_opts=`echo -q -i "$EC2_ROOT_SSH_KEY" -o StrictHostKeyChecking=no -o ServerAliveInterval=30`

time=`date +%Y%m%d%H%M%N`
CLUSTER=${CLUSTER:="${NAME}-${time}"}
logdir="logs/$CLUSTER"
mkdir -p $logdir
cluster_log="$logdir/cluster.log"
rm -f $cluster_log

msg () {
   echo
   echo "*** $@"
   echo
   return 0
}

for c in $CLIENTS ; do
  for t in $TESTS ; do
    job="$t-$c"
    job_logdir="$logdir/$job"
    mkdir -p $job_logdir
    job_log="$job_logdir/$job.log"

    # launch cluster

    msg "Launching cluster $CLUSTER for job $job" | tee -a $cluster_log 2>&1
    ./bin/init-hbase-cluster-secgroups $CLUSTER | tee -a $cluster_log 2>&1
    n="0"
    while [ "$n" -lt "$NUM_SLAVES" ] ; do
      ZOO_AMI_IMAGE=$ZOO_AMI ./bin/launch-hbase-zookeeper $CLUSTER $NUM_ZOOS | tee -a $cluster_log 2>&1
      AMI_IMAGE=$MASTER_AMI ./bin/launch-hbase-master $CLUSTER $NUM_SLAVES | tee -a $cluster_log 2>&1
      AMI_IMAGE=$MASTER_AMI ./bin/launch-hbase-slaves $CLUSTER $NUM_SLAVES | tee -a $cluster_log 2>&1
      ./bin/hbase-ec2 push $CLUSTER count-slaves.rb
      echo "Waiting for cluster to come up..." | tee -a $cluster_log
      sleep 10
      i=0
# this works for me:
#      n=`./bin/hbase-ec2 "PATH=/usr/local/jdk1.6.0_20/bin:\$PATH /usr/local/jruby/bin/jruby /root/count-slaves.rb" $CLUSTER`
        n=`./bin/hbase-ec2 $HBASE_HOME/bin/hbase $CLUSTER shell count-slaves.rb`
# original version
#      n=`./bin/hbase-ec2 $HBASE_HOME/bin/hbase $CLUSTER shell count-slaves.rb`
      n=`echo $n`
      while [ "$n" -ne "$NUM_SLAVES" ] ; do
        echo "Cluster $CLUSTER is not up yet ($n of $NUM_SLAVES)" | tee -a $cluster_log
        sleep 10 
        n=`./bin/hbase-ec2 $HBASE_HOME/bin/hbase $CLUSTER shell count-slaves.rb`
        n=`echo $n`
        i=`expr $i + 1`
        if [ "$i" -gt "30" ] ; then
          echo "yes" | ./bin/terminate-hbase-cluster $CLUSTER | tee -a $cluster_log 2>&1
          sleep 10
          break
        fi
      done
    done
    msg "Cluster $CLUSTER is up" | tee -a $cluster_log
    sleep 10

    # run randomWrite to warm the cluster
    
    rm -f $job_log
    msg "Initializing $CLUSTER with randomWrite"
    ./bin/hbase-ec2 $HBASE_HOME/bin/hbase $CLUSTER \
      org.apache.hadoop.hbase.PerformanceEvaluation $INIT_PEFLAGS randomWrite $MAX_CLIENTS \
      | tee -a $cluster_log \
      | tee -a $job_log 2>&1

    # run the actual test

    for i in $RUNS ; do
      run_log="$job_logdir/$job-$i.log"
      rm -f $run_log
      msg "Running PE ($t $c) on $CLUSTER, run $i"
      ./bin/hbase-ec2 $HBASE_HOME/bin/hbase $CLUSTER \
        org.apache.hadoop.hbase.PerformanceEvaluation $PEFLAGS $t $c \
        | tee -a $cluster_log \
        | tee -a $job_log \
        | tee -a $run_log 2>&1
    done

    master=`./bin/list-hbase-master $CLUSTER`
    msg "Copying logs from master"
    scp -Cr $ssh_opts "root@$master:/mnt/hadoop/logs/*" $job_logdir | tee -a $job_log 2>&1
    scp -Cr $ssh_opts "root@$master:/mnt/hbase/logs/*" $job_logdir | tee -a $job_log 2>&1

    slaves=`./bin/list-hbase-slaves $CLUSTER`
    msg "Copying logs from slaves"
    for slave in $slaves ; do
      scp -Cr $ssh_opts "root@$slave:/mnt/hadoop/logs/*" $job_logdir | tee -a $job_log 2>&1
      scp -Cr $ssh_opts "root@$slave:/mnt/hbase/logs/*" $job_logdir | tee -a $job_log 2>&1
    done

    zks=`./bin/list-hbase-zookeeper $CLUSTER`
    msg "Copying logs from Zookeepers"
   for zk in $zks ; do
     scp -Cr $ssh_opts "root@$zk:/mnt/hadoop/logs/*" $job_logdir | tee -a $job_log 2>&1
      scp -Cr $ssh_opts "root@$zk:/mnt/hbase/logs/*" $job_logdir | tee -a $job_log 2>&1
    done

    echo "yes" | ./bin/hbase-ec2 terminate-cluster $CLUSTER | tee -a $cluster_log 2>&1

    sleep 10

  done
done

# clean up

./bin/revoke-hbase-cluster-secgroups $job | tee -a $cluster_log 2>&1

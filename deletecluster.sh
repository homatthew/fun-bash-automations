zk_env="corp"
fabric="ltx1"
zk_cluster="gobblin"
jira_prefixes=(
  "gobblin-kafka-streaming-tracking-mho-test-ltx1-holdem-onboarding-mho-test"
  "gobblin-kafka-streaming-tracking-mho-test-ltx1-holdem-mho-test"
  "gobblin-kafka-streaming-tracking-test-rdsr-gse-lowvol-ltx1-holdem-test-1"
  "gobblin-kafka-streaming-tracking-test-ltx1-holdem-test"
  "gobblin-kafka-streaming-tracking-andjiang01-1"
)

if [ $zk_cluster == "shared" ]; then
  super_cluster="sharedSuperCluster"
else
  super_cluster="HelixControllerCluster_${zk_cluster}"
fi

for cluster_name in ${jira_prefixes[@]}
do
  echo "${cluster_name}"
  echo "1. deregister ${cluster_name} in ${zk_cluster} ${zk_env}-${fabric}"
  curl -X DELETE "http://hr-${fabric}.${zk_env}.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${super_cluster}/resources/${cluster_name}"
  sleep 5
  echo "2. Deleting cluster"
  curl -X DELETE "http://hr-${fabric}.${zk_env}.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${cluster_name}"
  # curl -X GET "http://hr-${fabric}.${zk_env}.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${cluster_name}"
done

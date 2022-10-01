# jira_prefixes=(
#   "gobblin-kafka-streaming-tracking-test-ltx1-holdem-onboarding"
#   "gobblin-kafka-streaming-tracking-test-ltx1-holdem-test-2"
#   "gobblin-kafka-streaming-tracking-test-ltx1-holdem-test-1"
# )
zk_cluster="gobblin"
jira_prefixes=(
  # "gobblin-kafka-streaming-tracking-mho-test-ltx1-holdem-mho-test"
  # "gobblin-kafka-streaming-tracking-mho-test-ltx1-holdem-onboarding-mho-test"
  "hello-world"
)

if [ $zk_cluster == "shared" ]; then
  super_cluster="sharedSuperCluster"
else
  super_cluster="HelixControllerCluster_${zk_cluster}"
fi

for cluster_name in ${jira_prefixes[@]}
do
  echo "${cluster_name}"
  echo "1. deregister ${cluster_name}"
  curl -X DELETE "http://hr-ltx1.corp.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${super_cluster}/resources/${cluster_name}"
  sleep 5
  echo "2. Deleting cluster"
  curl -X DELETE "http://hr-ltx1.corp.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${cluster_name}"
  # curl -X GET "http://hr-ltx1.corp.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${cluster_name}"
done

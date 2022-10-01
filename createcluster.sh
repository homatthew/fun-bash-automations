# Script for creating helix clusters on shared or gobblin corp-ltx1 helix clusters
# "shared" or "gobblin"
zk_cluster="gobblin"
clusters_to_create=(
  # e.g. "gobblin-kafka-streaming-tracking-test-ltx1-holdem-test-1"
#  "gobblin-kafka-streaming-tracking-test-rdsr-pool-gse-ltx1-holdem-test-1"
#  "gobblin-kafka-streaming-tracking-test-rdsr-nopool-gse-ltx1-holdem-test-1"
#  "gobblin-kafka-streaming-tracking-test-rdsr-pool-lowvol-ltx1-holdem-test-1"
#  "gobblin-kafka-streaming-tracking-test-rdsr-nopool-lowvol-ltx1-holdem-test-1"
  # "gobblin-kafka-streaming-tracking-test-rdsr-gse-lowvol-ltx1-holdem-test-1"
  # "gobblin-kafka-streaming-tracking-mho-test-ltx1-holdem-test-1"
  # "gobblin-kafka-streaming-tracking-mho-test-ltx1-holdem-onboarding-test"
  "hello-world"
)

if [ $zk_cluster == "shared" ]; then
  super_cluster="sharedSuperCluster"
else
  super_cluster="HelixControllerCluster_${zk_cluster}"
fi

for cluster_name in ${clusters_to_create[@]}
do
  echo "${cluster_name}"
  echo "1. Create ${cluster_name}"
  curl -X PUT "http://hr-ltx1.corp.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${cluster_name}"
  sleep 5
  json=" { \"id\" : \"${cluster_name}\", \"simpleFields\" : { \"allowParticipantAutoJoin\" : \"true\"} } "
  curl -X POST -H "Content-Type: application/json" "hr-ltx1.corp.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${cluster_name}/configs?command=update" -d "${json}"
  echo "2. Register ${cluster_name}"
  curl -X POST "http://hr-ltx1.corp.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${cluster_name}?command=activate&superCluster=${super_cluster}"
  curl "hr-ltx1.corp.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${cluster_name}/configs"
done

# Script for creating helix clusters on shared or gobblin ${zk_env}-ltx1 helix clusters
# "shared" or "gobblin"
zk_cluster="gobblin"
zk_env="corp"
zk_fabric="ltx1"
clusters_to_create=(
  "gobblin-kafka-streaming-tracking-test-kfketl2-wlo-ltx1-holdem-test-1"
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
  curl -X PUT "http://hr-${zk_fabric}.${zk_env}.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${cluster_name}"
  sleep 5
  json=" { \"id\" : \"${cluster_name}\", \"simpleFields\" : { \"allowParticipantAutoJoin\" : \"true\"} } "
  curl -X POST -H "Content-Type: application/json" "hr-${zk_fabric}.${zk_env}.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${cluster_name}/configs?command=update" -d "${json}"
  echo "2. Register ${cluster_name} in ${zk_cluster} ${zk_env}-${zk_fabric}"
  curl -X POST "http://hr-${zk_fabric}.${zk_env}.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${cluster_name}?command=activate&superCluster=${super_cluster}"
  curl "hr-${zk_fabric}.${zk_env}.linkedin.com:12954/admin/v2/namespaces/${zk_cluster}/clusters/${cluster_name}/configs"
done

clusters_to_create=(
  "gobblin-kafka-streaming-tracking-ltx1-holdem-onboarding"
  # "gobblin-kafka-streaming-tracking-ltx1-holdem-1"
)

for cluster_name in ${clusters_to_create[@]}
do
  echo "1. Deleting offline helix instances for: ${cluster_name}"
  curl -X POST "http://hr-ltx1.corp.linkedin.com:12954/admin/v2/namespaces/shared/clusters/${cluster_name}?command=purgeOfflineParticipants&duration=0"
done
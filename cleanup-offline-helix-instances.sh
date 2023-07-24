clusters_to_clean=(
  "gobblin-kafka-streaming-service-ltx1-holdem-medvol"
  # "gobblin-kafka-streaming-tracking-mho-test-ltx1-holdem-onboarding"
  # "gobblin-kafka-streaming-tracking-ltx1-holdem-1"
)

# https://iwww.corp.linkedin.com/wiki/cf/pages/viewpage.action?spaceKey=ENGS&title=Helix+REST+2.0+User+Manual
endpoint="hr-ltx1.corp.linkedin.com:12954/admin/v2/namespaces/gobblin"

for cluster_name in ${clusters_to_clean[@]}
do
  echo "1. Deleting offline helix instances for: ${cluster_name}"
  curl -X POST "http://${endpoint}/clusters/${cluster_name}?command=purgeOfflineParticipants&duration=0"
done

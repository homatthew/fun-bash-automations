workflows_to_delete=(
"job_KafkaHdfsStreamingServiceOrcMedVol0_1686619812459"
"job_KafkaHdfsStreamingServiceOrcMedVol1_1686605899482"
"job_KafkaHdfsStreamingServiceOrcMedVol2_1686605956690"
"job_KafkaHdfsStreamingServiceOrcMedVol3_1686606016716"
"job_KafkaHdfsStreamingServiceOrcMedVol5_1686619876518"
"job_KafkaHdfsStreamingServiceOrcMedVol6LongRetention_1686619829548"
"job_KafkaHdfsStreamingServiceOrcMedVolHighMem_1686608000545"
"job_KafkaHdfsStreamingServiceOrcMedVolLongRetention_1686607876510"
)
cluster_name="gobblin-kafka-streaming-service-ltx1-holdem-medvol"

# https://iwww.corp.linkedin.com/wiki/cf/pages/viewpage.action?spaceKey=ENGS&title=Helix+REST+2.0+User+Manual
endpoint="hr-ltx1.corp.linkedin.com:12954/admin/v2/namespaces/gobblin"

for workflow in ${workflows_to_delete[@]}
do
  echo "1. Deleting workflows for: ${cluster_name} ${workflow}"
  curl -X DELETE "http://${endpoint}/clusters/${cluster_name}/workflows/${workflow}"
  sleep 5
done

curl -X GET "http://${endpoint}/clusters/${cluster_name}/workflows"

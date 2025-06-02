#!/bin/zsh

# A shell script to start the mesh proxy for cline
# Modified to take arguments to restart the server
#
# Original script created by Mike Czarnota
# See: https://github.netflix.net/gist/mczarnota/b229667bdaecb1cf93b46bfb5aeceb34

ROOT_DIR="/Users/matthewho/repos/fun-bash-automations/cline"
SCRIPT_LOCATION="$ROOT_DIR/start_mesh_proxy_for_cline.sh"
FLAG_FILE="$ROOT_DIR/start_mesh_proxy_for_cline_run"
CONFIG_FILE="$ROOT_DIR/proxy-config.yaml"
RESTART_MODE=false


# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --restart|-r)
      RESTART_MODE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--restart|-r]"
      exit 1
      ;;
  esac
done

# Function to restart the mesh proxy
restart_mesh_proxy() {
  echo "Restarting mesh proxy..."

  # Stop running newt mesh process if exists
  if pgrep -f "newt --app-type mesh" > /dev/null; then
    echo "Stopping existing newt mesh process..."
    pkill -f "newt --app-type mesh"
    sleep 2
  fi

  # Remove config and flag files
  if [ -f "$CONFIG_FILE" ]; then
    echo "Removing existing config file..."
    rm -f "$CONFIG_FILE"
  fi

  if [ -f "$FLAG_FILE" ]; then
    echo "Removing flag file..."
    rm -f "$FLAG_FILE"
  fi

  echo "Cleanup complete, ready to restart."
}
check_already_run() {
  if [ -f "$FLAG_FILE" ]; then
    echo "$SCRIPT_LOCATION has already run. Exiting."
    exit 0
  fi
}

is_metatron_connected() {
  RESPONSE=$(metatron whoami 2>&1)
  if [[ $RESPONSE == *"username"* ]]; then
    echo "Connected to VPN: $RESPONSE"
    return 0
  else
    return 1
  fi
}

wait_for_metatron() {
  echo "Waiting for Metatron to be connected..."
  until is_metatron_connected; do
    printf "."
    sleep 1
  done
}

wait_for_docker() {
  echo "Checking if Docker is running..."
  while [[ -z "$(! docker stats --no-stream 2> /dev/null)" ]]; do
    printf "."
    sleep 1
  done
  echo "Docker is running."
}

# Function to create proxy configuration
create_proxy_config() {
  cat << EOF > "$CONFIG_FILE"
# yaml-language-server: $schema=http://snweb.test.netflix.net/files/MeshRoot.json
apiVersion: "v1"
spec:
  meshServers:
    - name: model-gateway
      config:
        localTargets:
          - name: lo_egress
            httpWorkload:
              port: 2002
              requestTimeoutMs: 0
        listeners:
        - name: strip_auth
          port: 7002
          handlers:
            - http:
                security:
                  plaintext: {}
                headers:
                  requestHeadersToRemove:
                    - "Authorization"
                defaultRoute:
                  localTargetName: lo_egress
EOF
}

if [ "$RESTART_MODE" = true ]; then
  restart_mesh_proxy
else
  check_already_run
fi

echo "$SCRIPT_LOCATION started at $(date)"
wait_for_metatron

wait_for_docker

create_proxy_config

newt --app-type mesh start -e prod -s "$CONFIG_FILE"

echo "$SCRIPT_LOCATION finished at $(date)"

touch "$FLAG_FILE"
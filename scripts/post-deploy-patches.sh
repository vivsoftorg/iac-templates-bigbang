#!/bin/bash

set -eu -o pipefail

GRAFANA_CONFIG=$(kubectl --namespace monitoring get configmaps monitoring-monitoring-grafana -o jsonpath="{.data.grafana\.ini}")

if ! grep -q "allow_embedding" <<< "${GRAFANA_CONFIG}"; then
    echo "patching grafana config to allow iframe embedding"

    GRAFANA_CONFIG+=$'\n[security]\nallow_embedding = true'
    GRAFANA_CONFIG_JSON_ENCODED=$(jq -R -s -c 'split("\n")' <<< "${GRAFANA_CONFIG}" | jq -r '. | join("\\n")')

    kubectl --namespace monitoring patch configmap monitoring-monitoring-grafana  -p "{\"data\": { \"grafana.ini\": \"${GRAFANA_CONFIG_JSON_ENCODED}\" } }"
    kubectl --namespace monitoring get configmaps monitoring-monitoring-grafana -o jsonpath="{.data.grafana\.ini}"
    kubectl --namespace monitoring delete pod "$(kubectl --namespace monitoring get pods -l="app.kubernetes.io/name=grafana" -o jsonpath="{.items.*.metadata.name}")"
    kubectl --namespace monitoring rollout status deployment monitoring-monitoring-grafana
fi

ELASTIC_PASSWORD=$(kubectl --namespace logging get secrets logging-ek-es-elastic-user -o jsonpath="{.data.elastic}" | base64 -d)

cat << EOF > nginx.conf
server {
    listen 8080;
    server_name localhost;

    location / {
        proxy_set_header Authorization "Basic $(echo -n "elastic:${ELASTIC_PASSWORD}" | base64 -w 0)";
        proxy_set_header HOST \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass_request_headers on;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_pass http://logging-ek-kb-http:5601/;
    }
}
EOF

kubectl --namespace logging get secret nginx-config || kubectl --namespace logging create secret generic nginx-config --from-file=default.conf=nginx.conf

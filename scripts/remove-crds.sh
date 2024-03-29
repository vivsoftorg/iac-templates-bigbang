#! /bin/bash

#Istio
for i in authorizationpolicies.security.istio.io destinationrules.networking.istio.io envoyfilters.networking.istio.io gateways.networking.istio.io istiooperators.install.istio.io peerauthentications.security.istio.io proxyconfigs.networking.istio.io requestauthentications.security.istio.io serviceentries.networking.istio.io sidecars.networking.istio.io telemetries.telemetry.istio.io virtualservices.networking.istio.io wasmplugins.extensions.istio.io workloadentries.networking.istio.io workloadgroups.networking.istio.io; do
    echo $i
    kubectl delete crd $i
done

# Gatekeeper
for i in assign.mutations.gatekeeper.sh assignmetadata.mutations.gatekeeper.sh configs.config.gatekeeper.sh constraintpodstatuses.status.gatekeeper.sh constrainttemplatepodstatuses.status.gatekeeper.sh constrainttemplates.templates.gatekeeper.sh expansiontemplate.expansion.gatekeeper.sh modifyset.mutations.gatekeeper.sh mutatorpodstatuses.status.gatekeeper.sh providers.externaldata.gatekeeper.sh; do
    echo $i
    kubectl delete crd $i
done


# jaegers kialis
kubectl delete crd jaegers.jaegertracing.io  kialis.kiali.io

# Kyverno
kubectl delete crd admissionreports.kyverno.io backgroundscanreports.kyverno.io cleanuppolicies.kyverno.io clusteradmissionreports.kyverno.io clusterbackgroundscanreports.kyverno.io clustercleanuppolicies.kyverno.io clusterpolicies.kyverno.io policies.kyverno.io policyexceptions.kyverno.io updaterequests.kyverno.io

# Grafana
delete crd clusterpolicyreports.wgpolicyk8s.io grafanaagents.monitoring.grafana.com integrations.monitoring.grafana.com logsinstances.monitoring.grafana.com metricsinstances.monitoring.grafana.com podlogs.monitoring.grafana.com policyreports.wgpolicyk8s.io
# webhooks
kubectl delete validatingwebhookconfigurations istiod-default-validator istio-validator-istio-system gatekeeper-validating-webhook-configuration
kubectl delete mutatingwebhookconfigurations istio-sidecar-injector

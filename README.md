# BigBang

The BigBang module deploys standard BigBang components on top of an existing Kubernetes cluster.
The BigBang Chart version being used is 1.24.0


## Mandatory Components

* Flux CD for GitOps
* EFK for logging
* Istio as service mesh
* ClusterAuditor for Kubernetes cluster auditing
* Prometheus & Grafana for monitoring
* Open Policy Agent as Gatekeeper 
* Twistlock for vulnerability scanning

## Optional components

* ArgoCD
* Authservice

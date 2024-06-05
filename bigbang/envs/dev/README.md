# AirGap environment

Create the `HelmRepository`  pointing to your local `oci` repository, like below , same is added [here](helmrepo.yaml)

Make sure to change the `url`

```
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: registry1
  namespace: bigbang
spec:
  interval: 2m
  type: oci
  url: oci://44.210.192.97:5000/bigbang
  insecure: true
```
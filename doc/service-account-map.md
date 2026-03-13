aws eks create-pod-identity-association \
  --cluster-name enbuild-eks \
  --namespace flux-system \
  --service-account kustomize-controller \
  --role-arn arn:aws:iam::986602297069:role/eks_managed_node-eks-node-group-20260311162624183200000005



  with flux ustomize-controller version v1.7.3

  Sops decrypt not working, so had to increase hop limit

  aws ec2 modify-instance-metadata-options   --instance-id i-0997a0c3f16ec3df9   --http-put-response-hop-limit 2

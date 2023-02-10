# Following Files are differeent in GH Template vs Gitlab

- bigbang/envs/dev/bigbang-deploy.yaml 
For this change the Chart repository , make a note that Github Chart repo needs to be synced manully 
- All the files in `envs/dev/values` since we have to change the Helm chart Repositories to Github 
For this set the following env vars and then run the `bigbang-template-upgrade-enbuild` process.
```
# Github
export CHART_BASE_REPO=https://github.com/VivSoftOrg
export CHART_BASE_REPO_SSH=git@github.com:VivSoftOrg
```
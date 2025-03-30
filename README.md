# Uncomplicated local cluster setup on k0s

## Requirement
Download the setup tool and the value-template.txt file on the target Debian(ish) server:
```
curl -o ~/local-cluster-setup.sh https://raw.githubusercontent.com/nbaerts/local-cluster/main/setup.sh && chmod 700 ~/local-cluster-setup.sh
curl -o ~/local-cluster-values.txt https://raw.githubusercontent.com/nbaerts/local-cluster/main/value-template.txt
```
Edit the value file `~/local-cluster-value.txt` as per the new local cluster to setup

## Setup the cluster
Execute the following command under root (or sudo root):
```
~/local-cluster-setup.sh -f ./local-cluster-values.txt install
```

## Upgrade the cluster to the latest third parties
Execute the following command under root (or sudo root):
```
~/local-cluster-setup.sh -f ./local-cluster-values.txt upgrade
```

## Uninstall k0s
Execute the following command under root (or sudo root):
```
~/local-cluster-setup.sh uninstall
```
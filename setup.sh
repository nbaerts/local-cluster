#!/bin/bash

function usage {
  [[ $1 != '' ]] && echo "[ERROR] $1"
  echo "Usage: $myBasename [--staging] [-f <valueFile>] install | upgrade | upgradeHelm | upgradeConfig | uninstall"
  echo "         --staging      : Use Let's Encrypt staging certificates to avoid rate limits while testing"
  echo "         -f <valueFile> : Value file containing the config to apply"
  echo "         install        : Install both required packages and k0s node"
  echo "         upgrade        : Upgrade both required packages and k0s node"
  echo "         upgradeHelm    : Upgrade helm charts only [no downtime]"
  echo "         upgradeConfig  : Upgrade the k0s config only [no downtime]"
  echo "         uninstall      : Uninstall k0s"
  echo "Desc.: Setup a k0s cluster with a single node"
  echo
  exit 1
}

function myInfo {
  [[ $1 == '-n' ]] && printf "[INFO] $2" && return 0
  echo "[INFO] $1"
  return 0
}

function myExit {
  echo "[ERROR] $1"
  exit 2
}

function setupSSH {
  mkdir -p ~/.ssh && chmod 700 ~/.ssh || myExit "Unable to create ~/.ssh"
  if [[ $SSH_AUTHORIZED_KEY != '' ]]
  then
    myInfo "Adding ssh authorized key..."
    echo "$SSH_AUTHORIZED_KEY" > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys || myExit "Unable to create ~/.ssh/authorized_keys"
    myInfo "Remove ssh password authentication..."
    sed -i "s/^.*PasswordAuthentication .*$/PasswordAuthentication no/g" /etc/ssh/sshd_config
    sshd -t && systemctl restart sshd || myExit "Unable to restart sshd"
  fi
  return 0
}

function installPackage {
  myInfo "Upgrading the OS..."
  apt update && apt upgrade -y
  myInfo "Installing apt packages..."
  apt install -y ufw dnsmasq net-tools curl git apache2-utils apt-transport-https ca-certificates rclone argon2 || myExit "Unable to install apt packages"
  return 0
}

function setupUfw {
  myInfo "Enable firewall (ufw)..."
  ufw disable
  myPorts="ssh http https"
  [[ $CLUSTER_LOCAL_DNS_SERVERS != '' ]] && myPorts="$myPorts 53/tcp 53/udp"
  for i in $myPorts
  do
    ufw allow $i || myExit "Unable to allow '$i' port"
  done
  ufw -f enable
  return 0
}

function setupDuckdnsIpRefresh {
  [[ $DUCKDNS_TOKEN == '' || $(echo "$CLUSTER_DOMAIN" | grep '.duckdns.org$') == '' ]] && return 0
  mySubDomain=$(echo "$CLUSTER_DOMAIN" | sed 's/.duckdns.org$//')
  myInfo "Adding the refresh of the external IP for the sub-domain '$mySubDomain'..."
  mkdir -p /opt/duckdns || myExit "Unable to create '/opt/duckdns'"
  echo "echo url=\"https://www.duckdns.org/update?domains=${mySubDomain}&token=${DUCKDNS_TOKEN}&ip=\" | curl -k -o /opt/duckdns/duck.log -K -" >/opt/duckdns/duck.sh && chmod 700 /opt/duckdns/duck.sh || myExit "Unable to create '/opt/duckdns/duck.sh'"
  crontab -l | egrep -v -e '^$' -e 'duck.sh' >/opt/duckdns/duck.crontab && printf '*/5 * * * * /opt/duckdns/duck.sh >/dev/null 2>&1\n\n' >>/opt/duckdns/duck.crontab || myExit "Unable to create '/opt/duckdns/duck.crontab'"
  crontab /opt/duckdns/duck.crontab || myExit "Unable to update the crontab"
  return 0
}

function setupBackup {
  [[ $RCLONE_END_POINT == '' ]] && return 0
  myInfo "Adding the backup of the config using rclone..."
  mkdir -p /opt/backup/local-cluster || myExit "Unable to create '/opt/backup/local-cluster'"
  myFiles=
  for i in $CLUSTER_APPS
  do
    myFiles="$myFiles /opt/$i/config"
  done
  cat >/opt/backup/local-cluster.sh << EOF
myTar="/opt/backup/local-cluster/local-cluster.\$(date '+%Y-%m-%d').tar"
echo "INFO: Backuping [\$myTar]..."
tar --exclude='/opt/*/config/metadata' --exclude='/opt/*/config/Backups' --exclude='/opt/*/config/logs' -cvf \$myTar $myFiles && gzip \$myTar || exit 2
echo "INFO: Keeping the last 3 backups only..."
ls -tp | grep -v '/$' | tail -n +4 | xargs -I {} rm -- {}
echo "INFO: Pushing backup with rclone..."
rclone mkdir $RCLONE_END_POINT:local-cluster && rclone -v sync /opt/backup/local-cluster $RCLONE_END_POINT:local-cluster >/opt/backup/local-cluster.log 2>&1 || exit 2
exit 0
EOF
  [[ $? -ne 0 ]] && myExit "Not able to create '/opt/backup/local-cluster.sh'"
  chmod 755 /opt/backup/local-cluster.sh || myExit "Not able to chmod '/opt/backup/local-cluster.sh'"
  crontab -l | egrep -v -e '^$' -e 'local-cluster.sh' >/opt/backup/local-cluster.crontab && printf '0 2 * * * /opt/backup/local-cluster.sh >/opt/backup/local-cluster.log 2>&1\n\n' >>/opt/backup/local-cluster.crontab || myExit "Unable to create '/opt/backup/local-cluster.crontab'"
  crontab /opt/backup/local-cluster.crontab || myExit "Unable to update the crontab"
  return 0
}

function setupLocalDns {
  #TODO: To replace by Pi-hole [https://install.pi-hole.net]?
  [[ $CLUSTER_LOCAL_DNS_SERVERS == '' ]] && return 0
  if [[ $(grep "^address=.*$CLUSTER_DOMAIN" /etc/dnsmasq.conf) == '' ]]
  then
    myInfo "Adding '$myIp' address for '$CLUSTER_DOMAIN'..."
    echo "address=/$CLUSTER_DOMAIN/$myIp" >>/etc/dnsmasq.conf || myExit "Unable to add '$myIp' address for '$CLUSTER_DOMAIN'"
  fi
  for i in $CLUSTER_LOCAL_DNS_SERVERS
  do
    [[ $(grep "^server=$i" /etc/dnsmasq.conf) != '' ]] && continue
    myInfo "Adding DNS server '$i'..."
    echo "server=$i" >>/etc/dnsmasq.conf || myExit "Unable to add server '$i'"
  done
  systemctl restart dnsmasq || myExit "Unable to restart dnsmasq"
  return 0
}

function installClusterTools {
  myInfo "Installing helm..."
  curl -o ~/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod 700 ~/get_helm.sh || myExit "Unable to download get_helm.sh"
  ~/get_helm.sh && rm -f ~/get_helm.sh || myExit "Unable to get helm"
  helm version || myExit "Helm not well installed"

  myInfo "Installing kubectl..."
  curl -o ~/kubectl -L "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" || myExit "Unable to download kubectl"
  install -o root -g root -m 0755 ~/kubectl /usr/local/bin/kubectl && rm -f ~/kubectl || myExit "Unable to move kubectl into '/usr/local/bin/'"
  kubectl version --client || myExit "kubectl not well installed"
  return 0
}

function stopNode {
  [[ ! -f /usr/local/bin/k0s ]] && return 0
  myInfo "Stoping the k0s node..."
  k0s stop
  return 0
}

function installK0s {
  myInfo "Installing k0s..."
  curl -sSLf https://get.k0s.sh | sh || myExit "Unable to install k0s"
  k0s version || myExit "k0s not well installed"
  return 0
}

function createDirs {
  mkdir -p /opt/media/ && chown local-cluster:local-cluster /opt/media || myExit "Unable to create '/opt/media'"
  for i in $CLUSTER_APPS
  do
    mkdir -p /opt/$i/config && chown local-cluster:local-cluster /opt/$i /opt/$i/config || myExit "Unable to create '/opt/$i/config'"
  done
  return 0
}

function resetNode {
  myInfo "Reseting the k0s node..."
  k0s reset 2>/dev/null
  return 0
}

function createNodeConfig {
  myInfo "Creating the new node config..."
  k0s config create > ~/local-cluster-k0s.yaml || myExit "Unable to generate the k0s config"
  sed -n '0,/helm:/p' ~/local-cluster-k0s.yaml >~/local-cluster-k0s.new.yaml || myExit "Unable to create the new k0s config"
  cat >>~/local-cluster-k0s.new.yaml << EOF
      repositories:
      - name: jetstack
        url: https://charts.jetstack.io
      - name: nbaerts
        url: https://nbaerts.github.io/helm-repo
      - name: kubernetes-dashboard
        url: https://kubernetes.github.io/dashboard/
      charts:
      - name: nginx-controler
        chartname: nbaerts/nginx-controler
        namespace: ingress-nginx
        order: 1
      - name: cert-manager
        chartname: jetstack/cert-manager
        namespace: cert-manager
        order: 2
        values: |
          installCRDs: true
      - name: cluster-issuer
        chartname: nbaerts/cluster-issuer
        namespace: cert-manager
        order: 3
        values: |
          global:
            email: $CLUSTER_EMAIL
EOF
  [[ $? -ne 0 ]] && myExit "Unable to add the default helm charts in the new k0s config"
  if [[ $(echo " $CLUSTER_APPS " | grep ' dashboard ') != '' ]]
  then
    cat >>~/local-cluster-k0s.new.yaml << EOF
      - name: dashboard
        chartname: kubernetes-dashboard/kubernetes-dashboard
        namespace: dashboard
        order: 4
        values: |
          app:
            ingress:
              enabled: true
              ingressClassName: nginx
              issuer:
                scope: cluster
                name: $myCertIssuer
              hosts:
                - dashboard.$CLUSTER_DOMAIN
              tls:
                secretName: dashboard-tls
EOF
  fi
  for i in $CLUSTER_APPS
  do
    [[ $i == 'dashboard' ]] && continue
    cat >>~/local-cluster-k0s.new.yaml << EOF
      - name: $i
        chartname: nbaerts/$i
        namespace: $i
        order: 4
        values: |
          global:
            host: $i.$CLUSTER_DOMAIN
            uid: $myUid
            gid: $myGid
            tz: $CLUSTER_TZ
          ingress:
            clusterIssuer: $myCertIssuer
EOF
    [[ $i == 'vaultwarden' ]] && cat >>~/local-cluster-k0s.new.yaml << EOF
          adminToken: 
            value: $VAULTWARDEN_ADMIN_TOKEN
          smtp:
            host: $SMTP_HOST
            security: $SMTP_SECURITY
            port: $SMTP_PORT
            from: $CLUSTER_EMAIL
            username:
              value: $SMTP_USERNAME
            password:
              value: $SMTP_PASSWORD
            authMechanism: $SMTP_AUTHMECHANISM
EOF
  done
  sed -n '/concurrencyLevel:/,$p' ~/local-cluster-k0s.yaml >>~/local-cluster-k0s.new.yaml || myExit "Unable to tail the new k0s config"
  mv ~/local-cluster-k0s.new.yaml ~/local-cluster-k0s.yaml || myExit "Unable to rename '~/local-cluster-k0s.new.yaml'"
  return 0
}

function installControler {
  myInfo "Installing k0s controller..."
  k0s install controller --single --enable-dynamic-config -c ~/local-cluster-k0s.yaml || myExit "Unable to install the new single k0s node"
  systemctl daemon-reload || myExit "Unable to reload"
  return 0
}

function waitForHelm {
  myInfo -n "Waiting for the $1 deployment"
  let i=24
  while [[ $i -gt 0 ]]
  do
    printf '.'
    let i=$i-1
    [[ $(helm list --all-namespaces | grep "^$1.*deployed") != '' ]] && break
    sleep 5
  done
  printf '\n'
  [[ $(helm list --all-namespaces | grep "^$1.*deployed") == '' ]] && myExit "$1 not yet ready [$(helm -n $1 list)]"
  return 0
}

function startNode {
  myInfo "Starting k0s..."
  k0s start || myExit "Unable to start k0s"

  myInfo -n "Waiting for the node"
  sleep 10
  let i=24
  while [[ $i -gt 0 ]]
  do
    printf '.'
    let i=$i-1
    k0s kubectl wait --for=condition=Ready nodes --all --timeout=600s >/dev/null 2>&1 && break
    sleep 5
  done
  printf '\n'
  k0s kubectl wait --for=condition=Ready nodes --all --timeout=600s && k0s status && k0s kubectl get nodes || myExit "The new k0s is not getting ready"
  
  myInfo "Copying the kube.config..."
  mkdir -p ~/.kube && cp /var/lib/k0s/pki/admin.conf ~/.kube/config || myExit "Unable to copy the kube.config"
  return 0
}

function fixCertManager {
  waitForHelm cert-manager
  myInfo "Set cert-manager deployment with 'dnsPolicy: Default'..."
  kubectl -n cert-manager get deployment cert-manager -o yaml > ~/cert-manager-deployment.yaml
  sed -i "s/dnsPolicy:.*$/dnsPolicy: Default/g" ~/cert-manager-deployment.yaml || myExit "Unbale to alter the cert-manager deployment config"
  kubectl apply -f ~/cert-manager-deployment.yaml || myExit "Unable to alter the cert-manager deployment"
  rm -f ~/cert-manager-deployment.yaml
  return 0
}

function createDashboardAccessToken {
  [[ $(echo " $CLUSTER_APPS " | grep ' dashboard ') == '' ]] && return 0
  waitForHelm dashboard
  myInfo "Creating the dashboard admin user..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: dashboard
---
apiVersion: v1
kind: Secret
metadata:
  name: admin-user
  namespace: dashboard
  annotations:
    kubernetes.io/service-account.name: "admin-user"   
type: kubernetes.io/service-account-token
EOF
  [[ $? -ne 0 ]] && myExit "Unable to create the dashboard admin user"
  return 0
}

function getDashboardAccessToken {
  [[ $(echo " $CLUSTER_APPS " | grep ' dashboard ') == '' ]] && return 0
  myInfo "Dashboard access token:"
  kubectl get secret admin-user -n dashboard -o jsonpath="{.data.token}" | base64 -d
  echo
  return 0
}

function removeK0s {
  myInfo "Removing k0s..."
  rm -f /usr/local/bin/k0s || myExit "Unable to remove '/usr/local/bin/k0s'"
  return 0
}

function installCluster {
  myVariables=
  [[ $CLUSTER_DOMAIN == '' ]] && myVariables="$myVariables CLUSTER_DOMAIN"
  [[ $CLUSTER_EMAIL  == '' ]] && myVariables="$myVariables CLUSTER_EMAIL"
  [[ $myVariables != '' ]] && myExit "The variable(s)$myVariables should not be emptied"

  setupSSH
  installPackage
  setupUfw
  setupDuckdnsIpRefresh
  setupBackup
  setupLocalDns
  installClusterTools
  createDirs

  stopNode
  installK0s
  [[ $1 != '--upgrade' ]] && resetNode && createNodeConfig && installControler
  startNode
  fixCertManager
  createDashboardAccessToken
  
  for i in nginx-controler cluster-issuer $CLUSTER_APPS
  do
    waitForHelm $i
  done
  helm list --all-namespaces
  kubectl get certificates --all-namespaces

  if [[ $1 != '--upgrade' ]]
  then
    echo
    myPorts="443 80"
    [[ $CLUSTER_LOCAL_DNS_SERVERS != ''  ]] && myInfo "The local cluster should be set as first DNS"
    myInfo "The ports 80 and 443 should be opened and forwarded to the local cluster"
    [[ $RCLONE_END_POINT != '' && ! -s ~/.config/rclone/rclone.conf ]] && myInfo "rclone should be configured to add the end point '$RCLONE_END_POINT' in order to allow backups [rclone config]"
    for i in $CLUSTER_APPS
    do
      myInfo "  +> https://$i.$CLUSTER_DOMAIN"
    done
    echo
  else
    echo
    myInfo "k0s cluster well upgraded"
    echo
  fi
  getDashboardAccessToken
  echo
  return 0
}

function upgradeHelm {
  helm repo add jetstack https://charts.jetstack.io || myExit "Unable to add the 'jetstack' repo" 
  helm repo add nbaerts  https://nbaerts.github.io/helm-repo  || myExit "Unable to add the 'nbaerts' repo"
  helm repo update
  helm list --all-namespaces --all --no-headers | while read myRelease myNamespace i
  do
    myChart="nbaerts/$myRelease"
    [[ $myRelease == 'cert-manager' ]] && myChart="jetstack/cert-manager"
    myInfo "Upgrading $myRelease [$myChart]..."
    helm upgrade -n $myNamespace --wait $myRelease $myChart || myExit "Unable to upgrade $myRelease [$myChart]"
  done
  fixCertManager

  echo
  helm list --all-namespaces --all
  echo
  myInfo "Helm releases well upgraded"
  echo
  return 0
}

function upgradeConfig {
  myVariables=
  [[ $CLUSTER_DOMAIN == '' ]] && myVariables="$myVariables CLUSTER_DOMAIN"
  [[ $CLUSTER_EMAIL  == '' ]] && myVariables="$myVariables CLUSTER_EMAIL"
  [[ $myVariables != '' ]] && myExit "The variable(s)$myVariables should not be emptied"
  
  createDirs
  createNodeConfig

  myInfo "Applying new dynamic k0s cluster..."
  kubectl apply -f ~/local-cluster-k0s.yaml || myExit "Unable to apply the new dynamic k0s cluster"
  fixCertManager

  echo
  k0s config status
  echo
  myInfo "New k0s config well applied"
  echo
  return 0
}

function uninstallCluster {
  stopNode
  resetNode
  removeK0s

  echo
  myInfo "The server should be rebooted [reboot]"
  echo
  return 0
}

### MAIN
myBasename=$(basename $0)
myIp=$(hostname -I | awk '{print $1}')
[[ $(whoami) != 'root' ]] && usage "Script to be executed under root"

myGid=$(id -g local-cluster)
if [[ $? -ne 0 ]]
then
  adduser --system local-cluster --group || myExit "Unable to create the system user 'local-cluster'"
  myGid=$(id -g local-cluster) || myExit "System group 'local-cluster' not well created"
fi
myUid=$(id -u local-cluster) || myExit "System user 'local-cluster' not well created"

myCertIssuer='letsencrypt-prod'
while [[ $(echo "#$1" | cut -c2) == '-' ]]
do
  case $1 in
    '--staging' ) myCertIssuer='letsencrypt-staging'
                  shift 1;;
    '-f'        ) [[ $2 == '' || ! -s $2 ]] && usage "An non-empty value file should be provided"
                  myInfo "Applying value file '$2'..."
                  . "$2" || myExit "Unable to interpret '$2'"
                  shift 2;;
    *           ) usage "Unknown option '$1'";;
  esac
done

case $1 in
  'install'       ) installCluster;;
  'upgrade'       ) installCluster --upgrade;;
  'upgradeHelm'   ) upgradeHelm;;
  'upgradeConfig' ) upgradeConfig;;
  'uninstall'     ) uninstallCluster;;
  *               ) usage "A valid action should be specified";;
esac
exit 0
 #!/bin/bash
set -x
set -e

###更改这里的IP, 自行确保NTP同步
declare -A NODE_MAP=( ["etcd0"]="192.168.56.100" ["etcd1"]="192.168.56.101" ["etcd2"]="192.168.56.102" )
###只支持部署3个节点etcd集群


etcd::download()
{
    ETCD_VER=v3.0.15
    DOWNLOAD_URL=https://github.com/coreos/etcd/releases/download
    [ -f ${PWD}/temp-etcd/etcd ]  && return
    curl -L ${DOWNLOAD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o ${PWD}/etcd-${ETCD_VER}-linux-amd64.tar.gz
    mkdir -p ${PWD}/temp-etcd && tar xzvf ${PWD}/etcd-${ETCD_VER}-linux-amd64.tar.gz -C ${PWD}/temp-etcd --strip-components=1
}

etcd::config()
{
    local node_index=$1

cat <<EOF >${PWD}/${node_index}.conf
ETCD_NAME=${node_index}
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${NODE_MAP[${node_index}]}:2380"
ETCD_LISTEN_PEER_URLS="http://${NODE_MAP[${node_index}]}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${NODE_MAP[${node_index}]}:2379,http://127.0.0.1:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://${NODE_MAP[${node_index}]}:2379"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster-378"
ETCD_INITIAL_CLUSTER="etcd0=http://${NODE_MAP['etcd0']}:2380,etcd1=http://${NODE_MAP['etcd1']}:2380,etcd2=http://${NODE_MAP['etcd2']}:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
# ETCD_DISCOVERY=""
# ETCD_DISCOVERY_SRV=""
# ETCD_DISCOVERY_FALLBACK="proxy"
# ETCD_DISCOVERY_PROXY=""
#
# ETCD_CA_FILE=""
# ETCD_CERT_FILE=""
# ETCD_KEY_FILE=""
# ETCD_PEER_CA_FILE=""
# ETCD_PEER_CERT_FILE=""
# ETCD_PEER_KEY_FILE=""
EOF
}

etcd::gen_unit()
{
# cat <<EOF >/usr/lib/systemd/system/etcd.service
cat <<EOF >${PWD}/etcd.service
[Unit]
Description=Etcd Server
After=network.target

[Service]
Type=notify
WorkingDirectory=/var/lib/etcd
EnvironmentFile=-/etc/etcd/10-etcd.conf
ExecStart=/usr/bin/etcd
Restart=always
RestartSec=8s
LimitNOFILE=40000

[Install]
WantedBy=multi-user.target
EOF
}

SSH_OPTS="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR -C"
etcd::scp()
{
  local host="$1"
  local src=($2)
  local dst="$3"
  scp -r ${SSH_OPTS} ${src[*]} "${host}:${dst}"
}
etcd::ssh()
{
  local host="$1"
  shift
  ssh ${SSH_OPTS} -t "${host}" "$@" >/dev/null 2>&1
}
etcd::ssh_nowait()
{
  local host="$1"
  shift
  ssh ${SSH_OPTS} -t "${host}" "nohup $@" >/dev/null 2>&1 &
}

etcd::deploy()
{
    for key in ${!NODE_MAP[@]}
    do
        etcd::config $key
        etcd::ssh "root@${NODE_MAP[$key]}" "mkdir -p /var/lib/etcd /etc/etcd"
        etcd::ssh "root@${NODE_MAP[$key]}" "systemctl stop firewalld && systemctl disable firewalld"
        etcd::scp "root@${NODE_MAP[$key]}" "${key}.conf" "/etc/etcd/10-etcd.conf"
        etcd::scp "root@${NODE_MAP[$key]}" "etcd.service" "/usr/lib/systemd/system"
        etcd::scp "root@${NODE_MAP[$key]}" "${PWD}/temp-etcd/etcd ${PWD}/temp-etcd/etcdctl" "/usr/bin"
        etcd::ssh_nowait "root@${NODE_MAP[$key]}" "systemctl daemon-reload && systemctl enable etcd && nohup systemctl start etcd"
    done

    rm -f ${PWD}/${key}.conf etcd.service

}

etcd::download
etcd::gen_unit
etcd::deploy
echo -e "\033[32m 部署完毕！ \033[0m"
